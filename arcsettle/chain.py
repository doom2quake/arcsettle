"""Chain adapter for ArcSettle: two modes, neither pretending to be the other.

**offline (default)** - an in-process model of the deployed contract's settlement gate.
It mirrors `src/ArcSettlement.sol` line for line: future-dated attestation, stale
attestation, redemption debt netted off attested reserves, uint256 bounds. It is a
MODEL. It produces no transaction hashes and no block numbers, because it has none.

**live (`ARC_RPC_URL` + `ARC_SETTLEMENT_ADDRESS`)** - real JSON-RPC against a deployed
Arc testnet contract. `snapshot()` is a real `eth_call` of `totalSupply()`,
`effectiveReserves()` and `settleableHeadroom()`. `would_revert()` is a real `eth_call`
dry-run of `settle(address,uint256)`, so the revert reason comes from the contract's
own custom error, not from a guess. Config is validated up front, so a typo in the
RPC URL or the address fails with a readable message before any network call.

What live mode does NOT do: broadcast a signed transaction. That needs a funded
Arc testnet key and a secp256k1 signer, and this repo ships neither. `apply_settle` in
live mode says exactly that instead of raising a bare NotImplementedError from
somewhere deep in the call stack. See docs/LIMITATIONS.md.
"""

from __future__ import annotations

import json
import threading
import urllib.error
import urllib.request
from typing import Any

from . import abi
from .config import ArcSettleSettings, settings

ONE = 10**6  # USDC has 6 decimals; the settlement claim tracks it unit for unit.
UINT256_MAX = abi.UINT256_MAX

# The contract's settlement gate is guarded by these custom errors; the offline model
# and the live dry-run both report the same names, so the two layers are comparable.
SETTLE_ERRORS = (
    "InsufficientReserves(uint256,uint256)",
    "StaleAttestation(uint256,uint256,uint256)",
    "FutureAttestation(uint256,uint256)",
    "NotSettler()",
    "ZeroAmount()",
    "ZeroAddress()",
)
_ERROR_BY_SELECTOR = {abi.selector(sig).hex(): sig.split("(")[0] for sig in SETTLE_ERRORS}


class ChainConfigError(RuntimeError):
    """Live mode was requested but the configuration cannot support it."""


class ChainCallError(RuntimeError):
    """The node was reachable but the call did not succeed."""


class LiveBroadcastUnavailable(RuntimeError):
    """Live reads work; broadcasting a signed settlement is not implemented here."""


# --------------------------------------------------------------------------- #
# offline model of the deployed contract
# --------------------------------------------------------------------------- #

_LOCK = threading.RLock()

_DEFAULT_STATE: dict[str, int] = {
    "reserves": 1_000_000 * ONE,
    "supply": 0,
    "attested_at": 1000,
    "now": 1000,
    "max_age": 86400,
    "attestation_id": 1,
    "pending_redemptions": 0,
    "redemption_debt_id": 0,
}
_STATE: dict[str, int] = dict(_DEFAULT_STATE)


def _effective_reserves_offline() -> int:
    """Mirror of `ArcSettlement.effectiveReserves()`."""
    st = _STATE
    if st["attested_at"] > st["now"]:
        return 0
    if st["now"] - st["attested_at"] > st["max_age"]:
        return 0
    debt = 0 if st["attestation_id"] > st["redemption_debt_id"] else st["pending_redemptions"]
    return st["reserves"] - debt if st["reserves"] > debt else 0


def snapshot() -> dict[str, Any]:
    """Reserves, supply and settleable headroom (all 1e6-scaled USDC), plus provenance.

    `source` is `"offline-model"` or `"live:<chain-id>"` so no caller can present
    model numbers as chain numbers by accident.
    """
    if settings.use_chain:
        return _chain_snapshot()
    with _LOCK:
        effective = _effective_reserves_offline()
        supply = _STATE["supply"]
        return {
            "source": "offline-model",
            "reserves": _STATE["reserves"],
            "effective_reserves": effective,
            "supply": supply,
            "headroom": effective - supply if effective > supply else 0,
            "attested_at": _STATE["attested_at"],
            "now": _STATE["now"],
            "attestation_id": _STATE["attestation_id"],
            "pending_redemptions": _STATE["pending_redemptions"],
        }


def check_amount(amount: int) -> str | None:
    """Validate an amount against Solidity's uint256 domain before anything else.

    The contract takes a `uint256`. A negative or oversized Python int is not a
    settlement the chain could ever accept, so it is rejected here rather than silently
    producing an impossible supply in the offline model.
    """
    if isinstance(amount, bool) or not isinstance(amount, int):
        return "NotAnInteger"
    if amount <= 0:
        return "ZeroAmount"
    if amount > UINT256_MAX:
        return "AmountExceedsUint256"
    return None


