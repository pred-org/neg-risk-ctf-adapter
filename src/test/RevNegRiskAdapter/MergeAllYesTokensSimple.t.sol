// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {console, RevNegRiskAdapter_SetUp} from "src/test/RevNegRiskAdapter/RevNegRiskAdapterSetUp.t.sol";
import {NegRiskIdLib} from "src/libraries/NegRiskIdLib.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";

contract RevNegRiskAdapter_MergeAllYesTokensSimple_Test is RevNegRiskAdapter_SetUp {
    uint256 constant QUESTION_COUNT_MAX = 32;
    bytes32 marketId;
    bytes32 questionId0;
    bytes32 conditionId0;
    uint256 positionIdFalse0;
    uint256 positionIdTrue0;

    function _before(uint256 _questionCount, uint256 _feeBips, uint256 _amount) internal {
        bytes memory data = new bytes(0);

        // prepare market
        vm.prank(oracle);
        marketId = nrAdapter.prepareMarket(_feeBips, data);

        uint8 i = 0;

        // prepare questions and split initial liquidity to alice
        while (i < _questionCount) {
            vm.prank(oracle);
            bytes32 questionId = nrAdapter.prepareQuestion(marketId, data);
            bytes32 conditionId = nrAdapter.getConditionId(questionId);

            // split position to alice
            vm.startPrank(alice);
            usdc.mint(alice, _amount);
            usdc.approve(address(nrAdapter), _amount);
            nrAdapter.splitPosition(conditionId, _amount);
            vm.stopPrank();

            // Store the 0th question details for resolution
            if (i == 0) {
                questionId0 = questionId;
                conditionId0 = conditionId;
                positionIdFalse0 = nrAdapter.getPositionId(questionId, false);
                positionIdTrue0 = nrAdapter.getPositionId(questionId, true);
            }

            ++i;
        }

        nrAdapter.setPrepared(marketId);

        assertEq(nrAdapter.getQuestionCount(marketId), _questionCount);

        // send YES positions to brian for ALL questions
        {
            i = 0;
            while (i < _questionCount) {
                uint256 positionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
                ctf.balanceOf(alice, positionId);
                vm.prank(alice);
                ctf.safeTransferFrom(alice, brian, positionId, _amount, "");
                assertEq(ctf.balanceOf(brian, positionId), _amount);
                ++i;
            }
        }

        // Give Brian approval for the merge operation
        vm.startPrank(brian);
        usdc.approve(address(revAdapter), _amount);
        ctf.setApprovalForAll(address(revAdapter), true);
        vm.stopPrank();
    }

    function _beforeWithoutApprovals(uint256 _questionCount, uint256 _feeBips, uint256 _amount) internal {
        // Set up market with questions
        vm.prank(oracle);
        marketId = nrAdapter.prepareMarket(_feeBips, "");

        uint8 i = 0;
        while (i < _questionCount) {
            vm.prank(oracle);
            nrAdapter.prepareQuestion(marketId, "");
            ++i;
        }

        nrAdapter.setPrepared(marketId);

        // Alice splits position to get YES/NO tokens for ALL questions
        vm.startPrank(alice);
        usdc.mint(alice, _amount * _questionCount);
        usdc.approve(address(nrAdapter), _amount * _questionCount);
        
        // Split position for each question
        for (uint8 j = 0; j < _questionCount; ++j) {
            bytes32 questionId = NegRiskIdLib.getQuestionId(marketId, j);
            bytes32 conditionId = nrAdapter.getConditionId(questionId);
            nrAdapter.splitPosition(conditionId, _amount);
        }
        vm.stopPrank();

        // send YES positions to brian for ALL questions
        {
            i = 0;
            while (i < _questionCount) {
                uint256 positionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
                ctf.balanceOf(alice, positionId);
                vm.prank(alice);
                ctf.safeTransferFrom(alice, brian, positionId, _amount, "");
                assertEq(ctf.balanceOf(brian, positionId), _amount);
                ++i;
            }
        }

        // Give Brian USDC approval but NOT CTF approval
        vm.startPrank(brian);
        usdc.approve(address(revAdapter), _amount);
        // ctf.setApprovalForAll(address(revAdapter), true); // This is intentionally commented out
        vm.stopPrank();
    }

    function _after(uint256 _questionCount, uint256 _amount) internal {
        // check balances
        {
            uint8 i = 0;
            uint256 yesPositionsCount = 0;

            while (i < _questionCount) {
                if (i != 0) {
                    // Non-pivot questions: brian's YES burned via convertPositions.
                    uint256 yesPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
                    uint256 noPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), false);

                    assertEq(ctf.balanceOf(brian, yesPositionId), 0, "Brian yes tokens should be 0");
                    assertEq(ctf.balanceOf(revAdapter.getYesTokenBurnAddress(), yesPositionId), _amount, "Yes tokens should be at the yes token burn address");
                    assertEq(ctf.balanceOf(address(revAdapter), yesPositionId), 0, "Yes tokens should be 0");
                    assertEq(ctf.balanceOf(address(revAdapter), noPositionId), 0, "No tokens should be 0");
                    ++yesPositionsCount;
                } else {
                    // Pivot question (index 0): user's YES pulled then merged with adapter's NO.
                    uint256 pivotYesPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
                    uint256 pivotNoPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), false);

                    assertEq(ctf.balanceOf(brian, pivotYesPositionId), 0, "Brian pivot YES tokens should be 0");
                    assertEq(ctf.balanceOf(brian, pivotNoPositionId), 0, "Brian pivot NO tokens should be 0");

                    // Adapter's pivot tokens are consumed by the merge step.
                    assertEq(ctf.balanceOf(address(revAdapter), pivotYesPositionId), 0, "Adapter pivot YES must be 0");
                    assertEq(ctf.balanceOf(address(revAdapter), pivotNoPositionId), 0, "Adapter pivot NO must be 0");

                    // The pivot YES minted by the internal split is sent to the burn address.
                    address burnAddress = revAdapter.getYesTokenBurnAddress();
                    assertEq(ctf.balanceOf(burnAddress, pivotYesPositionId), _amount, "Pivot YES tokens should be at burn address");
                }
                ++i;
            }

            assertEq(yesPositionsCount + 1, _questionCount);

            // brian should have full USDC from the merge operation (no fees deducted)
            assertEq(usdc.balanceOf(brian), _amount, "Brian should have full USDC from merge");

            // The CTF WCOL balance should be 0
            assertEq(wcol.balanceOf(address(revAdapter)), 0, "WCOL balance should be 0");
        }
    }

    function test_mergeAllYesTokens(uint256 _questionCount, uint256 _feeBips, uint128 _amount) public {
        vm.assume(_amount > 0);

        _feeBips = bound(_feeBips, 0, FEE_BIPS_MAX);
        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX); // between 2 and QUESTION_COUNT_MAX questions

        _before(_questionCount, _feeBips, _amount);

        // merge all yes tokens against pivot=0 explicitly so the resolved-question semantics
        // assert against question 0 (the 2-arg overload now auto-selects the first unresolved
        // pivot, which would skip question 0).
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, 0, _amount);
            revAdapter.mergeAllYesTokens(marketId, _amount, 0);
        }

        _after(_questionCount, _amount);
    }

    function test_mergeAllYesTokens_noFees(uint256 _questionCount, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        uint256 _feeBips = 0;

        _before(_questionCount, _feeBips, _amount);

        // merge all yes tokens
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, 0, _amount);
            revAdapter.mergeAllYesTokens(marketId, _amount, 0);
        }

        _after(_questionCount, _amount);
    }

    /// @notice A pre-existing donation of pivot NO must not be able to brick
    /// mergeAllYesTokens. Delta accounting on the pivot NO balance ensures
    /// the inner merge requests only what convertPositions actually produced,
    /// regardless of any pre-existing balance.
    function test_mergeAllYesTokens_donatedPivotNo_doesNotBrickOrOverpay(uint128 _amount) public {
        vm.assume(_amount > 0);

        uint256 _questionCount = 3;
        _before(_questionCount, 0, _amount);

        // Alice has _amount of pivot (q0) NO tokens from the split inside _before.
        // She donates 1 wei of pivot NO directly into the revAdapter.
        // Pre-fix: actualNoAmount = _amount + 1; the inner mergePositions then
        //   requires _amount + 1 of YES which the adapter does not have ⇒ DoS.
        vm.prank(alice);
        ctf.safeTransferFrom(alice, address(revAdapter), positionIdFalse0, 1, "");
        assertEq(ctf.balanceOf(address(revAdapter), positionIdFalse0), 1, "donation should land");

        uint256 brianUsdcBefore = usdc.balanceOf(brian);

        vm.startPrank(brian);
        ctf.setApprovalForAll(address(revAdapter), true);
        revAdapter.mergeAllYesTokens(marketId, _amount, 0);
        vm.stopPrank();

        // Brian gets exactly _amount USDC — the donation is not credited to him.
        assertEq(
            usdc.balanceOf(brian),
            brianUsdcBefore + _amount,
            "Brian must receive exactly the merge amount, not inflated by donation"
        );

        // The donated 1 wei of pivot NO is still in the adapter; never merged,
        // never paid out.
        assertEq(
            ctf.balanceOf(address(revAdapter), positionIdFalse0),
            1,
            "Donated pivot NO must remain in the adapter"
        );

        // Adapter retains no USDC dust.
        assertEq(usdc.balanceOf(address(revAdapter)), 0, "Adapter must retain no USDC");
    }

    function test_mergeAllYesTokens_maxFees(uint256 _questionCount, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        uint256 _feeBips = FEE_BIPS_MAX;

        _before(_questionCount, _feeBips, _amount);

        // merge all yes tokens
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, 0, _amount);
            revAdapter.mergeAllYesTokens(marketId, _amount, 0);
        }

        _after(_questionCount, _amount);
    }

    function test_mergeAllYesTokens_zeroAmount(uint256 _questionCount) public {
        uint256 amount = 0;

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);

        _before(_questionCount, 0, amount);

        {
            vm.prank(brian);
            revAdapter.mergeAllYesTokens(marketId, amount, 0);
        }
    }

    /// @notice mergeAllYesTokens forwards into convertPositions; once market is determined,
    ///         it reverts even for amount=0.
    function test_revert_mergeAllYesTokens_zeroAmount_marketAlreadyDetermined() public {
        uint256 questionCount = 3;
        uint128 amount = 1000;

        _before(questionCount, 0, amount);

        vm.prank(oracle);
        nrAdapter.reportOutcome(questionId0, true);
        assertTrue(nrAdapter.getDetermined(marketId), "market must be determined");

        vm.prank(brian);
        vm.expectRevert(MarketAlreadyDetermined.selector);
        revAdapter.mergeAllYesTokens(marketId, 0);
    }

    function test_revert_mergeAllYesTokens_marketNotPrepared(bytes32 _marketId) public {
        vm.expectRevert(MarketNotPrepared.selector);
        revAdapter.mergeAllYesTokens(_marketId, 0);
    }

    function test_revert_mergeAllYesTokens_noConvertiblePositions() public {
        // Each scenario uses a distinct market because MarketDataManager forbids
        // adding questions after setPrepared (MarketAlreadyFinalized).

        // 0 questions prepared
        vm.prank(oracle);
        bytes32 marketZero = nrAdapter.prepareMarket(0, "zero");
        nrAdapter.setPrepared(marketZero);
        vm.expectRevert(NoConvertiblePositions.selector);
        revAdapter.mergeAllYesTokens(marketZero, 0);

        // 1 question prepared
        vm.prank(oracle);
        bytes32 marketOne = nrAdapter.prepareMarket(0, "one");
        vm.prank(oracle);
        nrAdapter.prepareQuestion(marketOne, "");
        nrAdapter.setPrepared(marketOne);
        vm.expectRevert(NoConvertiblePositions.selector);
        revAdapter.mergeAllYesTokens(marketOne, 0);

        // 2 questions prepared - amount=0 returns early inside convertPositions
        vm.prank(oracle);
        bytes32 marketTwo = nrAdapter.prepareMarket(0, "two");
        vm.prank(oracle);
        nrAdapter.prepareQuestion(marketTwo, "");
        vm.prank(oracle);
        nrAdapter.prepareQuestion(marketTwo, "");
        nrAdapter.setPrepared(marketTwo);

        vm.startPrank(brian);
        usdc.approve(address(revAdapter), 0);
        ctf.setApprovalForAll(address(revAdapter), true);
        vm.stopPrank();

        vm.prank(brian);
        revAdapter.mergeAllYesTokens(marketTwo, 0);
    }

    function test_revert_mergeAllYesTokens_userNotApproved(uint256 _questionCount, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);

        // Set up market and positions but WITHOUT approvals
        _beforeWithoutApprovals(_questionCount, 0, _amount);

        // Try to merge without approval - should revert
        vm.prank(brian);
        vm.expectRevert();
        revAdapter.mergeAllYesTokens(marketId, _amount);
    }

    function test_revert_mergeAllYesTokens_insufficientYesTokens(uint256 _questionCount, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);

        _before(_questionCount, 0, _amount);

        // Remove some YES tokens from brian for a non-target question
        // This will cause the function to revert when trying to transfer insufficient tokens
        uint256 nonTargetIndex = 1; // Use question 1 since 0 is the target
        uint256 yesPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, uint8(nonTargetIndex)), true);
        vm.prank(brian);
        ctf.safeTransferFrom(brian, alice, yesPositionId, _amount, "");

        // Try to merge - this should revert due to insufficient YES tokens
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            // The function should revert when trying to transfer insufficient YES tokens
            vm.expectRevert();
            revAdapter.mergeAllYesTokens(marketId, _amount);
        }
    }

    function test_mergeAllYesTokens_wcolBalanceConsistency(uint256 _questionCount, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);

        _before(_questionCount, 0, _amount);

        // merge all yes tokens (explicit pivot=0 to match the resolved-question setup)
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);
            revAdapter.mergeAllYesTokens(marketId, _amount, 0);
        }

        // WCOL balance should always be 0 after execution
        uint256 wcolBalanceAfter = wcol.balanceOf(address(revAdapter));
        assertEq(wcolBalanceAfter, 0, "WCOL balance must be 0 after mergeAllYesTokens");
        
        // Every YES token (pivot via internal split, non-pivot via batch transfer) lands at the burn address.
        address burnAddress = revAdapter.getYesTokenBurnAddress();
        for (uint256 i = 0; i < _questionCount; i++) {
            uint256 yesPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, uint8(i)), true);
            assertEq(ctf.balanceOf(burnAddress, yesPositionId), _amount, string(abi.encodePacked("YES tokens for question ", vm.toString(i), " should be burned")));
        }
    }

    function test_mergeAllYesTokens_eventEmission(uint256 _questionCount, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);

        _before(_questionCount, 0, _amount);

        // merge all yes tokens and verify event (pivot=0 explicitly because question 0
        // is the resolved question under test).
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit(true, true, true, true);
            emit PositionsConverted(brian, marketId, 0, _amount);
            revAdapter.mergeAllYesTokens(marketId, _amount, 0);
        }
    }

    /// @notice End-to-end happy-path verification: USDC payout, WCOL invariant,
    ///         and that all YES tokens (pivot + non-pivot) end at the burn address.
    function test_mergeAllYesTokens_endToEndBehavior() public {
        uint256 questionCount = 3;
        uint256 feeBips = 0;
        uint128 amount = 1000;

        _before(questionCount, feeBips, amount);

        // Record initial balances
        uint256 initialUsdcBalance = usdc.balanceOf(brian);
        uint256 initialWcolBalance = wcol.balanceOf(address(revAdapter));

        // merge all yes tokens (explicit pivot=0 to test the resolved-pivot path)
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, 0, amount);
            revAdapter.mergeAllYesTokens(marketId, amount, 0);
        }

        // Verify final balances
        uint256 finalUsdcBalance = usdc.balanceOf(brian);
        uint256 finalWcolBalance = wcol.balanceOf(address(revAdapter));

        // Brian should have received USDC from the merge
        assertEq(finalUsdcBalance, initialUsdcBalance + amount, "Brian should receive USDC from merge");
        
        // WCOL balance should be 0
        assertEq(finalWcolBalance, 0, "WCOL balance should be 0");
        assertEq(initialWcolBalance, 0, "Initial WCOL balance should be 0");

        // All YES tokens should be burned
        for (uint256 i = 0; i < questionCount; i++) {
            uint256 yesPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, uint8(i)), true);
            assertEq(ctf.balanceOf(brian, yesPositionId), 0, "Brian should have no YES tokens");
            assertEq(ctf.balanceOf(revAdapter.getYesTokenBurnAddress(), yesPositionId), amount, "YES tokens should be burned");
        }
    }

    /// @notice With question 0 resolved TRUE, the market is determined and
    ///         mergeAllYesTokens now reverts with MarketAlreadyDetermined.
    function test_mergeAllYesTokens_q0ResolvedTrue_autoPivots(uint256 _questionCount, uint128 _amount) public {
        vm.assume(_amount > 0);
        _questionCount = bound(_questionCount, 3, QUESTION_COUNT_MAX);

        _before(_questionCount, 0, _amount);

        // Resolve question 0 AFTER setup so balances are already in place.
        vm.prank(oracle);
        nrAdapter.reportOutcome(questionId0, true);

        vm.startPrank(brian);
        ctf.setApprovalForAll(address(revAdapter), true);

        vm.expectRevert(MarketAlreadyDetermined.selector);
        revAdapter.mergeAllYesTokens(marketId, _amount);
        vm.stopPrank();
    }

    /// @notice Same as above but resolving Q0 as FALSE. payoutDenominator is still non-zero,
    ///         so the auto-pivot helper treats Q0 as resolved and skips to Q1.
    /// @dev    See test_mergeAllYesTokens_q0ResolvedTrue_autoPivots for the >=3 bound rationale.
    function test_mergeAllYesTokens_q0ResolvedFalse_autoPivots(uint256 _questionCount, uint128 _amount) public {
        vm.assume(_amount > 0);
        _questionCount = bound(_questionCount, 3, QUESTION_COUNT_MAX);

        _before(_questionCount, 0, _amount);

        vm.prank(oracle);
        nrAdapter.reportOutcome(questionId0, false);

        vm.startPrank(brian);
        ctf.setApprovalForAll(address(revAdapter), true);

        vm.expectEmit();
        emit PositionsConverted(brian, marketId, 1, _amount);
        revAdapter.mergeAllYesTokens(marketId, _amount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(brian), _amount, "Brian should receive USDC from merge via Q1 pivot");
        assertEq(wcol.balanceOf(address(revAdapter)), 0, "WCOL balance must be 0");
        assertEq(ctf.balanceOf(brian, positionIdTrue0), _amount, "Resolved Q0 YES must remain with brian");
    }
}
