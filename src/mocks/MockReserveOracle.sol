// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IReserveOracle} from "../interfaces/IReserveOracle.sol";

/// @notice Test-only reserve oracle with directly settable reserves + timestamp.
/// It performs NO proof verification and must never be deployed as the live oracle;
/// the real one is `src/ReserveAttestationOracle.sol`, which accepts a reserve figure
/// only against an EIP-712 signature from a registered attestor.
///
/// It exists so the settlement-gate tests can drive the oracle into arbitrary states
/// (future timestamps, extreme values) that a well-behaved oracle would refuse to produce.
contract MockReserveOracle is IReserveOracle {
    uint256 private _reserves;
    uint256 private _timestamp;
    uint256 private _id;

    constructor(uint256 reserves_, uint256 timestamp_) {
        _reserves = reserves_;
        _timestamp = timestamp_;
        _id = 1;
    }

    function attestedReserves() external view returns (uint256) {
        return _reserves;
    }

    function attestationTimestamp() external view returns (uint256) {
        return _timestamp;
    }

    function attestationId() external view returns (uint256) {
        return _id;
    }

    /// @notice Publish a new attestation (bumps the attestation id, as a real one does).
    function setReserves(uint256 reserves_, uint256 timestamp_) external {
        _reserves = reserves_;
        _timestamp = timestamp_;
        _id += 1;
    }

    /// @notice Overwrite the current attestation in place, WITHOUT bumping the id.
    /// Models an operator restating the same proof; ArcSettlement must not treat
    /// this as new evidence that a redemption outflow has been observed.
    function restateWithoutNewProof(uint256 reserves_, uint256 timestamp_) external {
        _reserves = reserves_;
        _timestamp = timestamp_;
    }
}

/// @dev Deliberately mis-declares `settle` as `view` so a `view` function can attempt
/// to call it. The EVM, not the type system, is what stops this: see ReentrantOracle.
interface ISettleLie {
    function settle(address to, uint256 amount) external view;
}

/// @notice Test-only oracle that tries to re-enter ArcSettlement.settle while
/// ArcSettlement is reading it.
///
/// Every `IReserveOracle` getter is `view`, so ArcSettlement reaches the oracle with
/// STATICCALL. Any state change attempted from inside that frame - including a
/// re-entrant settle - reverts at the EVM level. This mock exists to prove that
/// empirically rather than by assertion in a comment.
contract ReentrantOracle is IReserveOracle {
    address public target;
    address public victim;
    uint256 private _reserves;
    uint256 private _timestamp;

    constructor(uint256 reserves_, uint256 timestamp_) {
        _reserves = reserves_;
        _timestamp = timestamp_;
    }

    function arm(address target_, address victim_) external {
        target = target_;
        victim = victim_;
    }

    function attestedReserves() external view returns (uint256) {
        if (target != address(0)) ISettleLie(target).settle(victim, 1e6);
        return _reserves;
    }

    function attestationTimestamp() external view returns (uint256) {
        return _timestamp;
    }

    function attestationId() external pure returns (uint256) {
        return 1;
    }
}

/// @notice Test-only oracle whose `attestationId` always reverts, used to prove that
/// redemption (`redeem`) stays available when the oracle misbehaves.
contract BrokenOracle is IReserveOracle {
    uint256 private _reserves;
    uint256 private _timestamp;

    constructor(uint256 reserves_, uint256 timestamp_) {
        _reserves = reserves_;
        _timestamp = timestamp_;
    }

    function attestedReserves() external view returns (uint256) {
        return _reserves;
    }

    function attestationTimestamp() external view returns (uint256) {
        return _timestamp;
    }

    function attestationId() external pure returns (uint256) {
        revert("oracle down");
    }
}
