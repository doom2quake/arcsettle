// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReserveAttestationOracle} from "../src/ReserveAttestationOracle.sol";
import {ArcSettlement} from "../src/ArcSettlement.sol";
import {IReserveOracle} from "../src/interfaces/IReserveOracle.sol";

interface Vm {
    function warp(uint256) external;
    function prank(address) external;
    function addr(uint256 privateKey) external returns (address);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8, bytes32, bytes32);
    function expectRevert(bytes4) external;
    function expectPartialRevert(bytes4) external;
}

/// @notice The proof path. USDC reserve figures enter this oracle only against a valid
/// EIP-712 signature from a registered attestor, and the attestor set itself is
/// timelocked in the one direction that could manufacture trust. Amounts are 6-decimal USDC.
contract ReserveAttestationOracleTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    /// @dev secp256k1 group order, for the malleability test.
    uint256 constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    ReserveAttestationOracle oracle;
    uint256 attestorKey = 0xA11CE;
    uint256 outsiderKey = 0xBAD;
    address attestor;
    address outsider;

    function setUp() public {
        attestor = vm.addr(attestorKey);
        outsider = vm.addr(outsiderKey);
        vm.warp(1_700_000_000);
        oracle = new ReserveAttestationOracle(attestor);
    }

    function _sign(uint256 key, uint256 reserves, uint256 attestedAt, uint256 nonce_)
        internal
        returns (bytes memory)
    {
        bytes32 digest = oracle.attestationDigest(reserves, attestedAt, nonce_);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    // --- the happy path is a real signature check ------------------------------

    function test_ValidAttestationIsAccepted() public {
        uint256 ts = block.timestamp;
        oracle.submitAttestation(1_000_000e6, ts, 1, _sign(attestorKey, 1_000_000e6, ts, 1));
        require(oracle.attestedReserves() == 1_000_000e6, "reserves");
        require(oracle.attestationTimestamp() == ts, "timestamp");
        require(oracle.attestationId() == 1, "id");
        require(oracle.nonce() == 1, "nonce consumed");
    }

    /// Submission is permissionless: the signature is the authority, not the caller.
    function test_AnyoneMayRelayASignedAttestation() public {
        uint256 ts = block.timestamp;
        bytes memory sig = _sign(attestorKey, 1_000_000e6, ts, 1);
        vm.prank(address(0xDEAD));
        oracle.submitAttestation(1_000_000e6, ts, 1, sig);
        require(oracle.attestedReserves() == 1_000_000e6, "relayed attestation accepted");
    }

    function test_AttestationIdIncrementsPerAcceptedProof() public {
        uint256 ts = block.timestamp;
        oracle.submitAttestation(1e6, ts, 1, _sign(attestorKey, 1e6, ts, 1));
        vm.warp(ts + 1);
        oracle.submitAttestation(2e6, ts + 1, 2, _sign(attestorKey, 2e6, ts + 1, 2));
        require(oracle.attestationId() == 2, "id increments once per proof");
    }

    // --- everything a forger might try ----------------------------------------

    function test_UnknownAttestorRejected() public {
        uint256 ts = block.timestamp;
        bytes memory sig = _sign(outsiderKey, 9_000_000e6, ts, 1);
        vm.expectPartialRevert(ReserveAttestationOracle.UnknownAttestor.selector);
        oracle.submitAttestation(9_000_000e6, ts, 1, sig);
    }

    /// Re-signing over different numbers than were submitted must not verify.
    function test_TamperedAmountRejected() public {
        uint256 ts = block.timestamp;
        bytes memory sig = _sign(attestorKey, 1_000_000e6, ts, 1);
        vm.expectPartialRevert(ReserveAttestationOracle.UnknownAttestor.selector);
        oracle.submitAttestation(9_000_000e6, ts, 1, sig); // the signature covers 1M, not 9M
    }

    function test_ReplayRejectedByNonce() public {
        uint256 ts = block.timestamp;
        bytes memory sig = _sign(attestorKey, 1_000_000e6, ts, 1);
        oracle.submitAttestation(1_000_000e6, ts, 1, sig);
        vm.expectPartialRevert(ReserveAttestationOracle.BadNonce.selector);
        oracle.submitAttestation(1_000_000e6, ts, 1, sig);
    }

    function test_NonceMustBeExactlyNext() public {
        uint256 ts = block.timestamp;
        bytes memory sig = _sign(attestorKey, 1e6, ts, 2);
        vm.expectPartialRevert(ReserveAttestationOracle.BadNonce.selector);
        oracle.submitAttestation(1e6, ts, 2, sig);
    }

    /// A signature (v, r, s) has a twin (v', r, N - s) that recovers the same signer.
    /// Accepting both would let the same proof be counted under two distinct blobs.
    function test_MalleableSignatureRejected() public {
        uint256 ts = block.timestamp;
        bytes32 digest = oracle.attestationDigest(1_000_000e6, ts, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestorKey, digest);
        bytes32 flipped = bytes32(N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        vm.expectRevert(ReserveAttestationOracle.MalleableSignature.selector);
        oracle.submitAttestation(1_000_000e6, ts, 1, abi.encodePacked(r, flipped, flippedV));
    }

    function test_BadSignatureLengthRejected() public {
        vm.expectPartialRevert(ReserveAttestationOracle.BadSignatureLength.selector);
        oracle.submitAttestation(1e6, block.timestamp, 1, hex"deadbeef");
    }

    function test_BadSignatureVRejected() public {
        uint256 ts = block.timestamp;
        bytes32 digest = oracle.attestationDigest(1e6, ts, 1);
        (, bytes32 r, bytes32 s) = vm.sign(attestorKey, digest);
        vm.expectPartialRevert(ReserveAttestationOracle.BadSignatureV.selector);
        oracle.submitAttestation(1e6, ts, 1, abi.encodePacked(r, s, uint8(29)));
    }

    function test_FutureDatedAttestationRejected() public {
        uint256 ts = block.timestamp + 1;
        bytes memory sig = _sign(attestorKey, 1e6, ts, 1);
        vm.expectPartialRevert(ReserveAttestationOracle.FutureAttestation.selector);
        oracle.submitAttestation(1e6, ts, 1, sig);
    }

    /// A newer nonce carrying an older reserve reading would rewind the proof clock.
    function test_BackdatedAttestationRejected() public {
        uint256 ts = block.timestamp;
        oracle.submitAttestation(1e6, ts, 1, _sign(attestorKey, 1e6, ts, 1));
        bytes memory sig = _sign(attestorKey, 5e6, ts - 1, 2);
        vm.expectPartialRevert(ReserveAttestationOracle.StaleAttestationSupplied.selector);
        oracle.submitAttestation(5e6, ts - 1, 2, sig);
    }

    /// The domain separator binds the digest to this chain and this address, so an
    /// attestation signed for another deployment cannot be replayed here.
    function test_DigestIsBoundToChainAndContract() public {
        ReserveAttestationOracle other = new ReserveAttestationOracle(attestor);
        require(
            oracle.attestationDigest(1e6, 1, 1) != other.attestationDigest(1e6, 1, 1),
            "digest must differ per deployment"
        );
        uint256 ts = block.timestamp;
        bytes32 digest = other.attestationDigest(1e6, ts, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestorKey, digest);
        vm.expectPartialRevert(ReserveAttestationOracle.UnknownAttestor.selector);
        oracle.submitAttestation(1e6, ts, 1, abi.encodePacked(r, s, v));
    }

    // --- the attestor set is the trust root, so adding to it is delayed --------

    function test_OwnerCannotAddAnAttestorInstantly() public {
        oracle.announceAttestor(outsider);
        require(!oracle.isAttestor(outsider), "not yet an attestor");
        uint256 ts = block.timestamp;
        bytes memory sig = _sign(outsiderKey, 9_000_000e6, ts, 1);
        vm.expectPartialRevert(ReserveAttestationOracle.UnknownAttestor.selector);
        oracle.submitAttestation(9_000_000e6, ts, 1, sig);
    }

    function test_ConfirmBeforeTimelockReverts() public {
        oracle.announceAttestor(outsider);
        vm.warp(block.timestamp + 2 days - 1);
        vm.expectPartialRevert(ReserveAttestationOracle.TimelockNotElapsed.selector);
        oracle.confirmAttestor(outsider);
    }

    function test_ConfirmAfterTimelockAddsTheAttestor() public {
        oracle.announceAttestor(outsider);
        vm.warp(block.timestamp + 2 days);
        oracle.confirmAttestor(outsider);
        require(oracle.isAttestor(outsider), "attestor added after the delay");
        uint256 ts = block.timestamp;
        oracle.submitAttestation(5e6, ts, 1, _sign(outsiderKey, 5e6, ts, 1));
        require(oracle.attestedReserves() == 5e6, "new attestor can sign");
    }

    function test_AnnouncementExpiresAfterGrace() public {
        oracle.announceAttestor(outsider);
        vm.warp(block.timestamp + 2 days + 7 days + 1);
        vm.expectPartialRevert(ReserveAttestationOracle.AnnouncementExpired.selector);
        oracle.confirmAttestor(outsider);
    }

    function test_CancelledAnnouncementCannotBeConfirmed() public {
        oracle.announceAttestor(outsider);
        oracle.cancelAttestor(outsider);
        vm.warp(block.timestamp + 2 days);
        vm.expectPartialRevert(ReserveAttestationOracle.NoAnnouncement.selector);
        oracle.confirmAttestor(outsider);
    }

    function test_ConfirmWithoutAnnouncementReverts() public {
        vm.expectPartialRevert(ReserveAttestationOracle.NoAnnouncement.selector);
        oracle.confirmAttestor(outsider);
    }

    function test_NonOwnerCannotAnnounceAttestor() public {
        vm.prank(outsider);
        vm.expectRevert(ReserveAttestationOracle.NotOwner.selector);
        oracle.announceAttestor(outsider);
    }

    /// Revocation shrinks what the oracle believes, so it is immediate by design.
    function test_RevocationIsImmediate() public {
        oracle.revokeAttestor(attestor);
        require(!oracle.isAttestor(attestor), "revoked");
        uint256 ts = block.timestamp;
        bytes memory sig = _sign(attestorKey, 1e6, ts, 1);
        vm.expectPartialRevert(ReserveAttestationOracle.UnknownAttestor.selector);
        oracle.submitAttestation(1e6, ts, 1, sig);
    }

    function test_OwnershipHandoverIsTwoStep() public {
        oracle.transferOwnership(outsider);
        require(oracle.owner() == address(this), "unchanged until accepted");
        vm.prank(outsider);
        oracle.acceptOwnership();
        require(oracle.owner() == outsider, "handed over");
    }

    // --- end to end: signed proof -> settlement headroom ----------------------

    /// The full Arc path in one test: an attestor signs a USDC reserve figure, the
    /// oracle verifies the signature on-chain, and only then can a claim be settled,
    /// bounded by exactly that figure and not one unit more.
    function test_SignedProofUnlocksSettleAndBoundsIt() public {
        ArcSettlement arc = new ArcSettlement(IReserveOracle(address(oracle)), 1 days);
        require(arc.settleableHeadroom() == 0, "no proof yet, no headroom");

        uint256 ts = block.timestamp;
        oracle.submitAttestation(1_000_000e6, ts, 1, _sign(attestorKey, 1_000_000e6, ts, 1));
        require(arc.settleableHeadroom() == 1_000_000e6, "proof opened exactly its own headroom");

        arc.settle(address(0xA11CE), 1_000_000e6);
        vm.expectPartialRevert(ArcSettlement.InsufficientReserves.selector);
        arc.settle(address(0xA11CE), 1);

        // The proof goes stale, and the gate shuts again on its own.
        vm.warp(ts + 1 days + 1);
        require(arc.settleableHeadroom() == 0, "stale proof, no headroom");
    }
}
