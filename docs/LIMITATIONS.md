# LIMITATIONS: what is proved, what is simulated, what is not built

ArcSettle is milestone 1 of a grant proposal. This file states plainly what exists
today so that no reader has to infer it. Nothing elsewhere in the repo contradicts it.

## What is proved (on-chain, tested)

- `src/ArcSettlement.sol` reverts any settlement that would push settled supply past
  the **effective** attested USDC reserves, reverts a stale attestation, and reverts a
  future-dated attestation. 36 Solidity tests pin these paths.
- The **redeem-then-resettle defence**: redemption books `pendingRedemptions` and nets
  it off attested reserves until a *new* attestation (higher `attestationId`) observes
  the outflow. Deleting the defence turns `test_RedeemThenResettleAgainstOldAttestationReverts`
  red.
- `src/ReserveAttestationOracle.sol` accepts a reserve figure only against a valid
  EIP-712 signature from a registered attestor, on-chain recovered, with replay,
  malleability, wrong-length, bad-v, backdated and future-dated all refused. 23 Solidity
  tests pin these.
- The operator agent (`arcsettle/`) mirrors the same gate off-chain: 75 Python tests,
  each with a named Solidity counterpart where one exists.

## What is simulated (a model, labelled as one)

- The offline chain adapter (`arcsettle/chain.py`) is an **in-process model** of the
  deployed contract. It produces no transaction hashes and no block numbers, and its
  `source` field always reads `offline-model` so model numbers can never be mistaken
  for chain numbers.
- `ui/index.html` is a **browser simulation**. It shows the contract's real event
  signatures, `topic0` hashes and error selectors, and invents no transaction hashes.

## What is NOT built, deployed, or measured (state plainly)

- **No mainnet deployment, and none planned under this grant.** All work is Arc testnet
  only. As of today the contract is not deployed anywhere; the Arc deployment is
  milestone 2, not done here.
- **No live broadcast.** Live mode in this repo is **read-only**: `snapshot()` and the
  settle dry-run are real `eth_call`s against a deployed contract, but broadcasting a
  signed settlement needs a funded Arc testnet key and a secp256k1 signer, which this
  repo does not ship. `apply_settle` in live mode raises `LiveBroadcastUnavailable` and
  says so. Building the broadcast path is milestone 3.
- **No Circle-primitive integration yet.** CCTP, Wallets and Gateway are named in the
  roadmap (milestone 3 uses one for the signer/custody seam). None is wired in here.
- **No users.** Zero. No pilot, no design partner, no waitlist.
- **No revenue** and no business model beyond the grant.
- **No audit.** No third-party security review has been performed on any of this code.
- **No partnership with Circle** and no endorsement. This is grant-application work.
- **No live-chain test.** The live-mode tests use a fake node; they pin request
  encoding and revert decoding, not a real Arc endpoint.