def would_revert(amount: int) -> str | None:
    """Return the revert reason a settlement of `amount` would hit, or None.

    Offline: mirrors the on-chain checks in the same order. Live: asks the chain,
    via `eth_call`, and decodes the contract's own custom error selector.
    """
    bad = check_amount(amount)
    if bad:
        return bad
    if settings.use_chain:
        return _chain_would_revert(amount)
    with _LOCK:
        st = _STATE
        if st["attested_at"] > st["now"]:
            return "FutureAttestation"
        if st["now"] - st["attested_at"] > st["max_age"]:
            return "StaleAttestation"
        effective = _effective_reserves_offline()
        if st["supply"] + amount > effective:
            return "InsufficientReserves"
        if st["supply"] + amount > UINT256_MAX:
            return "SupplyExceedsUint256"
    return None


def apply_settle(amount: int) -> dict[str, Any]:
    """Check and apply a settlement atomically. Returns the outcome; never raises on refusal.

    The check and the state change happen under one lock, so two concurrent callers
    cannot both pass a gate that only one of them fits through.
    """
    if settings.use_chain:
        reason = would_revert(amount)
        if reason:
            return {"status": "reverted", "reason": reason, "amount": amount}
        return _chain_settle(amount)
    with _LOCK:
        reason = would_revert(amount)
        if reason:
            return {"status": "reverted", "reason": reason, "amount": amount}
        # A newer attestation discharges the booked redemption debt, exactly as
        # `ArcSettlement.settle` does before it computes effective reserves.
        if _STATE["pending_redemptions"] and _STATE["attestation_id"] > _STATE["redemption_debt_id"]:
            _STATE["pending_redemptions"] = 0
        _STATE["supply"] += amount
        return {"status": "settled", "amount": amount, "new_supply": _STATE["supply"],
                "attestation_id": _STATE["attestation_id"], "source": "offline-model"}


def apply_redeem(amount: int) -> dict[str, Any]:
    """Offline mirror of `ArcSettlement.redeem`: frees supply, books redemption debt.

    Redeeming does NOT reopen settlement headroom. The freed amount is netted off attested
    reserves until a NEW attestation (higher id) proves the post-redemption USDC balance.
    """
    if settings.use_chain:
        raise LiveBroadcastUnavailable(
            "redeem is a state-changing transaction; live mode in this repo is read-only. "
            "See docs/LIMITATIONS.md."
        )
    bad = check_amount(amount)
    if bad:
        return {"status": "reverted", "reason": bad, "amount": amount}
    with _LOCK:
        if amount > _STATE["supply"]:
            return {"status": "reverted", "reason": "InsufficientBalance", "amount": amount}
        _STATE["supply"] -= amount
        if _STATE["attestation_id"] > _STATE["redemption_debt_id"]:
            _STATE["redemption_debt_id"] = _STATE["attestation_id"]
            _STATE["pending_redemptions"] = amount
        else:
            _STATE["pending_redemptions"] += amount
        return {"status": "redeemed", "amount": amount, "new_supply": _STATE["supply"],
                "pending_redemptions": _STATE["pending_redemptions"], "source": "offline-model"}


def set_reserves(reserves: int, now: int | None = None) -> None:
    """Publish a new offline attestation (mirrors `MockReserveOracle.setReserves`: id + 1)."""
    if reserves < 0 or reserves > UINT256_MAX:
        raise ValueError(f"reserves out of uint256 range: {reserves}")
    with _LOCK:
        _STATE["reserves"] = reserves
        _STATE["attested_at"] = _STATE["now"] if now is None else now
        _STATE["attestation_id"] += 1


def set_now(ts: int) -> None:
    with _LOCK:
        _STATE["now"] = ts


def _reset() -> None:
    with _LOCK:
        _STATE.update(_DEFAULT_STATE)


# --------------------------------------------------------------------------- #
# live mode: real eth_call against a deployed Arc testnet contract
# --------------------------------------------------------------------------- #

# A zero-address `from` is refused by `onlySettler`, so live dry-runs use the
# configured settler when one is set and otherwise report NotSettler honestly.
_ZERO_ADDRESS = "0x" + "00" * 20


def validate_chain_config(cfg: ArcSettleSettings | None = None) -> None:
    """Fail fast, with every problem listed, before a single byte hits the network."""
    cfg = cfg or settings
    problems: list[str] = []
    url = (cfg.rpc_url or "").strip()
    if not url:
        problems.append("ARC_RPC_URL is not set")
    elif not (url.startswith("http://") or url.startswith("https://")):
        problems.append(f"ARC_RPC_URL must be an http(s) URL, got {url!r}")
    for name, value, required in (
        ("ARC_SETTLEMENT_ADDRESS", cfg.settlement_address, True),
        ("ARC_ORACLE_ADDRESS", cfg.oracle_address, False),
        ("ARC_SETTLER_ADDRESS", cfg.settler_address, False),
    ):
        if not value:
            if required:
                problems.append(f"{name} is not set")
            continue
        try:
            abi.normalize_address(value)
        except ValueError as exc:
            problems.append(f"{name}: {exc}")
    if problems:
        raise ChainConfigError("live chain mode is misconfigured: " + "; ".join(problems))


