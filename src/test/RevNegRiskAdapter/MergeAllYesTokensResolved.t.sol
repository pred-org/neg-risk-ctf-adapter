// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {console, RevNegRiskAdapter_SetUp} from "src/test/RevNegRiskAdapter/RevNegRiskAdapterSetUp.t.sol";
import {NegRiskIdLib} from "src/libraries/NegRiskIdLib.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";

/// @notice Tests for mergeAllYesTokens in markets that contain at least one
///         resolved question. The audit fix forbids using a RESOLVED question
///         as the pivot, but resolved NON-pivot questions are skipped gracefully
///         so the user can still merge the remaining YES tokens to USDC.
contract RevNegRiskAdapter_MergeAllYesTokensResolved_Test is RevNegRiskAdapter_SetUp {
    uint256 constant QUESTION_COUNT_MAX = 32;
    bytes32 marketId;

    /// @dev Prepare a market with `_questionCount` questions, split USDC to alice
    ///      for each, and transfer alice's YES tokens for ALL questions to brian.
    ///      Does NOT resolve any question; resolution is left to each test.
    function _before(uint256 _questionCount, uint256 _feeBips, uint256 _amount) internal {
        vm.prank(oracle);
        marketId = nrAdapter.prepareMarket(_feeBips, "");

        for (uint8 i = 0; i < _questionCount; ++i) {
            vm.prank(oracle);
            bytes32 questionId = nrAdapter.prepareQuestion(marketId, "");
            bytes32 conditionId = nrAdapter.getConditionId(questionId);

            vm.startPrank(alice);
            usdc.mint(alice, _amount);
            usdc.approve(address(nrAdapter), _amount);
            nrAdapter.splitPosition(conditionId, _amount);
            vm.stopPrank();
        }

        nrAdapter.setPrepared(marketId);
        assertEq(nrAdapter.getQuestionCount(marketId), _questionCount);

        // Forward all of alice's YES tokens to brian.
        for (uint8 i = 0; i < _questionCount; ++i) {
            uint256 yesId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
            vm.prank(alice);
            ctf.safeTransferFrom(alice, brian, yesId, _amount, "");
            assertEq(ctf.balanceOf(brian, yesId), _amount);
        }

        vm.startPrank(brian);
        ctf.setApprovalForAll(address(revAdapter), true);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                       1 OF 3 RESOLVED, NOT THE PIVOT
    //////////////////////////////////////////////////////////////*/

    /// @notice With 3 questions and Q1 resolved (the resolved question is NOT the pivot),
    ///         mergeAllYesTokens(pivotId=0) settles via Q0 and processes the remaining
    ///         non-pivot YES (Q2). YES(Q1) is left with brian (worthless / redeemable separately).
    function test_mergeAllYesTokens_resolvedNonPivotQuestionTrue(uint128 _amount) public {
        vm.assume(_amount > 0);
        uint256 questionCount = 3;
        uint256 resolvedIdx = 1; // non-pivot

        _before(questionCount, 0, _amount);

        bytes32 resolvedQuestionId = NegRiskIdLib.getQuestionId(marketId, uint8(resolvedIdx));
        vm.prank(oracle);
        nrAdapter.reportOutcome(resolvedQuestionId, true);

        uint256 usdcBefore = usdc.balanceOf(brian);

        vm.prank(brian);
        revAdapter.mergeAllYesTokens(marketId, _amount);

        // Brian receives full _amount USDC from the pivot merge (no fees on this flow).
        assertEq(usdc.balanceOf(brian), usdcBefore + _amount, "Brian should receive USDC from merge");
        assertEq(wcol.balanceOf(address(revAdapter)), 0, "WCOL balance must be 0");

        address burnAddress = revAdapter.getYesTokenBurnAddress();

        // Pivot YES (Q0): minted by the internal split and sent to burn; brian's own YES(Q0)
        // is pulled into the adapter and then consumed by the final mergePositions.
        uint256 pivotYesId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, 0), true);
        assertEq(ctf.balanceOf(brian, pivotYesId), 0, "Brian pivot YES should be 0");
        assertEq(ctf.balanceOf(burnAddress, pivotYesId), _amount, "Pivot YES should be at burn address");

        // Resolved non-pivot YES (Q1): NOT touched — still with brian, not at the burn address.
        uint256 resolvedYesId = nrAdapter.getPositionId(resolvedQuestionId, true);
        assertEq(ctf.balanceOf(brian, resolvedYesId), _amount, "Resolved non-pivot YES must remain with brian");
        assertEq(ctf.balanceOf(burnAddress, resolvedYesId), 0, "Resolved non-pivot YES must not be burned");

        // Unresolved non-pivot YES (Q2): burned via the batch transfer in convertPositions.
        uint256 otherYesId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, 2), true);
        assertEq(ctf.balanceOf(brian, otherYesId), 0, "Unresolved non-pivot YES should leave brian");
        assertEq(ctf.balanceOf(burnAddress, otherYesId), _amount, "Unresolved non-pivot YES should be burned");
    }

    /// @notice Same flow but the resolved non-pivot question pays out FALSE.
    function test_mergeAllYesTokens_resolvedNonPivotQuestionFalse(uint128 _amount) public {
        vm.assume(_amount > 0);
        uint256 questionCount = 3;
        uint256 resolvedIdx = 1;

        _before(questionCount, 0, _amount);

        bytes32 resolvedQuestionId = NegRiskIdLib.getQuestionId(marketId, uint8(resolvedIdx));
        vm.prank(oracle);
        nrAdapter.reportOutcome(resolvedQuestionId, false);

        vm.prank(brian);
        revAdapter.mergeAllYesTokens(marketId, _amount);

        assertEq(usdc.balanceOf(brian), _amount, "Brian should receive USDC from merge");
        assertEq(wcol.balanceOf(address(revAdapter)), 0, "WCOL balance must be 0");

        // Resolved non-pivot YES must not be pulled regardless of outcome value.
        uint256 resolvedYesId = nrAdapter.getPositionId(resolvedQuestionId, true);
        assertEq(ctf.balanceOf(brian, resolvedYesId), _amount, "Resolved non-pivot YES must remain with brian");
    }

    /*//////////////////////////////////////////////////////////////
                  Q0 RESOLVED: 2-ARG AUTO-PIVOT + 3-ARG EXPLICIT
    //////////////////////////////////////////////////////////////*/

    /// @notice When Q0 is resolved, the 2-arg overload auto-skips to the first unresolved
    ///         question (Q1) and the merge succeeds. The 3-arg overload remains available
    ///         for callers who want to pick the pivot explicitly.
    function test_mergeAllYesTokens_q0Resolved_explicitPivot(uint128 _amount) public {
        vm.assume(_amount > 0);
        uint256 questionCount = 3;

        _before(questionCount, 0, _amount);

        bytes32 q0 = NegRiskIdLib.getQuestionId(marketId, 0);
        vm.prank(oracle);
        nrAdapter.reportOutcome(q0, true);

        // 2-arg overload auto-pivots to Q1 (Q0 is resolved) and succeeds.
        vm.prank(brian);
        revAdapter.mergeAllYesTokens(marketId, _amount);

        assertEq(usdc.balanceOf(brian), _amount, "Brian should receive USDC from auto-pivot merge");
        assertEq(wcol.balanceOf(address(revAdapter)), 0, "WCOL balance must be 0");

        address burnAddress = revAdapter.getYesTokenBurnAddress();

        // Resolved Q0's YES stays with brian (skipped in the burn loop).
        uint256 q0YesId = nrAdapter.getPositionId(q0, true);
        assertEq(ctf.balanceOf(brian, q0YesId), _amount, "Resolved Q0 YES must remain with brian");
        assertEq(ctf.balanceOf(burnAddress, q0YesId), 0, "Resolved Q0 YES must not be burned");

        // Q1 is the auto-selected pivot: brian's YES is pulled; the split-minted YES is burned.
        uint256 q1YesId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, 1), true);
        assertEq(ctf.balanceOf(brian, q1YesId), 0, "Brian's Q1 YES should be 0");
        assertEq(ctf.balanceOf(burnAddress, q1YesId), _amount, "Q1 pivot YES should be at burn address");

        // Q2 (unresolved non-pivot) is burned via the batch transfer.
        uint256 q2YesId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, 2), true);
        assertEq(ctf.balanceOf(brian, q2YesId), 0, "Brian's Q2 YES should be 0");
        assertEq(ctf.balanceOf(burnAddress, q2YesId), _amount, "Q2 YES should be burned");
    }
}
