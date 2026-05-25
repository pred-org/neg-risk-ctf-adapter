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

    /// @notice With 3 questions and Q1 resolved TRUE, the market is determined and
    ///         mergeAllYesTokens now reverts with MarketAlreadyDetermined.
    function test_mergeAllYesTokens_resolvedNonPivotQuestionTrue(uint128 _amount) public {
        vm.assume(_amount > 0);
        uint256 questionCount = 3;
        uint256 resolvedIdx = 1; // non-pivot

        _before(questionCount, 0, _amount);

        bytes32 resolvedQuestionId = NegRiskIdLib.getQuestionId(marketId, uint8(resolvedIdx));
        vm.prank(oracle);
        nrAdapter.reportOutcome(resolvedQuestionId, true);

        vm.prank(brian);
        vm.expectRevert(MarketAlreadyDetermined.selector);
        revAdapter.mergeAllYesTokens(marketId, _amount);
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

    /// @notice When Q0 is resolved TRUE, the market is determined and mergeAllYesTokens
    ///         now reverts with MarketAlreadyDetermined.
    function test_mergeAllYesTokens_q0Resolved_explicitPivot(uint128 _amount) public {
        vm.assume(_amount > 0);
        uint256 questionCount = 3;

        _before(questionCount, 0, _amount);

        bytes32 q0 = NegRiskIdLib.getQuestionId(marketId, 0);
        vm.prank(oracle);
        nrAdapter.reportOutcome(q0, true);

        vm.prank(brian);
        vm.expectRevert(MarketAlreadyDetermined.selector);
        revAdapter.mergeAllYesTokens(marketId, _amount);
    }

    /// @notice When Q0 is resolved FALSE, market is NOT determined and the 2-arg
    ///         overload auto-skips Q0, pivots to Q1, and merge succeeds.
    function test_mergeAllYesTokens_q0ResolvedFalse_autoPivotSucceeds(uint128 _amount) public {
        vm.assume(_amount > 0);
        uint256 questionCount = 3;

        _before(questionCount, 0, _amount);

        bytes32 q0 = NegRiskIdLib.getQuestionId(marketId, 0);
        vm.prank(oracle);
        nrAdapter.reportOutcome(q0, false);
        assertFalse(nrAdapter.getDetermined(marketId), "market must not be determined");

        vm.startPrank(brian);
        vm.expectEmit(true, true, true, true);
        emit PositionsConverted(brian, marketId, 1, _amount);
        revAdapter.mergeAllYesTokens(marketId, _amount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(brian), _amount, "Brian should receive USDC from Q1 pivot merge");
        assertEq(wcol.balanceOf(address(revAdapter)), 0, "WCOL balance must be 0");

        address burnAddress = revAdapter.getYesTokenBurnAddress();
        uint256 q0YesId = nrAdapter.getPositionId(q0, true);
        // Resolved FALSE non-pivot YES should be skipped.
        assertEq(ctf.balanceOf(brian, q0YesId), _amount, "Resolved Q0 YES must remain with brian");
        assertEq(ctf.balanceOf(burnAddress, q0YesId), 0, "Resolved Q0 YES must not be burned");
    }

    /// @notice With Q0 resolved FALSE, callers can still choose explicit pivot Q2.
    ///         The operation succeeds because market is not determined.
    function test_mergeAllYesTokens_q0ResolvedFalse_explicitPivotSucceeds(uint128 _amount) public {
        vm.assume(_amount > 0);
        uint256 questionCount = 3;
        uint256 pivotId = 2;

        _before(questionCount, 0, _amount);

        bytes32 q0 = NegRiskIdLib.getQuestionId(marketId, 0);
        vm.prank(oracle);
        nrAdapter.reportOutcome(q0, false);
        assertFalse(nrAdapter.getDetermined(marketId), "market must not be determined");

        vm.startPrank(brian);
        vm.expectEmit(true, true, true, true);
        emit PositionsConverted(brian, marketId, pivotId, _amount);
        revAdapter.mergeAllYesTokens(marketId, _amount, pivotId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(brian), _amount, "Brian should receive USDC from explicit pivot merge");
        assertEq(wcol.balanceOf(address(revAdapter)), 0, "WCOL balance must be 0");

        address burnAddress = revAdapter.getYesTokenBurnAddress();
        uint256 q0YesId = nrAdapter.getPositionId(q0, true);
        // Resolved FALSE non-pivot YES should be skipped.
        assertEq(ctf.balanceOf(brian, q0YesId), _amount, "Resolved Q0 YES must remain with brian");
        assertEq(ctf.balanceOf(burnAddress, q0YesId), 0, "Resolved Q0 YES must not be burned");
    }
}
