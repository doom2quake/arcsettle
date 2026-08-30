# DEMO: recording kit (~75 seconds)

A tight, honest walk-through. Every number on screen is produced live by the code or
proved by a test; nothing is a screenshot of a claim.

## Setup

```bash
cd projects/circle-arc/app
forge test            # expect: 59 passed
PYTHONPATH=. python -m arcsettle.main --help
```

Open `ui/index.html` in a browser for the visual (it opens over `file://`, no server).

## Beat 1: the invariant (0:00-0:20)

> "ArcSettle is a USDC settlement rail for Arc. Its one rule: settled claims can never
> exceed the USDC reserves that have actually been proven. That rule is on-chain, not a
> policy in a runbook."

Run:

```bash
PYTHONPATH=. python -m arcsettle.main status
PYTHONPATH=. python -m arcsettle.main settle 800000     # within reserves -> SETTLED
PYTHONPATH=. python -m arcsettle.main settle 300000     # over -> REFUSED, no gas spent
```

Point out: the agent refuses off-chain *exactly* what the contract would revert on-chain.

## Beat 2: the hero defence (0:20-0:45)

> "The subtle attack: redeem, move the freed USDC out, then re-settle against the same
> old proof. Naive reserve gates allow it. We do not."

```bash
PYTHONPATH=. python -m arcsettle.main demo
```

Narrate step 4: redeeming frees supply but the freed amount is netted off reserves as
`pendingRedemptions` until a **new** attestation observes the outflow. Settlement
headroom stays shut until then.

## Beat 3: proved, not asserted (0:45-1:05)

> "Each defence has a test that goes red if you delete it."

```bash
forge test --match-test test_RedeemThenResettleAgainstOldAttestationReverts -vv
forge test --match-contract ReserveAttestationOracleTest
```

23 oracle tests: EIP-712 signature recovery, replay, malleability, timelocked attestor
set. 36 settlement tests: the gate, freshness, redemption accounting, re-entrancy.

## Beat 4: honest close (1:05-1:15)

> "Testnet only. No mainnet, no live broadcast yet, no users, no audit. That is
> milestone 1: the contract and the proof path, tested. See LIMITATIONS.md."

Show `docs/LIMITATIONS.md`.
