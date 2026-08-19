// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IReserveOracle - the proof-of-reserves feed ArcSettle reads before it settles.
/// @notice ArcSettle reads a reserve attestation from a reserve oracle before it will
/// settle a USDC-denominated claim. The attestation states how much USDC collateral is
/// currently proven, when it was last proven, and a monotonic identifier for the
/// attestation itself, so settlement can be gated on "prove-before-settle".
///
/// `attestationId` is load bearing, not decoration: ArcSettlement uses it to tell
/// "the same proof I already saw" from "a new proof that has accounted for the USDC
/// released during a redemption". See `ArcSettlement.redeem`.
interface IReserveOracle {
    /// @return The total USDC reserves currently attested (6-decimal USDC units).
    function attestedReserves() external view returns (uint256);

    /// @return The unix timestamp of the latest attestation.
    function attestationTimestamp() external view returns (uint256);

    /// @return A strictly increasing identifier, bumped once per accepted attestation.
    function attestationId() external view returns (uint256);
}
