// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ArcSettlement} from "../src/ArcSettlement.sol";
import {IReserveOracle} from "../src/interfaces/IReserveOracle.sol";
import {MockReserveOracle, BrokenOracle, ReentrantOracle} from "../src/mocks/MockReserveOracle.sol";

/// Minimal cheatcode interface so the suite is self-contained (no forge-std needed).
interface Vm {
    function warp(uint256) external;
    function prank(address) external;
    function expectRevert(bytes4) external;         // full-data match (errors without args)
    function expectPartialRevert(bytes4) external;  // selector-only match (errors with args)
    function expectRevert() external;
}

/// @notice The settlement gate, and every way a reviewer might try to get around it.
///
/// Each test below pins one specific defence. Delete the defence in
/// `src/ArcSettlement.sol` and the matching test goes red. Amounts are 6-decimal USDC.
contract ArcSettlementTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    ArcSettlement arc;
    MockReserveOracle att;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        // 1,000,000 USDC of reserves attested "now" (timestamp 1000).
        att = new MockReserveOracle(1_000_000e6, 1000);
        vm.warp(1000);
        arc = new ArcSettlement(att, 1 days);
    }

    // --- the hero: settled supply can never exceed proven USDC reserves ---------

    function test_SettleWithinReservesSucceeds() public {
        arc.settle(alice, 800_000e6);
        require(arc.balanceOf(alice) == 800_000e6, "balance");
        require(arc.totalSupply() == 800_000e6, "supply");
        require(arc.settleableHeadroom() == 200_000e6, "headroom");
    }

    function test_SettlePastReservesReverts() public {
        arc.settle(alice, 1_000_000e6); // exactly at reserves: ok
        vm.expectPartialRevert(ArcSettlement.InsufficientReserves.selector);
        arc.settle(alice, 1); // one unit past reserves: reverts
    }

    function test_SettleExactlyAtReservesSucceeds() public {
        arc.settle(alice, 1_000_000e6);
        require(arc.totalSupply() == 1_000_000e6, "supply at cap");
        require(arc.settleableHeadroom() == 0, "no headroom");
    }

    function test_ReservesIncreaseRaisesHeadroom() public {
        arc.settle(alice, 1_000_000e6);
        att.setReserves(1_500_000e6, 1000);
        require(arc.settleableHeadroom() == 500_000e6, "new headroom");
        arc.settle(alice, 500_000e6); // now allowed
        require(arc.totalSupply() == 1_500_000e6, "supply grew with reserves");
    }

    function test_SettleZeroReverts() public {
        vm.expectRevert(ArcSettlement.ZeroAmount.selector);
        arc.settle(alice, 0);
    }

    function test_SettleToZeroAddressReverts() public {
        vm.expectRevert(ArcSettlement.ZeroAddress.selector);
        arc.settle(address(0), 1e6);
    }

    function test_NonSettlerCannotSettle() public {
        vm.prank(alice);
        vm.expectRevert(ArcSettlement.NotSettler.selector);
        arc.settle(alice, 1e6);
    }

    // --- freshness: stale, future dated, and extreme timestamps ---------------

    function test_StaleAttestationReverts() public {
        vm.warp(1000 + 1 days + 1); // attestation older than maxAge
        vm.expectPartialRevert(ArcSettlement.StaleAttestation.selector);
        arc.settle(alice, 1e6);
    }

    /// A timestamp accidentally supplied in milliseconds is decades in the future.
    /// Without the explicit future check it would read as "fresh" forever.
    function test_FutureAttestationReverts() public {
        att.restateWithoutNewProof(1_000_000e6, block.timestamp + 1);
        vm.expectPartialRevert(ArcSettlement.FutureAttestation.selector);
        arc.settle(alice, 1e6);
    }

    function test_MillisecondTimestampIsRejectedNotTrusted() public {
        att.restateWithoutNewProof(1_000_000e6, 1000 * 1000); // seconds mistaken for ms
        vm.expectPartialRevert(ArcSettlement.FutureAttestation.selector);
        arc.settle(alice, 1e6);
    }

    /// `attestedAt + maxAge` would panic on overflow. Freshness is computed with a
    /// subtraction, so the extreme value is a clean revert, not a DoS panic.
    function test_ExtremeTimestampRevertsCleanlyWithoutOverflowPanic() public {
        att.restateWithoutNewProof(1_000_000e6, type(uint256).max);
        vm.expectPartialRevert(ArcSettlement.FutureAttestation.selector);
        arc.settle(alice, 1e6);
        require(arc.effectiveReserves() == 0, "view must not panic on extreme ts");
    }

    /// The view must never advertise headroom that `settle` would refuse.
    function test_ViewsReportZeroWhenAttestationUnusable() public {
        vm.warp(1000 + 1 days + 1);
        require(arc.effectiveReserves() == 0, "stale -> 0 effective");
        require(arc.settleableHeadroom() == 0, "stale -> 0 headroom");
    }

    // --- redemption cannot reopen headroom before reserves fall ---------------

    /// Redeeming frees settled supply. It must NOT free settlement capacity, because
    /// the USDC that backed the redeemed claims is on its way out of the reserve.
    function test_RedeemDoesNotReopenHeadroom() public {
        arc.settle(alice, 1_000_000e6);
        require(arc.settleableHeadroom() == 0, "at cap before redeem");
        vm.prank(alice);
        arc.redeem(400_000e6);
        require(arc.totalSupply() == 600_000e6, "supply after redeem");
        require(arc.pendingRedemptions() == 400_000e6, "redemption debt booked");
        require(arc.settleableHeadroom() == 0, "headroom must stay shut");
    }

    /// The exact attack from the review: 1M settled against 1M reserves, redeem 400k,
    /// move 400k of USDC out off chain, then re-settle 400k against the OLD proof.
    /// That would leave 1M of settled claims backed by 600k. It must revert.
    function test_RedeemThenResettleAgainstOldAttestationReverts() public {
        arc.settle(alice, 1_000_000e6);
        vm.prank(alice);
        arc.redeem(400_000e6);
        // Operator restates the same proof (no new attestation id) after moving
        // the released USDC out. Supply is 600k, reserves still "read" 1M.
        att.restateWithoutNewProof(1_000_000e6, 1000);
        vm.expectPartialRevert(ArcSettlement.InsufficientReserves.selector);
        arc.settle(bob, 400_000e6);
        require(arc.totalSupply() == 600_000e6, "supply unchanged after refusal");
    }

    /// A genuinely NEW attestation has observed the post-redemption balance, so it
    /// discharges the debt and headroom reopens to whatever it now proves.
    function test_NewAttestationClearsRedemptionDebt() public {
        arc.settle(alice, 1_000_000e6);
        vm.prank(alice);
        arc.redeem(400_000e6);
        require(arc.settleableHeadroom() == 0, "shut while debt outstanding");
        att.setReserves(600_000e6, 1000); // bumps attestationId: the outflow is proven
        require(arc.settleableHeadroom() == 0, "600k reserves back 600k supply exactly");
        att.setReserves(1_000_000e6, 1000); // fresh capital proven in
        require(arc.settleableHeadroom() == 400_000e6, "headroom reopens on new proof");
        arc.settle(bob, 400_000e6);
        require(arc.totalSupply() == 1_000_000e6, "supply matches proven reserves");
        require(arc.pendingRedemptions() == 0, "debt discharged");
    }

    function test_SuccessiveRedemptionsAccumulateDebtUnderOneAttestation() public {
        arc.settle(alice, 1_000_000e6);
        vm.prank(alice);
        arc.redeem(200_000e6);
        vm.prank(alice);
        arc.redeem(300_000e6);
        require(arc.pendingRedemptions() == 500_000e6, "debt accumulates");
        require(arc.effectiveReserves() == 500_000e6, "reserves netted down");
        require(arc.settleableHeadroom() == 0, "no headroom");
    }

    function test_RedeemMoreThanBalanceReverts() public {
        arc.settle(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(ArcSettlement.InsufficientBalance.selector);
        arc.redeem(101e6);
    }

    /// Redemption must stay available even when the oracle is down, and the failure
    /// must be conservative: debt still accrues, headroom stays shut.
    function test_RedeemSurvivesBrokenOracleAndStaysConservative() public {
        BrokenOracle broken = new BrokenOracle(1_000_000e6, 1000);
        // Seed supply while a working oracle is in place (settle reads attestationId),
        // then rotate the broken oracle in through the timelock.
        ArcSettlement arc2 = new ArcSettlement(att, 1 days);
        arc2.settle(alice, 1_000_000e6);
        arc2.proposeOracle(IReserveOracle(address(broken)), 1 days);
        vm.warp(block.timestamp + 2 days);
        arc2.commitOracle();

        vm.prank(alice);
        arc2.redeem(400_000e6); // must not revert even though attestationId() reverts
        require(arc2.totalSupply() == 600_000e6, "redemption succeeded");
        require(arc2.pendingRedemptions() == 400_000e6, "debt booked conservatively");
    }

    // --- operator cannot conjure headroom -------------------------------------

    /// The review's finding: swap the oracle for one that reports anything, settle.
    /// The swap is now a two-step timelocked change, so step one alone does nothing.
    function test_OwnerCannotSwapOracleInstantly() public {
        MockReserveOracle liar = new MockReserveOracle(type(uint128).max, 1000);
        arc.proposeOracle(IReserveOracle(address(liar)), 1 days);
        require(address(arc.oracle()) == address(att), "oracle unchanged on propose");
        require(arc.settleableHeadroom() == 1_000_000e6, "headroom still from the old proof");
        vm.expectPartialRevert(ArcSettlement.InsufficientReserves.selector);
        arc.settle(alice, 2_000_000e6);
    }

    function test_CommitBeforeTimelockReverts() public {
        MockReserveOracle liar = new MockReserveOracle(type(uint128).max, 1000);
        arc.proposeOracle(IReserveOracle(address(liar)), 1 days);
        vm.warp(block.timestamp + 2 days - 1);
        vm.expectPartialRevert(ArcSettlement.TimelockNotElapsed.selector);
        arc.commitOracle();
    }

    function test_CommitAfterTimelockSucceeds() public {
        MockReserveOracle next = new MockReserveOracle(2_000_000e6, 1000);
        arc.proposeOracle(IReserveOracle(address(next)), 1 days);
        vm.warp(block.timestamp + 2 days);
        next.restateWithoutNewProof(2_000_000e6, block.timestamp);
        arc.commitOracle();
        require(address(arc.oracle()) == address(next), "oracle rotated after delay");
        require(arc.settleableHeadroom() == 2_000_000e6, "new proof in force");
    }

    /// A forgotten proposal must not be committable a year later.
    function test_ExpiredProposalCannotBeCommitted() public {
        MockReserveOracle next = new MockReserveOracle(2_000_000e6, 1000);
        arc.proposeOracle(IReserveOracle(address(next)), 1 days);
        vm.warp(block.timestamp + 2 days + 7 days + 1);
        vm.expectPartialRevert(ArcSettlement.ProposalExpired.selector);
        arc.commitOracle();
    }

    function test_CancelledProposalCannotBeCommitted() public {
        MockReserveOracle next = new MockReserveOracle(2_000_000e6, 1000);
        arc.proposeOracle(IReserveOracle(address(next)), 1 days);
        arc.cancelOracle();
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(ArcSettlement.NoPendingOracle.selector);
        arc.commitOracle();
    }

    /// "Disable freshness with maxAge = 0" is not a reachable state.
    function test_FreshnessCannotBeDisabled() public {
        vm.expectPartialRevert(ArcSettlement.InvalidMaxAge.selector);
        arc.proposeOracle(att, 0);
    }

    function test_FreshnessCannotExceedCeiling() public {
        vm.expectPartialRevert(ArcSettlement.InvalidMaxAge.selector);
        arc.proposeOracle(att, 7 days + 1);
    }

    function test_NonOwnerCannotProposeOracle() public {
        vm.prank(alice);
        vm.expectRevert(ArcSettlement.NotOwner.selector);
        arc.proposeOracle(att, 1 days);
    }

    function test_NonOwnerCannotSetSettler() public {
        vm.prank(alice);
        vm.expectRevert(ArcSettlement.NotOwner.selector);
        arc.setSettler(alice, true);
    }

    /// Even a freshly appointed settler is still bounded by the proof.
    function test_NewSettlerIsStillReserveBounded() public {
        arc.setSettler(alice, true);
        vm.prank(alice);
        arc.settle(alice, 1_000_000e6);
        vm.prank(alice);
        vm.expectPartialRevert(ArcSettlement.InsufficientReserves.selector);
        arc.settle(alice, 1);
    }

    function test_OwnershipHandoverIsTwoStep() public {
        arc.transferOwnership(alice);
        require(arc.owner() == address(this), "owner unchanged until accepted");
        vm.prank(bob);
        vm.expectRevert(ArcSettlement.NotPendingOwner.selector);
        arc.acceptOwnership();
        vm.prank(alice);
        arc.acceptOwnership();
        require(arc.owner() == alice, "owner handed over");
    }

    // --- oracle cannot re-enter -----------------------------------------------

    /// Every IReserveOracle getter is `view`, so ArcSettlement reads the oracle with
    /// STATICCALL. A malicious oracle that tries to settle while being read cannot
    /// change state, and the whole settle fails closed instead of double counting.
    function test_MaliciousOracleCannotReenterSettle() public {
        ReentrantOracle evil = new ReentrantOracle(1_000_000e6, 1000);
        ArcSettlement arc2 = new ArcSettlement(IReserveOracle(address(evil)), 1 days);
        evil.arm(address(arc2), alice);
        vm.expectRevert();
        arc2.settle(alice, 1e6);
        require(arc2.totalSupply() == 0, "no supply created by the re-entrancy attempt");
    }

    // --- ERC-20 plumbing -------------------------------------------------------

    function test_TransferMovesBalance() public {
        arc.settle(alice, 100e6);
        vm.prank(alice);
        arc.transfer(bob, 40e6);
        require(arc.balanceOf(alice) == 60e6 && arc.balanceOf(bob) == 40e6, "transfer");
    }

    function test_TransferMoreThanBalanceReverts() public {
        arc.settle(alice, 10e6);
        vm.prank(alice);
        vm.expectRevert(ArcSettlement.InsufficientBalance.selector);
        arc.transfer(bob, 11e6);
    }

    function test_TransferFromSpendsAllowance() public {
        arc.settle(alice, 100e6);
        vm.prank(alice);
        arc.approve(address(this), 40e6);
        arc.transferFrom(alice, bob, 40e6);
        require(arc.allowance(alice, address(this)) == 0, "allowance spent");
        vm.expectRevert(ArcSettlement.InsufficientAllowance.selector);
        arc.transferFrom(alice, bob, 1);
    }

    function test_InfiniteAllowanceIsNotDecremented() public {
        arc.settle(alice, 100e6);
        vm.prank(alice);
        arc.approve(address(this), type(uint256).max);
        arc.transferFrom(alice, bob, 40e6);
        require(arc.allowance(alice, address(this)) == type(uint256).max, "infinite allowance kept");
    }

    function test_TransferToZeroAddressReverts() public {
        arc.settle(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(ArcSettlement.ZeroAddress.selector);
        arc.transfer(address(0), 1e6);
    }

    /// Settled supply is the sum of balances after an arbitrary settle/redeem/transfer mix.
    function testFuzz_SupplyNeverExceedsEffectiveReserves(uint96 a, uint96 b, uint96 redeemAmt) public {
        uint256 amountA = uint256(a) % 600_000e6;
        uint256 amountB = uint256(b) % 600_000e6;
        if (amountA > 0) arc.settle(alice, amountA);
        if (amountB > 0 && arc.totalSupply() + amountB <= arc.effectiveReserves()) arc.settle(bob, amountB);
        uint256 toRedeem = uint256(redeemAmt) % (arc.balanceOf(alice) + 1);
        if (toRedeem > 0) {
            vm.prank(alice);
            arc.redeem(toRedeem);
        }
        require(arc.totalSupply() <= arc.effectiveReserves(), "supply <= effective reserves, always");
        require(arc.balanceOf(alice) + arc.balanceOf(bob) == arc.totalSupply(), "balances sum to supply");
    }
}
