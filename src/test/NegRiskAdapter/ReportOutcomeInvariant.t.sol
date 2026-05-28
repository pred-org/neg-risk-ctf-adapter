// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {NegRiskAdapter_SetUp} from "src/test/NegRiskAdapter/NegRiskAdapterSetUp.sol";
import {NegRiskIdLib} from "src/libraries/NegRiskIdLib.sol";

/// @title NegRiskAdapter_ReportOutcomeInvariant_Test
/// @notice Exercises the neg-risk "at least one YES" invariant added in MarketDataManager.
///         A multi-question neg-risk market may not resolve all-NO because the protocol
///         would otherwise be unable to release the WCOL backing of the un-determined market.
/// @dev    NegRiskInvariantViolated comes in via NegRiskAdapter_SetUp ⇒ INegRiskAdapterEE ⇒ IMarketStateManagerEE.
contract NegRiskAdapter_ReportOutcomeInvariant_Test is NegRiskAdapter_SetUp {
    function _prepareMarketWithQuestions(uint256 _questionCount) internal returns (bytes32 marketId) {
        bytes memory data = new bytes(0);
        vm.startPrank(oracle);
        marketId = nrAdapter.prepareMarket(0, data);
        for (uint256 i; i < _questionCount; ++i) {
            nrAdapter.prepareQuestion(marketId, data);
        }
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          INVARIANT - 2 QUESTIONS
    //////////////////////////////////////////////////////////////*/

    function test_revert_allNo_twoQuestionMarket() public {
        bytes32 marketId = _prepareMarketWithQuestions(2);
        bytes32 q0 = NegRiskIdLib.getQuestionId(marketId, 0);
        bytes32 q1 = NegRiskIdLib.getQuestionId(marketId, 1);

        vm.prank(oracle);
        nrAdapter.reportOutcome(q0, false);

        // Final NO on a multi-question market that was never determined must revert.
        vm.expectRevert(NegRiskInvariantViolated.selector);
        vm.prank(oracle);
        nrAdapter.reportOutcome(q1, false);
    }

    /*//////////////////////////////////////////////////////////////
                          INVARIANT - 3 QUESTIONS
    //////////////////////////////////////////////////////////////*/

    function test_revert_allNo_threeQuestionMarket() public {
        bytes32 marketId = _prepareMarketWithQuestions(3);
        bytes32 q0 = NegRiskIdLib.getQuestionId(marketId, 0);
        bytes32 q1 = NegRiskIdLib.getQuestionId(marketId, 1);
        bytes32 q2 = NegRiskIdLib.getQuestionId(marketId, 2);

        vm.prank(oracle);
        nrAdapter.reportOutcome(q0, false);
        vm.prank(oracle);
        nrAdapter.reportOutcome(q1, false);

        vm.expectRevert(NegRiskInvariantViolated.selector);
        vm.prank(oracle);
        nrAdapter.reportOutcome(q2, false);
    }

    /*//////////////////////////////////////////////////////////////
                         HAPPY PATHS - NOT BLOCKED
    //////////////////////////////////////////////////////////////*/

    function test_finalQuestionYes_passes() public {
        bytes32 marketId = _prepareMarketWithQuestions(2);
        bytes32 q0 = NegRiskIdLib.getQuestionId(marketId, 0);
        bytes32 q1 = NegRiskIdLib.getQuestionId(marketId, 1);

        vm.prank(oracle);
        nrAdapter.reportOutcome(q0, false);
        vm.prank(oracle);
        nrAdapter.reportOutcome(q1, true);

        assertTrue(nrAdapter.getDetermined(marketId));
        assertEq(nrAdapter.getResult(marketId), 1);
    }

    function test_firstQuestionYes_thenNo_passes() public {
        bytes32 marketId = _prepareMarketWithQuestions(2);
        bytes32 q0 = NegRiskIdLib.getQuestionId(marketId, 0);
        bytes32 q1 = NegRiskIdLib.getQuestionId(marketId, 1);

        vm.prank(oracle);
        nrAdapter.reportOutcome(q0, true);

        // Subsequent NO on a determined market is allowed (just records the result on CTF).
        vm.prank(oracle);
        nrAdapter.reportOutcome(q1, false);

        assertTrue(nrAdapter.getDetermined(marketId));
        assertEq(nrAdapter.getResult(marketId), 0);
    }

    /*//////////////////////////////////////////////////////////////
                  SINGLE-QUESTION MARKETS ARE EXEMPT
    //////////////////////////////////////////////////////////////*/

    function test_singleQuestionMarket_noIsAllowed() public {
        bytes32 marketId = _prepareMarketWithQuestions(1);
        bytes32 q0 = NegRiskIdLib.getQuestionId(marketId, 0);

        // A qc==1 neg-risk market degenerates into a binary YES/NO market, so NO is fine.
        vm.prank(oracle);
        nrAdapter.reportOutcome(q0, false);

        assertFalse(nrAdapter.getDetermined(marketId));
    }

    function test_singleQuestionMarket_yesIsAllowed() public {
        bytes32 marketId = _prepareMarketWithQuestions(1);
        bytes32 q0 = NegRiskIdLib.getQuestionId(marketId, 0);

        vm.prank(oracle);
        nrAdapter.reportOutcome(q0, true);

        assertTrue(nrAdapter.getDetermined(marketId));
        assertEq(nrAdapter.getResult(marketId), 0);
    }

    /*//////////////////////////////////////////////////////////////
                IDEMPOTENCE & DUPLICATE-RESOLVE SEMANTICS
    //////////////////////////////////////////////////////////////*/

    /// @notice A duplicate report for the same questionId is blocked downstream by the CTF
    ///         ("payout denominator already set"). The crucial property we assert here is
    ///         that the failed duplicate call does NOT increment reportedCount and does NOT
    ///         surface a misleading NegRiskInvariantViolated. After the failed retry, the
    ///         market still resolves cleanly via a YES on the remaining question.
    function test_duplicateReport_revertsAtCtfAndDoesNotInflateReportedCount() public {
        bytes32 marketId = _prepareMarketWithQuestions(2);
        bytes32 q0 = NegRiskIdLib.getQuestionId(marketId, 0);
        bytes32 q1 = NegRiskIdLib.getQuestionId(marketId, 1);

        vm.prank(oracle);
        nrAdapter.reportOutcome(q0, false);
        assertEq(nrAdapter.getReportedCount(marketId), 1);

        // Duplicate report reverts inside ConditionalTokens. The require message is suppressed
        // here because we only care about the post-revert state.
        vm.prank(oracle);
        vm.expectRevert(bytes("payout denominator already set"));
        nrAdapter.reportOutcome(q0, false);

        // reportedCount is unchanged: questionReported gated the increment, and the CTF
        // revert rolled back any mutation that did slip through.
        assertEq(nrAdapter.getReportedCount(marketId), 1);

        // The market can still be resolved with a YES on q1 without our invariant tripping.
        vm.prank(oracle);
        nrAdapter.reportOutcome(q1, true);
        assertTrue(nrAdapter.getDetermined(marketId));
        assertEq(nrAdapter.getResult(marketId), 1);
        assertEq(nrAdapter.getReportedCount(marketId), 2);
    }

    /*//////////////////////////////////////////////////////////////
                          REPORTED COUNT VIEW
    //////////////////////////////////////////////////////////////*/

    function test_getReportedCount_tracksUniqueReports() public {
        bytes32 marketId = _prepareMarketWithQuestions(3);
        bytes32 q0 = NegRiskIdLib.getQuestionId(marketId, 0);
        bytes32 q1 = NegRiskIdLib.getQuestionId(marketId, 1);

        assertEq(nrAdapter.getReportedCount(marketId), 0);

        vm.prank(oracle);
        nrAdapter.reportOutcome(q0, false);
        assertEq(nrAdapter.getReportedCount(marketId), 1);

        vm.prank(oracle);
        nrAdapter.reportOutcome(q1, true);
        assertEq(nrAdapter.getReportedCount(marketId), 2);
    }

    /*//////////////////////////////////////////////////////////////
                  EMERGENCY UNSTICK PATH (DESIGN NOTE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Documents the recovery path when a market would otherwise resolve all-NO.
    ///         If the legitimate outcome of every question is NO, the protocol relies on
    ///         governance to either (a) flag the final question and emergencyResolve it
    ///         to YES on the operator, or (b) keep the market un-finalized indefinitely.
    ///         The reportOutcome path itself is intentionally blocked.
    function test_allNoMarket_canBeUnstuckByFinalYesReport() public {
        bytes32 marketId = _prepareMarketWithQuestions(2);
        bytes32 q0 = NegRiskIdLib.getQuestionId(marketId, 0);
        bytes32 q1 = NegRiskIdLib.getQuestionId(marketId, 1);

        // First NO is recorded; second NO would violate the invariant.
        vm.prank(oracle);
        nrAdapter.reportOutcome(q0, false);

        vm.prank(oracle);
        vm.expectRevert(NegRiskInvariantViolated.selector);
        nrAdapter.reportOutcome(q1, false);

        // Operator can instead resolve the final question YES to keep the market solvent.
        vm.prank(oracle);
        nrAdapter.reportOutcome(q1, true);

        assertTrue(nrAdapter.getDetermined(marketId));
        assertEq(nrAdapter.getResult(marketId), 1);
    }
}
