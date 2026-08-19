// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IReserveOracle} from "./interfaces/IReserveOracle.sol";

/// @title ReserveAttestationOracle - a proof-of-reserves oracle that only moves on a
/// verified proof.
/// @notice USDC reserve figures do not enter this contract because a privileged account
/// says so. They enter because someone presents an EIP-712 signature from a registered
/// attestor over `(reserves, attestedAt, nonce)`. The contract recovers the signer
/// on-chain, rejects unknown signers, rejects replays via a strictly incrementing nonce,
/// rejects backdated or future-dated attestations, and rejects malleable signatures.
///
/// Submission is permissionless: anyone can relay an attestor's signed attestation,
/// so liveness does not depend on one relayer's key. The attestor set is the only
/// trust assumption, and it is asymmetrically governed: ADDING an attestor (the
/// direction that could prove reserves out of nothing) is a two-step, `ATTESTOR_TIMELOCK`
/// delayed, publicly announced change. REMOVING one (the direction that can only
/// reduce what the oracle will believe) is immediate, because a compromised key
/// must be revocable in the same block it is discovered.
contract ReserveAttestationOracle is IReserveOracle {
    // --- EIP-712 ---
    bytes32 public constant ATTESTATION_TYPEHASH =
        keccak256("ReserveAttestation(uint256 reserves,uint256 attestedAt,uint256 nonce)");
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /// @dev secp256k1 group order / 2, for the low-s malleability check.
    uint256 private constant _HALF_ORDER = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    /// @notice Delay between announcing a new attestor and it being able to sign.
    uint256 public constant ATTESTOR_TIMELOCK = 2 days;
    /// @notice An announced attestor that is not confirmed within this window after
    /// its eta expires, so a forgotten proposal cannot be revived years later.
    uint256 public constant ATTESTOR_GRACE = 7 days;

    bytes32 public immutable DOMAIN_SEPARATOR;

    // --- state ---
    address public owner;
    address public pendingOwner;
    mapping(address => bool) public isAttestor;
    /// @notice Timestamp at which an announced attestor may be confirmed. 0 = none.
    mapping(address => uint256) public attestorEta;

    uint256 private _reserves;
    uint256 private _attestedAt;
    uint256 private _attestationId;
    /// @notice Last consumed attestation nonce. The next must be exactly this + 1.
    uint256 public nonce;

    // --- events ---
    event AttestorSet(address indexed attestor, bool enabled);
    event AttestorAnnounced(address indexed attestor, uint256 eta);
    event AttestorAnnouncementCancelled(address indexed attestor);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);
    event AttestationAccepted(
        address indexed attestor, uint256 reserves, uint256 attestedAt, uint256 nonce, uint256 attestationId
    );

    // --- errors ---
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error BadSignatureLength(uint256 length);
    error MalleableSignature();
    error BadSignatureV(uint8 v);
    error UnknownAttestor(address recovered);
    error BadNonce(uint256 expected, uint256 supplied);
    error FutureAttestation(uint256 attestedAt, uint256 nowTs);
    error StaleAttestationSupplied(uint256 attestedAt, uint256 lastAttestedAt);
    error NoAnnouncement(address attestor);
    error AlreadyAttestor(address attestor);
    error TimelockNotElapsed(uint256 eta, uint256 nowTs);
    error AnnouncementExpired(uint256 eta, uint256 nowTs);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param attestor The first registered attestor. Required: an oracle with an
    /// empty attestor set can never accept a proof, so it is a deployment error.
    constructor(address attestor) {
        if (attestor == address(0)) revert ZeroAddress();
        owner = msg.sender;
        isAttestor[attestor] = true;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                _EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("ArcSettle Reserve Oracle")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
        emit OwnershipTransferred(address(0), msg.sender);
        emit AttestorSet(attestor, true);
    }

    // --- IReserveOracle ---

    function attestedReserves() external view returns (uint256) {
        return _reserves;
    }

    function attestationTimestamp() external view returns (uint256) {
        return _attestedAt;
    }

    function attestationId() external view returns (uint256) {
        return _attestationId;
    }

    // --- the proof path ---

    /// @notice Hash that an attestor signs (EIP-712 typed data).
    function attestationDigest(uint256 reserves, uint256 attestedAt, uint256 attestationNonce)
        public
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(ATTESTATION_TYPEHASH, reserves, attestedAt, attestationNonce));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    /// @notice Accept a USDC reserve attestation if and only if it carries a valid
    /// signature from a registered attestor over a fresh, unreplayed nonce.
    /// @dev Callable by anyone; the signature, not the caller, is the authority.
    function submitAttestation(uint256 reserves, uint256 attestedAt, uint256 attestationNonce, bytes calldata signature)
        external
    {
        uint256 expected = nonce + 1;
        if (attestationNonce != expected) revert BadNonce(expected, attestationNonce);
        if (attestedAt > block.timestamp) revert FutureAttestation(attestedAt, block.timestamp);
        if (attestedAt <= _attestedAt) revert StaleAttestationSupplied(attestedAt, _attestedAt);

        address signer = _recover(attestationDigest(reserves, attestedAt, attestationNonce), signature);
        if (!isAttestor[signer]) revert UnknownAttestor(signer);

        _reserves = reserves;
        _attestedAt = attestedAt;
        nonce = attestationNonce;
        uint256 id = _attestationId + 1;
        _attestationId = id;
        emit AttestationAccepted(signer, reserves, attestedAt, attestationNonce, id);
    }

    /// @dev ecrecover with the three checks people forget: length, v range, low-s.
    /// Returns a non-zero address or reverts; it never returns address(0).
    function _recover(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) revert BadSignatureLength(signature.length);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (uint256(s) > _HALF_ORDER) revert MalleableSignature();
        if (v != 27 && v != 28) revert BadSignatureV(v);
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert UnknownAttestor(address(0));
        return signer;
    }

    // --- admin (attestor set only; it can never set reserves directly) ---

    /// @notice Step 1 of adding an attestor. Public the moment it is announced;
    /// settlement holders have `ATTESTOR_TIMELOCK` to react before the key can sign.
    function announceAttestor(address attestor) external onlyOwner {
        if (attestor == address(0)) revert ZeroAddress();
        if (isAttestor[attestor]) revert AlreadyAttestor(attestor);
        uint256 eta = block.timestamp + ATTESTOR_TIMELOCK;
        attestorEta[attestor] = eta;
        emit AttestorAnnounced(attestor, eta);
    }

    /// @notice Step 2, only after the timelock and only inside the grace window.
    /// @dev Permissionless on purpose: the announcement is the authorising act, and
    /// the delay is what protects holders. Anyone may finish the (already public) job.
    function confirmAttestor(address attestor) external {
        uint256 eta = attestorEta[attestor];
        if (eta == 0) revert NoAnnouncement(attestor);
        if (block.timestamp < eta) revert TimelockNotElapsed(eta, block.timestamp);
        if (block.timestamp > eta + ATTESTOR_GRACE) revert AnnouncementExpired(eta, block.timestamp);
        delete attestorEta[attestor];
        isAttestor[attestor] = true;
        emit AttestorSet(attestor, true);
    }

    function cancelAttestor(address attestor) external onlyOwner {
        if (attestorEta[attestor] == 0) revert NoAnnouncement(attestor);
        delete attestorEta[attestor];
        emit AttestorAnnouncementCancelled(attestor);
    }

    /// @notice Revoke an attestor immediately. Removal only ever shrinks what this
    /// oracle will believe, so it is not delayed: a leaked key is revocable now.
    function revokeAttestor(address attestor) external onlyOwner {
        isAttestor[attestor] = false;
        delete attestorEta[attestor];
        emit AttestorSet(attestor, false);
    }

    /// @notice Two-step ownership handover: a typo cannot orphan the oracle.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }
}
