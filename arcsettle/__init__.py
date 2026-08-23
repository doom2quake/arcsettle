"""ArcSettle: a reserve-gated USDC settlement rail for Arc and its reserve-aware operator agent.

The contract (src/ArcSettlement.sol) cannot settle past proven reserves: every settlement
is gated by a signed reserve attestation and reverts if it would exceed the effective USDC
reserves. This package is the autonomous operator that settles within headroom and refuses
doomed transactions before they spend gas.

It runs against an offline model of the contract by default and against a real
Arc testnet node (read-only) when ARC_RPC_URL and ARC_SETTLEMENT_ADDRESS are set. Which one
produced a given number is always in the `source` field, never left to inference.
See docs/LIMITATIONS.md for what is proved, what is simulated, and what is not built.

Milestone 1 of the ArcSettle grant proposal. Arc testnet only, never mainnet.
"""

from .config import settings

__all__ = ["settings"]
__version__ = "0.1.0"
