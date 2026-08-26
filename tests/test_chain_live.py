"""Live (RPC) mode: config validation, real request encoding, revert decoding.

These tests do not need a node. They pin the two things that used to be absent:
that live mode validates its configuration up front instead of failing somewhere
deep in a call stack, and that when it does talk to an Arc node it sends real
`eth_call` payloads and decodes the contract's own custom errors.

A test that needs an actual Arc testnet endpoint is out of scope here; see
docs/LIMITATIONS.md for exactly what has and has not been exercised against a live chain.
"""

import json

import pytest

from arcsettle import abi, chain
from arcsettle.config import ArcSettleSettings

GOOD_ADDRESS = "0x000000000000000000000000000000000000dead"
OTHER_ADDRESS = "0x00000000000000000000000000000000000000ab"


def live_settings(**overrides) -> ArcSettleSettings:
    base = dict(rpc_url="https://rpc.example.invalid", settlement_address=GOOD_ADDRESS,
                settler_address=OTHER_ADDRESS, settle_recipient=OTHER_ADDRESS)
    base.update(overrides)
    return ArcSettleSettings(**base)


# --- configuration is validated before anything hits the network -------------

def test_valid_config_passes():
    chain.validate_chain_config(live_settings())


@pytest.mark.parametrize("overrides,needle", [
    ({"rpc_url": ""}, "ARC_RPC_URL is not set"),
    ({"rpc_url": "ws://node.example"}, "must be an http(s) URL"),
    ({"settlement_address": ""}, "ARC_SETTLEMENT_ADDRESS is not set"),
    ({"settlement_address": "0xnothex"}, "ARC_SETTLEMENT_ADDRESS"),
    ({"oracle_address": "0x1234"}, "ARC_ORACLE_ADDRESS"),
    ({"settler_address": "not-an-address"}, "ARC_SETTLER_ADDRESS"),
])
def test_bad_config_is_rejected_with_a_readable_message(overrides, needle):
    with pytest.raises(chain.ChainConfigError) as excinfo:
        chain.validate_chain_config(live_settings(**overrides))
    assert needle in str(excinfo.value)


def test_all_config_problems_are_reported_together():
    with pytest.raises(chain.ChainConfigError) as excinfo:
        chain.validate_chain_config(ArcSettleSettings(rpc_url="", settlement_address=""))
    message = str(excinfo.value)
    assert "ARC_RPC_URL" in message and "ARC_SETTLEMENT_ADDRESS" in message


def test_use_chain_requires_both_url_and_address():
    assert live_settings().use_chain is True
    assert ArcSettleSettings(rpc_url="https://x.invalid").use_chain is False
    assert live_settings(offline=True).use_chain is False


# --- live reads are real eth_calls -------------------------------------------

class FakeNode:
    """Records the JSON-RPC calls made and replays canned results."""

    def __init__(self, results):
        self.results = results
        self.calls = []

    def __call__(self, method, params, allow_error=False):
        self.calls.append((method, params))
        key = method
        if method == "eth_call":
            key = params[0]["data"][:10]
        value = self.results[key]
        if isinstance(value, Exception):
            raise value
        return value


def _uint(value: int) -> str:
    return "0x" + value.to_bytes(32, "big").hex()


def install(monkeypatch, node, cfg=None):
    monkeypatch.setattr(chain, "settings", cfg or live_settings())
    monkeypatch.setattr(chain, "_rpc", node)


def test_snapshot_reads_the_contract_over_rpc(monkeypatch):
    node = FakeNode({
        "eth_chainId": "0xaa36a7",     # a testnet chain id
        "eth_blockNumber": "0x4c4b40",
        "0x18160ddd": _uint(800_000 * chain.ONE),   # totalSupply()
        "0xe7039ed8": _uint(1_000_000 * chain.ONE),  # effectiveReserves()
        "0x30708cf9": _uint(200_000 * chain.ONE),   # settleableHeadroom()
    })
    install(monkeypatch, node)
    snap = chain.snapshot()
    assert snap["source"] == "live:11155111"
    assert snap["chain_id"] == 11155111
    assert snap["block_number"] == 0x4C4B40
    assert snap["supply"] == 800_000 * chain.ONE
    assert snap["headroom"] == 200_000 * chain.ONE
    assert snap["contract"] == GOOD_ADDRESS
    # Reads are eth_call at "latest" against the configured contract, not guesses.
    calls = [p for m, p in node.calls if m == "eth_call"]
    assert all(c[0]["to"] == GOOD_ADDRESS and c[1] == "latest" for c in calls)


