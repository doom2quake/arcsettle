"""ArcSettle operator agent CLI.

    arcsettle status                 # reserves / settled supply / settleable headroom
    arcsettle settle 800000          # propose a settlement (USDC units)
    arcsettle redeem 400000          # redeem: frees supply, not headroom
    arcsettle runs                   # the audit trail this process recorded

The agent is reserve-aware: before it submits a settlement it checks the same invariant
the contract enforces, and REFUSES a settlement that would exceed proven reserves rather
than broadcasting a transaction doomed to revert. Prove before settle, off chain and
on. Every decision passes agent-core's action guardrail and is recorded.

Ordering matters and is deliberate: an amount that is not a valid uint256 is
rejected first, then the reserve pre-check, and only a settlement that will actually be
submitted consumes a slot from the action limiter. A refusal costs no quota, so a
burst of bad proposals cannot lock out a good one.
"""

from __future__ import annotations

import argparse
import json
import threading
from typing import Any

from agent_core import ActionLimiter, ActionPolicy, StateStore, signature_of

from . import chain
from .chain import ONE
from .config import settings

_limiter = ActionLimiter(ActionPolicy.from_env("ARC"))

# One process-scoped store, so a run id returned by `propose_settle` can actually be
# read back, and so recurrence detection can see earlier runs. Creating a store per
# call also re-created (and leaked) a Firestore client on every settlement.
_store: StateStore | None = None
_store_lock = threading.Lock()


def get_store() -> StateStore:
    global _store
    with _store_lock:
        if _store is None:
            _store = StateStore.create(settings)
        return _store


def _reset_store_for_tests() -> None:
    global _store
    with _store_lock:
        _store = None


def _wei_fields(payload: dict[str, Any]) -> dict[str, Any]:
    """Render 1e6-scaled ints as decimal strings for the audit record.

    A large USDC amount can exceed an int64, and Firestore stores integers as int64.
    Recording them as strings is the difference between an audit trail that works
    against the real backend and one that only works in memory.
    """
    out: dict[str, Any] = {}
    for key, value in payload.items():
        out[key] = str(value) if isinstance(value, int) and not isinstance(value, bool) else value
    return out


def status() -> dict[str, Any]:
    s = chain.snapshot()
    out = {
        "source": s["source"],
        "reserves_usdc": s["reserves"] // ONE,
        "supply_usdc": s["supply"] // ONE,
        "headroom_usdc": s["headroom"] // ONE,
    }
    for key in ("chain_id", "block_number", "contract", "attestation_id"):
        if key in s:
            out[key] = s[key]
    if s.get("pending_redemptions"):
        out["pending_redemptions_usdc"] = s["pending_redemptions"] // ONE
    return out


