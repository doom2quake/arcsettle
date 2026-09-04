# ArcSettle: agentic USDC settlement with on-chain proof-of-reserves on Arc

**Applicant:** doom2quake (builder collective)
**Programme:** Circle Developer Grants (Arc-forward)
**Requested:** milestone-based USDC grant, non-dilutive
**New project repo:** `github.com/doom2quake/arcsettle` (new repo, purpose-built for this proposal)
**Status of this document:** draft grant proposal, testnet-only scope, no mainnet deployment

---

## 0. Grant verification (read this first)

We verified the programme against Circle's own pages before writing.

**VERIFIED on an official Circle page (`circle.com/grant`, fetched 2026-08-24):**

- The programme is a **grant, non-dilutive**. It is not an equity investment and does not require a SAFE or token. We keep our IP.
- Funding is paid **in USDC**, tiered from about **$5,000 for early-stage development up to $100,000 for scaling**.
- Funding is **milestone-based**: payments release as milestones are met and approved, with milestones tailored to the applicant roadmap and including Circle and Arc integration commitments.
- The selection pipeline is: submit through the grants portal, initial alignment review, finalist technical review with Ventures/Product/BD, acceptance and milestone design, then disbursement on milestone completion.
- Selection weighs platform alignment with USDC and Circle products, a team with a proven ability to ship, traction or a credible path to it, and ecosystem impact that expands USDC utility.
- **Arc is explicitly core**: proposals should show that Arc is central to the flow of value, liquidity, or settlement, with meaningful use of Circle products (USDC, Wallets, CCTP, Gateway).
- Focus areas named on Circle/Arc pages include **agentic economic activity, stablecoin FX, peer-to-peer payments, treasury management, prediction markets, and lending/borrowing**.

**CONFLICT we are flagging honestly:** Circle's own grant page renders as open with a live application URL (`circle.com/grant/application`). Several third-party news aggregators, by contrast, state the window is closed as of August 2026 and point to Circle's Discord for the next cycle. We trust the official page over the aggregators, but the disagreement is real. **An operator must confirm the portal is actually accepting submissions before we invest applicant time.** This is the single gating check.

**INFERRED (not stated verbatim on an official page):** that an agentic proof-of-reserves settlement product maps onto the "agentic economic activity" and "treasury management" focus areas. The mapping is ours; the focus-area labels are Circle's.

---

## 1. The problem

Fiat-backed stablecoins settle on-chain but prove solvency **off-chain**. The issuer holds reserves at a bank and asserts that circulating supply never exceeds them. The chain sees tokens move; it does not see whether those tokens are backed at the instant they are minted or settled. When an attestation lags, when a redemption frees mint headroom before the outflow is observed, or when a treasury agent mints against a stale proof, the gap between "reported reserves" and "reserves that have actually been proven right now" is where depegs and insolvency events live. Anyone accepting the token as settlement, a merchant, a payment processor, a treasury desk, wears that gap, and they cannot see it until it has already cost them.

The failure sharpens the moment you put an **autonomous agent** on the treasury. An agent that rebalances, settles, or mints on a schedule will, unless something stops it, submit a mint against whatever reserve figure it last read, waste gas on transactions that revert, or, worse, act on a figure that a redemption has already invalidated. The guarantee that "we never mint past proven reserves" has to be an on-chain invariant the agent cannot talk its way around, not a policy in a runbook.

## 2. Why Arc, why now

Arc is Circle's own settlement chain, with USDC as native gas and value, and first-class access to Circle's settlement primitives (CCTP, Wallets, Gateway). That makes it the right and arguably the only correct home for a proof-of-reserves settlement rail: the reserve asset, the settled asset, and the gas asset are the same regulated dollar, so the invariant "circulating never exceeds attested reserves" is expressed in one unit end to end, with no bridge-risk seam in the middle of the guarantee. On a general-purpose chain this product is a bolt-on; on Arc it is native to how value already moves.

The timing is that Arc is pre-mainnet and Circle is actively funding production-grade builders through the relaunched grant programme, explicitly naming agentic economic activity and treasury management as focus areas. The primitive we want to make standard, an agent that provably cannot settle past proven reserves, is exactly the kind of durable ecosystem safety rail that is far cheaper to establish before mainnet liquidity arrives than to retrofit after. We want to be building it during the window when Circle is choosing what the Arc settlement layer looks like.

## 3. Evidence we ship