def _rpc(method: str, params: list[Any], *, allow_error: bool = False) -> Any:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(
        settings.rpc_url, data=body, headers={"content-type": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=settings.rpc_timeout_s) as response:
            payload = json.loads(response.read().decode())
    except urllib.error.URLError as exc:
        raise ChainCallError(f"{method} could not reach {settings.rpc_url}: {exc}") from exc
    except (ValueError, OSError) as exc:
        raise ChainCallError(f"{method} failed against {settings.rpc_url}: {exc}") from exc
    if "error" in payload:
        if allow_error:
            return payload["error"]
        raise ChainCallError(f"{method} returned an error: {payload['error']}")
    return payload["result"]


def _eth_call_uint(to: str, signature: str) -> int:
    data = "0x" + abi.selector(signature).hex()
    return abi.decode_uint256(_rpc("eth_call", [{"to": to, "data": data}, "latest"]))


def _chain_snapshot() -> dict[str, Any]:
    validate_chain_config()
    address = abi.normalize_address(settings.settlement_address)
    chain_id = int(_rpc("eth_chainId", []), 16)
    block = int(_rpc("eth_blockNumber", []), 16)
    supply = _eth_call_uint(address, "totalSupply()")
    effective = _eth_call_uint(address, "effectiveReserves()")
    headroom = _eth_call_uint(address, "settleableHeadroom()")
    out: dict[str, Any] = {
        "source": f"live:{chain_id}",
        "chain_id": chain_id,
        "block_number": block,
        "contract": address,
        "reserves": effective,
        "effective_reserves": effective,
        "supply": supply,
        "headroom": headroom,
    }
    if settings.oracle_address:
        oracle = abi.normalize_address(settings.oracle_address)
        out["oracle"] = oracle
        out["reserves"] = _eth_call_uint(oracle, "attestedReserves()")
        out["attested_at"] = _eth_call_uint(oracle, "attestationTimestamp()")
        out["attestation_id"] = _eth_call_uint(oracle, "attestationId()")
    return out


def _revert_data(error: Any) -> str:
    """Pull the revert payload out of the several shapes nodes use for it."""
    if isinstance(error, dict):
        data = error.get("data")
        if isinstance(data, dict):
            data = data.get("data") or data.get("originalError", {}).get("data")
        if isinstance(data, str):
            return data
    return ""


def _chain_would_revert(amount: int) -> str | None:
    """Dry-run `settle(to, amount)` with `eth_call` and decode the contract's error."""
    validate_chain_config()
    address = abi.normalize_address(settings.settlement_address)
    recipient = abi.normalize_address(settings.settle_recipient or settings.settler_address) \
        if (settings.settle_recipient or settings.settler_address) else _ZERO_ADDRESS
    if recipient == _ZERO_ADDRESS:
        raise ChainConfigError(
            "live dry-run needs a recipient: set ARC_SETTLE_RECIPIENT (or ARC_SETTLER_ADDRESS). "
            "settle(address(0), ...) always reverts with ZeroAddress."
        )
    data = "0x" + (
        abi.selector("settle(address,uint256)")
        + abi.encode_address(recipient)
        + abi.encode_uint256(amount)
    ).hex()
    call: dict[str, Any] = {"to": address, "data": data}
    if settings.settler_address:
        call["from"] = abi.normalize_address(settings.settler_address)
    result = _rpc("eth_call", [call, "latest"], allow_error=True)
    if isinstance(result, dict) and "code" in result:  # an error object
        revert = _revert_data(result)
        if revert.startswith("0x") and len(revert) >= 10:
            return _ERROR_BY_SELECTOR.get(revert[2:10], f"UnknownRevert({revert[:10]})")
        message = str(result.get("message", "")).strip()
        return f"Revert({message})" if message else "Revert(unknown)"
    return None


def _chain_settle(amount: int) -> dict[str, Any]:
    """Live mode is read-only. Say so, loudly, instead of pretending to broadcast."""
    raise LiveBroadcastUnavailable(
        "Live mode in this repo is read-only: reads and settle dry-runs go to the chain, "
        "but broadcasting a signed settlement needs a funded Arc testnet settler key and a "
        "secp256k1 signer, which this repo does not ship. The dry-run result for "
        f"{amount} USDC units is authoritative for whether the settlement would succeed. "
        "Run without ARC_RPC_URL to exercise the full decision loop against the "
        "offline model. See docs/LIMITATIONS.md."
    )
