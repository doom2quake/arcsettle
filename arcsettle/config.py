"""ArcSettle agent configuration - extends agent-core's BaseSettings.

The load-bearing artifact is the on-chain contract (src/ArcSettlement.sol plus the
reserve attestation oracle). This Python layer is the autonomous operator: a
reserve-aware settlement agent that never proposes a settlement the contract would reject.

ARC TESTNET ONLY. Nothing here targets or should target mainnet.

Chain mode is off unless `ARC_RPC_URL` and `ARC_SETTLEMENT_ADDRESS` are both set, and even
then it is read-only (see `chain.py` and docs/LIMITATIONS.md).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from agent_core import BaseSettings, env_bool, env_int, env_str


@dataclass(frozen=True)
class ArcSettleSettings(BaseSettings):
    env_prefix: str = "ARC"
    app_name: str = "arcsettle"

    rpc_url: str = field(default_factory=lambda: env_str("ARC_RPC_URL"))            # Arc testnet RPC
    settlement_address: str = field(default_factory=lambda: env_str("ARC_SETTLEMENT_ADDRESS"))
    oracle_address: str = field(default_factory=lambda: env_str("ARC_ORACLE_ADDRESS"))
    settler_address: str = field(default_factory=lambda: env_str("ARC_SETTLER_ADDRESS"))
    settle_recipient: str = field(default_factory=lambda: env_str("ARC_SETTLE_RECIPIENT"))
    rpc_timeout_s: int = field(default_factory=lambda: env_int("ARC_RPC_TIMEOUT_S", 15))
    offline: bool = field(default_factory=lambda: env_bool("ARC_OFFLINE", False))

    @property
    def use_chain(self) -> bool:
        return bool(self.rpc_url and self.settlement_address) and not self.offline


settings = ArcSettleSettings()