def test_snapshot_reads_the_oracle_when_configured(monkeypatch):
    node = FakeNode({
        "eth_chainId": "0xaa36a7", "eth_blockNumber": "0x1",
        "0x18160ddd": _uint(0), "0xe7039ed8": _uint(0), "0x30708cf9": _uint(0),
        "0x" + abi.selector("attestedReserves()").hex(): _uint(5 * chain.ONE),
        "0x" + abi.selector("attestationTimestamp()").hex(): _uint(1_700_000_000),
        "0x" + abi.selector("attestationId()").hex(): _uint(7),
    })
    install(monkeypatch, node, live_settings(oracle_address=OTHER_ADDRESS))
    snap = chain.snapshot()
    assert snap["reserves"] == 5 * chain.ONE
    assert snap["attested_at"] == 1_700_000_000
    assert snap["attestation_id"] == 7


def test_rpc_transport_failure_is_a_clear_error(monkeypatch):
    node = FakeNode({"eth_chainId": chain.ChainCallError("boom")})
    install(monkeypatch, node)
    with pytest.raises(chain.ChainCallError):
        chain.snapshot()


# --- the settle dry-run is a real eth_call whose revert the contract produces -

def _revert(signature: str, *args: int) -> dict:
    data = abi.selector(signature) + b"".join(abi.encode_uint256(a) for a in args)
    return {"code": 3, "message": "execution reverted", "data": "0x" + data.hex()}


def test_dry_run_encodes_a_real_settle_call(monkeypatch):
    node = FakeNode({"0x15afd409": "0x"})
    install(monkeypatch, node)
    assert chain.would_revert(5 * chain.ONE) is None
    (method, params) = node.calls[0]
    assert method == "eth_call"
    data = params[0]["data"]
    assert data[:10] == "0x15afd409", "settle(address,uint256) selector"
    assert data[10:74] == "00" * 12 + OTHER_ADDRESS[2:], "recipient, left padded"
    assert int(data[74:138], 16) == 5 * chain.ONE, "amount"
    assert params[0]["from"] == OTHER_ADDRESS, "dry-run runs as the settler"


@pytest.mark.parametrize("signature,args,expected", [
    ("InsufficientReserves(uint256,uint256)", (10**12, 0), "InsufficientReserves"),
    ("StaleAttestation(uint256,uint256,uint256)", (1, 2, 3), "StaleAttestation"),
    ("FutureAttestation(uint256,uint256)", (2, 1), "FutureAttestation"),
    ("NotSettler()", (), "NotSettler"),
])
def test_dry_run_decodes_the_contracts_custom_errors(monkeypatch, signature, args, expected):
    node = FakeNode({"0x15afd409": _revert(signature, *args)})
    install(monkeypatch, node)
    assert chain.would_revert(5 * chain.ONE) == expected


def test_dry_run_reports_unknown_revert_data_honestly(monkeypatch):
    node = FakeNode({"0x15afd409": {"code": 3, "message": "execution reverted",
                                    "data": "0xdeadbeef"}})
    install(monkeypatch, node)
    assert chain.would_revert(1).startswith("UnknownRevert(")


def test_dry_run_handles_nested_revert_data(monkeypatch):
    """Some nodes nest the revert payload one level down."""
    inner = _revert("InsufficientReserves(uint256,uint256)", 1, 0)
    node = FakeNode({"0x15afd409": {"code": 3, "message": "reverted",
                                    "data": {"data": inner["data"]}}})
    install(monkeypatch, node)
    assert chain.would_revert(1) == "InsufficientReserves"


def test_dry_run_without_a_recipient_fails_loudly(monkeypatch):
    install(monkeypatch, FakeNode({}), live_settings(settler_address="", settle_recipient=""))
    with pytest.raises(chain.ChainConfigError) as excinfo:
        chain.would_revert(1)
    assert "ARC_SETTLE_RECIPIENT" in str(excinfo.value)


def test_amount_domain_is_checked_before_any_rpc(monkeypatch):
    node = FakeNode({})
    install(monkeypatch, node)
    assert chain.would_revert(-1) == "ZeroAmount"
    assert chain.would_revert(2**256) == "AmountExceedsUint256"
    assert node.calls == [], "an impossible amount must not reach the network"


# --- what live mode does NOT do, stated in code, not just in prose -----------

def test_live_broadcast_is_refused_with_an_explicit_reason(monkeypatch):
    node = FakeNode({"0x15afd409": "0x"})
    install(monkeypatch, node)
    with pytest.raises(chain.LiveBroadcastUnavailable) as excinfo:
        chain.apply_settle(5 * chain.ONE)
    message = str(excinfo.value)
    assert "read-only" in message and "LIMITATIONS.md" in message


def test_live_mode_refuses_to_pretend_a_redeem_happened(monkeypatch):
    install(monkeypatch, FakeNode({}))
    with pytest.raises(chain.LiveBroadcastUnavailable):
        chain.apply_redeem(1)


def test_offline_snapshot_never_claims_to_be_a_chain():
    assert chain.snapshot()["source"] == "offline-model"
    assert "block_number" not in chain.snapshot()
    assert "tx_hash" not in json.dumps(chain.apply_settle(chain.ONE))
