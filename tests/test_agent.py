"""Operator-agent tests against the offline model of the deployed contract.

Every test here has a named counterpart in `test/ArcSettlement.t.sol`. The point
of the offline model is that the agent refuses exactly what the chain would revert,
so the two suites are meant to be read side by side. Amounts are in USDC units.
"""

import threading

import pytest

from arcsettle import chain
from arcsettle.chain import ONE
from arcsettle.main import get_store, propose_redeem, propose_settle, status


# --- the gate ---------------------------------------------------------------

def test_status_headroom():
    s = status()
    assert s["source"] == "offline-model"
    assert s["reserves_usdc"] == 1_000_000
    assert s["headroom_usdc"] == 1_000_000


def test_settle_within_reserves():
    out = propose_settle(800_000)
    assert out["decision"] == "settled"
    assert status()["supply_usdc"] == 800_000
    assert status()["headroom_usdc"] == 200_000


def test_settle_past_reserves_refused():
    propose_settle(1_000_000)              # exactly at reserves
    out = propose_settle(1)                # one past -> refused (not submitted)
    assert out["decision"] == "refused"
    assert out["reason"] == "InsufficientReserves"


def test_stale_attestation_refused():
    chain.set_now(1000 + 86400 + 1)      # attestation now stale
    out = propose_settle(1)
    assert out["decision"] == "refused"
    assert out["reason"] == "StaleAttestation"


def test_future_attestation_refused():
    """Mirrors test_FutureAttestationReverts: a future proof is not an eternal proof."""
    chain.set_reserves(1_000_000 * ONE, now=2000)   # attested at 2000
    chain.set_now(1500)                             # ...but "now" is 1500
    out = propose_settle(1)
    assert out["decision"] == "refused"
    assert out["reason"] == "FutureAttestation"


def test_reserves_increase_unlocks_settle():
    propose_settle(1_000_000)
    chain.set_reserves(1_500_000 * ONE, now=1000)
    out = propose_settle(500_000)
    assert out["decision"] == "settled"
    assert status()["supply_usdc"] == 1_500_000


# --- amounts outside the uint256 domain -------------------------------------

@pytest.mark.parametrize("bad", [-1, -1_000_000, 0])
def test_non_positive_amounts_are_rejected_not_settled(bad):
    """A uint256 cannot be negative or zero-valued; the agent must not model one.

    Regression: `settle -1` used to report `settled`, drive supply to -1, and raise
    headroom to 1,000,001.
    """
    out = propose_settle(bad)
    assert out["decision"] == "rejected"
    assert out["reason"] == "ZeroAmount"
    assert status()["supply_usdc"] == 0
    assert status()["headroom_usdc"] == 1_000_000


def test_amount_beyond_uint256_is_rejected():
    out = propose_settle(2**256)
    assert out["decision"] == "rejected"
    assert out["reason"] == "AmountExceedsUint256"
    assert status()["supply_usdc"] == 0


def test_boolean_amount_is_rejected():
    assert propose_settle(True)["decision"] == "rejected"


# --- redemption cannot reopen headroom --------------------------------------

def test_redeem_does_not_reopen_headroom():
    propose_settle(1_000_000)
    assert status()["headroom_usdc"] == 0
    out = propose_redeem(400_000)
    assert out["decision"] == "redeemed"
    assert status()["supply_usdc"] == 600_000
    assert status()["headroom_usdc"] == 0, "redeeming must not free settlement capacity"


def test_redeem_then_resettle_against_old_attestation_refused():
    """The Solidity attack, in Python: 1M settled, redeem 400k, re-settle 400k."""
    propose_settle(1_000_000)
    propose_redeem(400_000)
    out = propose_settle(400_000)
    assert out["decision"] == "refused"
    assert out["reason"] == "InsufficientReserves"
    assert status()["supply_usdc"] == 600_000