def propose_settle(amount_usdc: int) -> dict[str, Any]:
    """Decide and, if safe, execute a settlement. Returns the decision plus the audit run id."""
    store = get_store()
    run_id = store.start_run(trigger={"settle_usdc": str(amount_usdc)})

    # 1. Domain check. The contract takes a uint256; anything else is not a settlement.
    if isinstance(amount_usdc, bool) or not isinstance(amount_usdc, int) or amount_usdc <= 0:
        store.record_guardrail(run_id, "AMOUNT_DOMAIN", "rejected", f"amount must be > 0, got {amount_usdc!r}")
        store.set_status(run_id, "rejected")
        return {"decision": "rejected", "reason": "ZeroAmount", "run_id": run_id}
    amount = amount_usdc * ONE
    if amount > chain.UINT256_MAX:
        store.record_guardrail(run_id, "AMOUNT_DOMAIN", "rejected", "amount exceeds uint256")
        store.set_status(run_id, "rejected")
        return {"decision": "rejected", "reason": "AmountExceedsUint256", "run_id": run_id}

    # 2. Reserve pre-check BEFORE the limiter, so a refusal costs no action quota.
    revert = chain.would_revert(amount)
    if revert:
        store.record_guardrail(run_id, "RESERVE_GATE", "refused", f"{revert} for {amount_usdc} USDC")
        store.set_status(run_id, "refused")
        s = chain.snapshot()
        return {"decision": "refused", "reason": revert, "headroom_usdc": s["headroom"] // ONE,
                "run_id": run_id}

    # 3. Only a settlement we intend to submit consumes a slot from the action guardrail.
    allowed, reason = _limiter.check(run_id, "settle")
    if not allowed:
        store.record_guardrail(run_id, "ACTION_LIMITER", "blocked", f"settle: {reason}")
        store.set_status(run_id, "blocked")
        return {"decision": "blocked", "reason": reason, "run_id": run_id}

    # 4. Apply. The check and the state change are atomic inside the adapter, so a
    #    concurrent proposal cannot slip through the gate this one just closed.
    result = chain.apply_settle(amount)
    if result["status"] != "settled":
        store.record_guardrail(run_id, "RESERVE_GATE", "refused", f"{result['reason']} on submit")
        store.set_status(run_id, "refused")
        return {"decision": "refused", "reason": result["reason"], "run_id": run_id}

    store.set_data(run_id, "settle", _wei_fields(result))
    store.detect_recurrence(run_id, signature_of("settle", amount_usdc))
    store.set_status(run_id, "settled")
    return {"decision": "settled", "amount_usdc": amount_usdc,
            "new_supply_usdc": result["new_supply"] // ONE, "run_id": run_id}


def propose_redeem(amount_usdc: int) -> dict[str, Any]:
    """Redeem: settle claims back out. Frees supply but NOT headroom until a new attestation."""
    store = get_store()
    run_id = store.start_run(trigger={"redeem_usdc": str(amount_usdc)})
    if isinstance(amount_usdc, bool) or not isinstance(amount_usdc, int) or amount_usdc <= 0:
        store.record_guardrail(run_id, "AMOUNT_DOMAIN", "rejected", f"amount must be > 0, got {amount_usdc!r}")
        store.set_status(run_id, "rejected")
        return {"decision": "rejected", "reason": "ZeroAmount", "run_id": run_id}
    result = chain.apply_redeem(amount_usdc * ONE)
    if result["status"] != "redeemed":
        store.record_guardrail(run_id, "REDEEM", "refused", str(result["reason"]))
        store.set_status(run_id, "refused")
        return {"decision": "refused", "reason": result["reason"], "run_id": run_id}
    store.set_data(run_id, "redeem", _wei_fields(result))
    store.set_status(run_id, "redeemed")
    return {"decision": "redeemed", "amount_usdc": amount_usdc,
            "new_supply_usdc": result["new_supply"] // ONE,
            "pending_redemptions_usdc": result["pending_redemptions"] // ONE,
            "run_id": run_id}


def _print_status(s: dict[str, Any]) -> None:
    where = "offline model" if s["source"] == "offline-model" else s["source"]
    print(f"[{where}] reserves={s['reserves_usdc']:,} USDC | supply={s['supply_usdc']:,} | "
          f"settleable headroom={s['headroom_usdc']:,}")
    if "pending_redemptions_usdc" in s:
        print(f"           pending redemptions {s['pending_redemptions_usdc']:,} USDC "
              "(netted off reserves until a new attestation lands)")


def cli(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="arcsettle", description="Reserve-gated USDC settlement operator agent.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status", help="Show reserves / settled supply / headroom.")
    m = sub.add_parser("settle", help="Propose a settlement (USDC units).")
    m.add_argument("amount", type=int)
    b = sub.add_parser("redeem", help="Redeem (USDC units): frees supply, not headroom.")
    b.add_argument("amount", type=int)
    sub.add_parser("runs", help="Show the audit runs recorded by this process.")
    sub.add_parser("demo", help="Tell the whole prove-before-settle story in one run.")
    args = parser.parse_args(argv)

    if args.cmd == "demo":
        s = status()
        print(f"[{'offline model' if s['source'] == 'offline-model' else s['source']}] "
              "the numbers below come from this source, not from a screenshot.")
        print(f"1) Attested reserves: {s['reserves_usdc']:,} USDC, settled supply {s['supply_usdc']:,}.")
        print("2) settle 800,000 (within reserves):")
        print("   ", propose_settle(800_000)["decision"])
        print("3) settle 300,000 (would exceed reserves):")
        r = propose_settle(300_000)
        print(f"    {r['decision']}: {r['reason']} - headroom is only {r['headroom_usdc']:,} USDC. "
              "The agent will NOT submit a tx the contract would revert.")
        print("4) redeem 200,000 -> supply falls, headroom does NOT reopen:")
        rb = propose_redeem(200_000)
        print(f"    {rb['decision']} -> supply {status()['supply_usdc']:,}, "
              f"headroom {status()['headroom_usdc']:,} (redemption debt "
              f"{rb['pending_redemptions_usdc']:,} still netted off reserves).")
        print("5) A new proof-of-reserves attestation of 1,500,000 USDC post-redemption -> headroom reopens:")
        chain.set_reserves(1_500_000 * ONE, now=chain.snapshot()["now"])
        r = propose_settle(300_000)
        print(f"    {r['decision']} -> supply {status()['supply_usdc']:,} USDC. Prove, then settle.")
        return 0

    if args.cmd == "status":
        _print_status(status())
        return 0
    if args.cmd == "runs":
        runs = get_store().list(limit=20)
        if not runs:
            print("No runs recorded yet in this process.")
        for r in runs:
            print(f"{r['run_id']}  {r['status']:<9} {json.dumps(r.get('trigger', {}))}")
        return 0
    if args.cmd == "settle":
        out = propose_settle(args.amount)
        if out["decision"] == "settled":
            print(f"SETTLED {out['amount_usdc']:,} USDC -> supply {out['new_supply_usdc']:,}  (run {out['run_id']})")
        elif out["decision"] == "refused":
            print(f"REFUSED: {out['reason']} (settleable headroom {out.get('headroom_usdc', 0):,} USDC). "
                  "The agent will not submit a settlement the contract would revert.")
        elif out["decision"] == "rejected":
            print(f"REJECTED: {out['reason']}. The contract takes a uint256; that amount is not one.")
        else:
            print(f"BLOCKED by guardrail: {out['reason']}")
        return 0
    if args.cmd == "redeem":
        out = propose_redeem(args.amount)
        if out["decision"] == "redeemed":
            print(f"REDEEMED {out['amount_usdc']:,} USDC -> supply {out['new_supply_usdc']:,}; "
                  f"redemption debt {out['pending_redemptions_usdc']:,} USDC stays netted off "
                  "reserves until a new attestation lands.")
        else:
            print(f"{out['decision'].upper()}: {out['reason']}")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(cli())
