// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IReserveOracle} from "./interfaces/IReserveOracle.sol";

/// @title ArcSettlement - a USDC settlement rail that cannot settle past proven reserves.
/// @notice ArcSettle is a settlement layer for Arc, Circle's settlement chain, where the
/// reserve asset, the settled asset, and gas are the same regulated dollar (USDC). Every
/// settlement is gated by a reserve attestation: the transaction REVERTS if
/// `settledSupply + amount` would exceed the currently attested USDC reserves, if the
/// attestation is stale, or if it is dated in the future. Prove-before-settle, enforced
/// on-chain, so an autonomous treasury agent provably cannot settle past what has actually
/// been proven right now.
///
/// Balances are denominated in USDC's native 6 decimals, so "settled claims never exceed
/// attested USDC reserves" is expressed in one unit end to end with no unit-conversion seam.
///
/// Three properties a reviewer should check by reading this file:
///
///  1. The operator cannot conjure settlement headroom. The reserve oracle and the
///     freshness bound can only be changed through a two-step, `ORACLE_TIMELOCK`-delayed
///     proposal that is public the moment it is proposed, and `maxAttestationAge`
///     is clamped to [MIN_ATTESTATION_AGE, MAX_ATTESTATION_AGE] so freshness can
///     never be switched off.
///  2. Redemption does not silently reopen headroom. Redeeming frees settled supply but
///     the freed amount is booked as `pendingRedemptions` and subtracted from the
///     attested reserves until a NEW attestation (higher `attestationId`) lands
///     that has actually observed the USDC outflow.
///  3. Time is handled defensively. An attestation timestamp in the future reverts
///     instead of being treated as eternally fresh, and freshness is computed as
///     `block.timestamp - attestedAt` so no addition can overflow.
///
/// Self-contained (no external library) so the security surface is fully auditable
/// in one file: a minimal, correct ERC-20 settlement-claim token with checked arithmetic
/// (Solidity 0.8), explicit access control, custom errors, and events on every state change.
contract ArcSettlement {
    // --- settlement-claim token metadata (USDC-denominated, 6 decimals like USDC) ---
    string public constant name = "Arc Settled USDC Claim";
    string public constant symbol = "asUSDC";
    uint8 public constant decimals = 6;

    // --- guard rails on operator power ---
    /// @notice Delay between proposing and committing an oracle/freshness change.
    uint256 public constant ORACLE_TIMELOCK = 2 days;
    /// @notice A proposal must be committed within this window after its eta, so a
    /// forgotten proposal cannot be resurrected months later against a quiet chain.
    uint256 public constant ORACLE_PROPOSAL_GRACE = 7 days;
    /// @notice Freshness bound floor and ceiling. `maxAttestationAge` cannot leave
    /// this range, so "disable the freshness check" is not a reachable state.
    uint256 public constant MIN_ATTESTATION_AGE = 1 minutes;
    uint256 public constant MAX_ATTESTATION_AGE = 7 days;

    // --- settlement-claim state ---
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // --- access control ---
    address public owner;
    address public pendingOwner;
    mapping(address => bool) public isSettler;

    // --- reserve gate ---
    IReserveOracle public oracle;
    /// @notice Max age (seconds) an attestation may be before settlement is refused.
    uint256 public maxAttestationAge;

    // --- timelocked oracle rotation ---
    IReserveOracle public pendingOracle;
    uint256 public pendingMaxAttestationAge;
    uint256 public pendingOracleEta;

    // --- redemption accounting (see property 2 above) ---
    /// @notice Settled USDC claims redeemed that the current attestation has not yet accounted for.
    uint256 public pendingRedemptions;
    /// @notice The attestation id the outstanding `pendingRedemptions` were booked against.
    uint256 public redemptionDebtAttestationId;

    // --- events ---
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Settled(address indexed to, uint256 amount, uint256 newSupply, uint256 effectiveReserves, uint256 attestationId);
    event Redeemed(address indexed from, uint256 amount, uint256 pendingRedemptions);
    event RedemptionDebtCleared(uint256 amount, uint256 attestationId);
    event SettlerSet(address indexed settler, bool enabled);
    event OracleProposed(address indexed oracle, uint256 maxAge, uint256 eta);
    event OracleProposalCancelled(address indexed oracle);
    event OracleSet(address indexed oracle, uint256 maxAge);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    // --- errors ---
    error NotOwner();
    error NotPendingOwner();
    error NotSettler();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidMaxAge(uint256 maxAge);
    error InsufficientReserves(uint256 requested, uint256 available);
    error StaleAttestation(uint256 attestedAt, uint256 nowTs, uint256 maxAge);
    error FutureAttestation(uint256 attestedAt, uint256 nowTs);
    error InsufficientBalance();
    error InsufficientAllowance();
    error NoPendingOracle();
    error TimelockNotElapsed(uint256 eta, uint256 nowTs);
    error ProposalExpired(uint256 eta, uint256 nowTs);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlySettler() {
        if (!isSettler[msg.sender]) revert NotSettler();
        _;
    }

    constructor(IReserveOracle _oracle, uint256 _maxAttestationAge) {
        if (address(_oracle) == address(0)) revert ZeroAddress();
        if (_maxAttestationAge < MIN_ATTESTATION_AGE || _maxAttestationAge > MAX_ATTESTATION_AGE) {
            revert InvalidMaxAge(_maxAttestationAge);
        }
        owner = msg.sender;
        isSettler[msg.sender] = true;
        oracle = _oracle;
        maxAttestationAge = _maxAttestationAge;
        emit OwnershipTransferred(address(0), msg.sender);
        emit SettlerSet(msg.sender, true);
        emit OracleSet(address(_oracle), _maxAttestationAge);
    }

    // --- the reserve-gated settlement (the core of the design) ---

    /// @notice Reserves usable for settlement right now: attested USDC reserves minus any
    /// redemption outflow the current attestation has not yet seen.
    /// @return 0 when the attestation is unusable (stale or future dated), so a
    /// caller reading this view can never be told there is headroom when `settle`
    /// would revert.
    function effectiveReserves() public view returns (uint256) {
        uint256 attestedAt = oracle.attestationTimestamp();
        if (attestedAt > block.timestamp) return 0;
        if (block.timestamp - attestedAt > maxAttestationAge) return 0;
        uint256 reserves = oracle.attestedReserves();
        uint256 debt = oracle.attestationId() > redemptionDebtAttestationId ? 0 : pendingRedemptions;
        return reserves > debt ? reserves - debt : 0;
    }

    /// @notice How much more USDC can be settled right now given the current attestation.
    function settleableHeadroom() public view returns (uint256) {
        uint256 effective = effectiveReserves();
        uint256 supply = totalSupply;
        return effective > supply ? effective - supply : 0;
    }

    /// @notice Settle `amount` USDC of claim to `to`, but only if proven reserves cover
    /// the new settled supply.
    /// @dev Reverts with InsufficientReserves if it would exceed effective reserves,
    /// StaleAttestation if the proof is older than `maxAttestationAge`, or
    /// FutureAttestation if the proof is dated ahead of the current block.
    function settle(address to, uint256 amount) external onlySettler {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 attestedAt = oracle.attestationTimestamp();
        if (attestedAt > block.timestamp) revert FutureAttestation(attestedAt, block.timestamp);
        // Subtraction, not `attestedAt + maxAge`: the addition can overflow, this cannot.
        if (block.timestamp - attestedAt > maxAttestationAge) {
            revert StaleAttestation(attestedAt, block.timestamp, maxAttestationAge);
        }

        uint256 reserves = oracle.attestedReserves();
        uint256 attId = oracle.attestationId();

        // A newer attestation has landed: it already reflects the USDC released
        // by earlier redemptions, so the booked redemption debt is discharged.
        uint256 debt = pendingRedemptions;
        if (debt != 0 && attId > redemptionDebtAttestationId) {
            pendingRedemptions = 0;
            emit RedemptionDebtCleared(debt, attId);
            debt = 0;
        }
        uint256 effective = reserves > debt ? reserves - debt : 0;

        uint256 supply = totalSupply;
        uint256 newSupply = supply + amount;
        if (newSupply > effective) {
            revert InsufficientReserves(amount, effective > supply ? effective - supply : 0);
        }

        totalSupply = newSupply;
        unchecked {
            balanceOf[to] += amount; // cannot overflow: bounded by totalSupply
        }
        emit Settled(to, amount, newSupply, effective, attId);
        emit Transfer(address(0), to, amount);
    }

    /// @notice Redeem `amount` from the caller (settle the claim back out of circulation).
    /// @dev Redemption frees settled supply but NOT settlement headroom. The redeemed
    /// amount is booked as redemption debt and netted off attested reserves until a newer
    /// attestation proves the post-redemption USDC balance. Without this, a
    /// redeem-then-resettle loop against one stale attestation would leave settled claims
    /// backed by USDC that has already left the reserve.
    function redeem(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = balanceOf[msg.sender];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[msg.sender] = bal - amount;
            totalSupply -= amount;
        }

        // Redemption must never be blocked by a misbehaving oracle, so this read is
        // fault tolerant: on failure we keep the existing debt id, which is the
        // conservative choice (debt accumulates, headroom stays shut).
        uint256 attId = redemptionDebtAttestationId;
        try oracle.attestationId() returns (uint256 id) {
            attId = id;
        } catch {}

        if (attId > redemptionDebtAttestationId) {
            redemptionDebtAttestationId = attId;
            pendingRedemptions = amount;
        } else {
            pendingRedemptions += amount;
        }

        emit Redeemed(msg.sender, amount, pendingRedemptions);
        emit Transfer(msg.sender, address(0), amount);
    }

    // --- ERC-20 ---

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
        return true;
    }

    // --- admin ---

    function setSettler(address settler, bool enabled) external onlyOwner {
        if (settler == address(0)) revert ZeroAddress();
        isSettler[settler] = enabled;
        emit SettlerSet(settler, enabled);
    }

    /// @notice Step 1 of an oracle / freshness change. Public from this moment;
    /// holders have `ORACLE_TIMELOCK` to react before it can take effect.
    function proposeOracle(IReserveOracle _oracle, uint256 _maxAge) external onlyOwner {
        if (address(_oracle) == address(0)) revert ZeroAddress();
        if (_maxAge < MIN_ATTESTATION_AGE || _maxAge > MAX_ATTESTATION_AGE) revert InvalidMaxAge(_maxAge);
        uint256 eta = block.timestamp + ORACLE_TIMELOCK;
        pendingOracle = _oracle;
        pendingMaxAttestationAge = _maxAge;
        pendingOracleEta = eta;
        emit OracleProposed(address(_oracle), _maxAge, eta);
    }

    /// @notice Step 2, only after the timelock has elapsed.
    function commitOracle() external onlyOwner {
        IReserveOracle next = pendingOracle;
        if (address(next) == address(0)) revert NoPendingOracle();
        uint256 eta = pendingOracleEta;
        if (block.timestamp < eta) revert TimelockNotElapsed(eta, block.timestamp);
        if (block.timestamp > eta + ORACLE_PROPOSAL_GRACE) revert ProposalExpired(eta, block.timestamp);
        uint256 maxAge = pendingMaxAttestationAge;
        oracle = next;
        maxAttestationAge = maxAge;
        delete pendingOracle;
        delete pendingMaxAttestationAge;
        delete pendingOracleEta;
        emit OracleSet(address(next), maxAge);
    }

    function cancelOracle() external onlyOwner {
        IReserveOracle next = pendingOracle;
        if (address(next) == address(0)) revert NoPendingOracle();
        delete pendingOracle;
        delete pendingMaxAttestationAge;
        delete pendingOracleEta;
        emit OracleProposalCancelled(address(next));
    }

    /// @notice Two-step ownership handover: a typo cannot orphan the contract.
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