def test_new_attestation_clears_redemption_debt():
    propose_settle(1_000_000)
    propose_redeem(400_000)
    chain.set_reserves(1_000_000 * ONE, now=1000)   # a NEW proof (id bumps)
    assert status()["headroom_usdc"] == 400_000
    assert propose_settle(400_000)["decision"] == "settled"


def test_redeem_more_than_supply_refused():
    propose_settle(100)
    out = propose_redeem(101)
    assert out["decision"] == "refused"
    assert out["reason"] == "InsufficientBalance"


# --- guardrail accounting ----------------------------------------------------

def test_refusals_do_not_consume_the_action_quota(monkeypatch):
    """Regression: two over-reserve refusals used to exhaust a two-action cap and
    block a legitimate settlement that landed after reserves increased."""
    from arcsettle import main
    monkeypatch.setattr(main._limiter.policy, "max_actions_per_cycle", 2, raising=False)
    monkeypatch.setattr(main._limiter.policy, "max_actions_per_hour", 2, raising=False)

    assert propose_settle(2_000_000)["decision"] == "refused"
    assert propose_settle(2_000_000)["decision"] == "refused"
    chain.set_reserves(3_000_000 * ONE, now=1000)
    assert propose_settle(1_000)["decision"] == "settled", "a refusal must cost no quota"


def test_limiter_still_caps_real_settlements(monkeypatch):
    from arcsettle import main
    monkeypatch.setattr(main._limiter.policy, "max_actions_per_cycle", 2, raising=False)
    monkeypatch.setattr(main._limiter.policy, "max_actions_per_hour", 2, raising=False)
    assert propose_settle(1)["decision"] == "settled"
    assert propose_settle(1)["decision"] == "settled"
    assert propose_settle(1)["decision"] == "blocked"


# --- the audit trail is real -------------------------------------------------

def test_run_id_can_be_read_back():
    """Regression: a fresh StateStore per call meant the returned run id was dead
    on arrival and recurrence detection never saw an earlier run."""
    out = propose_settle(1_000)
    record = get_store().get(out["run_id"])
    assert record is not None
    assert record["status"] == "settled"


def test_recurrence_detection_sees_earlier_runs():
    first = propose_settle(1_000)
    second = propose_settle(1_000)
    assert get_store().get(first["run_id"]) is not None
    record = get_store().get(second["run_id"])
    assert record["recurrence"] is not None, "the same settlement twice is a repeat"


def test_recorded_amounts_are_backend_safe():
    """Large USDC amounts can exceed an int64; the audit record must not
    depend on a backend that silently cannot store them."""
    out = propose_settle(800_000)
    data = get_store().get(out["run_id"])["data"]["settle"]
    assert data["new_supply"] == str(800_000 * ONE)
    assert all(not isinstance(v, int) or abs(v) < 2**63 for v in data.values())


def test_refusal_is_recorded_as_a_guardrail():
    out = propose_settle(2_000_000)
    record = get_store().get(out["run_id"])
    assert record["status"] == "refused"
    assert any(g["name"] == "RESERVE_GATE" for g in record["guardrails"])


# --- concurrency -------------------------------------------------------------

def test_concurrent_settlements_cannot_both_pass_one_gate(monkeypatch):
    """Two threads proposing the full headroom must not both settle it.

    Regression: the offline check and the offline mutation were separate, so a
    reader could pass a gate another writer had already closed.
    """
    from arcsettle import main
    monkeypatch.setattr(main._limiter.policy, "max_actions_per_cycle", 100, raising=False)
    monkeypatch.setattr(main._limiter.policy, "max_actions_per_hour", 100, raising=False)

    results = []
    barrier = threading.Barrier(8)

    def worker():
        barrier.wait()
        results.append(propose_settle(1_000_000)["decision"])

    threads = [threading.Thread(target=worker) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert results.count("settled") == 1, f"exactly one settlement may win: {results}"
    assert status()["supply_usdc"] == 1_000_000
    assert status()["headroom_usdc"] == 0