**Milestone 1 is already built and green.** The ArcSettle repo exists at `projects/circle-arc/app` (a new, self-contained repo, not a copy of the lead build): the reserve-gate contract (`src/ArcSettlement.sol`) and the EIP-712 attestation oracle (`src/ReserveAttestationOracle.sol`), ported to Arc, denominated in USDC (6 decimals), with the redeem-then-resettle defence intact, plus the reserve-aware operator agent (`arcsettle/`, vendoring `agent_core`). Verified counts, reproduced on 2026-08-26:

- **`forge test`: 59 Solidity tests pass** (solc 0.8.24) across the settlement rail (36) and the reserve oracle (23). The reserve gate, the redeem-then-resettle defence (`test_RedeemThenResettleAgainstOldAttestationReverts`), timelocked oracle rotation, and the signed EIP-712 proof path each have dedicated tests.
- **`PYTHONPATH=. pytest tests -q`: 75 Python tests pass**, covering the operator agent, offline-model parity with the contract, the dependency-free ABI layer (selectors pinned to solc's own output), and live-mode config and revert decoding.

Full package in the repo: `ui/index.html` (self-contained settlement-gauge demo with agent run-trace and on-chain event log), `paper/paper.tex` + `references.bib`, `deck/deck.md` (Marp), `DEMO.md`, `docs/LIMITATIONS.md`, `docs/ui.png`, `CITATION.cff`, MIT `LICENSE`. This completes milestone 1; milestones 2 to 4 remain as scoped in Section 4.

The two lead systems ArcSettle was adapted from, also real repositories with reproducible test suites checked by mutation (each defence removed and the matching test confirmed to go red):

**ProofBackedUSD** (`github.com/doom2quake/proofbackedusd`), an EVM stablecoin that reverts any mint that would push supply past proven reserves:

- **59 Solidity tests** (`forge test`) across the coin and an EIP-712 reserve oracle. The reserve gate, the redeem-then-remint defence, timelocked oracle rotation, and the signed-proof path each have dedicated tests.
- **75 Python tests** (`pytest`) covering the operator agent, offline-model parity with the contract, the ABI layer, and live-mode config and revert decoding.
- The hero defence: a redemption frees supply but does **not** reopen mint headroom until a new attestation has observed the outflow (`pendingRedemptions` netted off attested reserves). This blocks the redeem-move-collateral-remint attack that naive reserve gates allow.
- Live mode is real but **read-only**: `status` performs real `eth_call`s and a proposed mint is dry-run against the contract's own custom error. Broadcasting a signed mint is explicitly **not built** and the code says so.

**PayLane** (`github.com/doom2quake/paylane`), the same invariant as a Solana settlement rail, proving the pattern is not chain-specific:

- **39 Rust invariant tests + 13 program tests** against the **real SPL Token program** inside `solana-program-test` (real CPIs, real supply changes, real burns), plus **44 Python tests**. A stubbed mint helper fails all thirteen program tests.
- An attested reserve figure below circulating supply is **recorded and pauses the treasury** rather than being refused, so a shortfall is on-chain truth, not a swallowed error.

Both agents run on our shared `agent-core` guardrail layer (an `ActionLimiter` plus an audit trail): the agent runs the on-chain gate off-chain first, so a doomed mint never spends gas, and only a mint that will actually be submitted spends action quota.

The independent review pass matters here: both repos carry an `HONESTY.md` that maps, line by line, what is proved, what is simulated, and what is not built. We removed an earlier "CertiK-clean" claim from ProofBackedUSD because **no audit has been performed**; the file records that removal. This is the review discipline ArcSettle inherits.

## 4. Milestone roadmap

ArcSettle is a **new repo** (`github.com/doom2quake/arcsettle`). It adapts ProofBackedUSD's reserve-gate contract and EIP-712 oracle to Arc, replaces the pbUSD token with **USDC as the settled and reserve asset**, and puts the agent-core operator agent in front of it as the settlement driver. All work is **Arc testnet only**.

**Milestone 1 — Arc reserve-gated settlement contract (weeks 0-4). BUILT.**
Deliverable: the reserve-gate and EIP-712 attestation oracle ported to Arc, denominated in USDC, with the redeem-then-resettle defence intact. Reviewer verifies by running `forge test` and reading the diff against ProofBackedUSD. **Status: complete and green** at `projects/circle-arc/app` — `forge test` reports 59 Solidity tests passing (36 settlement + 23 oracle) and `pytest tests -q` reports 75 Python tests passing (see Section 3). Unlocks: a settlement contract on Arc that provably cannot settle past proven reserves.
Unlocks the next milestone.

**Milestone 2 — Testnet deployment + live read path (weeks 4-8).**
Deliverable: the contract deployed to **Arc testnet** with a published address and explorer link, and the agent's read-only path (`status`, dry-run settle via `eth_call`) pointed at the live testnet contract returning real chain-tagged data. Reviewer verifies by opening the explorer link and running the agent in live read mode against the deployed address. Unlocks: the first end-to-end, on-chain-verifiable proof-of-reserves settlement on Arc.
Unlocks the next milestone.

**Milestone 3 — Agentic settlement broadcast with guardrails (weeks 8-14).**
Deliverable: the currently-unbuilt broadcast path, a funded testnet signer that lets the agent-core operator agent actually submit reserve-gated settlements on Arc, every action bounded by the `ActionLimiter` and written to the audit trail; integration with a Circle primitive (Wallets or Gateway) for the signer/custody seam. Reviewer verifies by running a scripted settlement session that produces real Arc testnet transaction hashes for accepted settlements and on-chain reverts for refused ones, cross-checked against the audit log. Unlocks: a working agentic USDC settlement rail on Arc, the core deliverable.
Unlocks the final milestone.

**Milestone 4 — Reusable Arc proof-of-reserves module + docs (weeks 14-18).**
Deliverable: the reserve-gate extracted as a documented, MIT-licensed module other Arc builders can drop into their own USDC contracts, with an integration guide, the `HONESTY.md` scope map, and a reference agent. Reviewer verifies by following the guide to gate a fresh toy contract on Arc testnet. Unlocks: the pattern becomes ecosystem infrastructure rather than one app.

**After the grant:** the module is maintained in the open as the reference proof-of-reserves gate for Arc USDC contracts; we pursue design-partner treasuries running agentic settlement on Arc testnet, and a security audit (explicitly not yet done) as a funded follow-on before any mainnet consideration.

## 5. Ecosystem impact

Everything is MIT-licensed under `doom2quake` and open-sourced. Reusable outputs for other Arc builders: (1) the **reserve-gate + EIP-712 attestation contract** as a drop-in module for any USDC-denominated contract on Arc; (2) the **agent-core guardrail layer** (`ActionLimiter` + audit trail) that runs an on-chain gate off-chain first so agents never burn gas on doomed transactions; (3) the **`HONESTY.md` review pattern** that maps proved/simulated/not-built, which we would like to see more Arc grantees adopt; (4) an **integration guide** and reference agent. The durable contribution is a standard, tested answer to "how does an agent settle in USDC on Arc without ever exceeding proven reserves," established before mainnet.

## 6. Sustainability and honest limits

**What keeps it alive after the money ends:** the reserve-gate is small, dependency-light, and already carries its own test suite, so maintenance cost is low. The pattern is reusable across every USDC contract on Arc, which gives it a reason to be maintained beyond any single app. Follow-on paths are design-partner treasuries and a funded audit; neither is promised here.

**What is NOT built, deployed, or measured (state plainly):**

- **No users.** Zero. No pilot, no design partner, no waitlist.
- **No mainnet deployment, and none planned under this grant.** All work is Arc testnet only. As of today ArcSettle is not deployed anywhere; the Arc contract is a planned port, not a running one.
- **No revenue** and no business model beyond the grant.
- **No audit.** No third-party security review has been performed on any of our code. We removed a prior "CertiK-clean" claim because it was false.
- **No live broadcast yet.** In the systems we ship today, submitting a signed transaction is explicitly unbuilt (ProofBackedUSD raises `LiveBroadcastUnavailable`; PayLane refuses to construct a live treasury without an injected client). Milestone 3 is exactly the work to build it, on testnet.
- **No partnership with Circle** and no endorsement. This is an application.
- **The traction Circle's criteria ask for, we do not have.** Our substitute is working, mutation-tested code and a candid scope map, not usage numbers. We are not hiding that gap.

---

*Cite:*

```bibtex
@software{sarkar_arcsettle_2026,
  author  = {Dipankar Sarkar},
  title   = {ArcSettle: Agentic USDC Settlement with On-Chain Proof-of-Reserves on Arc},
  year    = {2026},
  url     = {https://github.com/doom2quake/arcsettle},
  license = {MIT}
}
```

License: MIT, held by doom2quake. Testnet only; no mainnet, no real funds.
