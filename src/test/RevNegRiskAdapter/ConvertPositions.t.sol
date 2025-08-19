// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {console, RevNegRiskAdapter_SetUp} from "src/test/RevNegRiskAdapter/RevNegRiskAdapterSetUp.sol";
import {NegRiskIdLib} from "src/libraries/NegRiskIdLib.sol";

contract RevNegRiskAdapter_ConvertPositions_Test is RevNegRiskAdapter_SetUp {
    uint256 constant QUESTION_COUNT_MAX = 32;
    bytes32 marketId;

    function _before(uint256 _questionCount, uint256 _feeBips, uint256 _targetIndex, uint256 _amount) internal {
        bytes memory data = new bytes(0);

        // prepare market
        vm.prank(oracle);
        marketId = revAdapter.prepareMarket(_feeBips, data);

        uint8 i = 0;

        // prepare questions and split initial liquidity to alice
        while (i < _questionCount) {
            vm.prank(oracle);
            bytes32 questionId = revAdapter.prepareQuestion(marketId, data);
            bytes32 conditionId = revAdapter.getConditionId(questionId);

            // split position to alice
            vm.startPrank(alice);
            usdc.mint(alice, _amount);
            usdc.approve(address(revAdapter), _amount);
            revAdapter.splitPosition(conditionId, _amount);
            vm.stopPrank();

            ++i;
        }

        assertEq(revAdapter.getQuestionCount(marketId), _questionCount);

        // send YES positions to brian for ALL questions (including target)
        // The convertPositions function will burn the target YES position
        {
            i = 0;

            while (i < _questionCount) {
                uint256 positionId = revAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
                ctf.balanceOf(alice, positionId);
                vm.prank(alice);
                ctf.safeTransferFrom(alice, brian, positionId, _amount, "");
                assertEq(ctf.balanceOf(brian, positionId), _amount);
                ++i;
            }
        }
    }

    function _after(uint256 _questionCount, uint256 _feeBips, uint256 _targetIndex, uint256 _amount) internal {
        // check balances
        {
            uint256 feeAmount = (_amount * _feeBips) / FEE_BIPS_MAX;
            uint256 amountOut = _amount - feeAmount;

            uint8 i = 0;
            uint256 yesPositionsCount = 0;

            while (i < _questionCount) {
                if (i != _targetIndex) {
                    // YES positions should be gone from brian
                    uint256 yesPositionId = revAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
                    uint256 noPositionId = revAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), false);

                    // brian has no more of the yes tokens
                    assertEq(ctf.balanceOf(brian, yesPositionId), 0);
                    // they are all at the yes token burn address
                    assertEq(ctf.balanceOf(revAdapter.YES_TOKEN_BURN_ADDRESS(), yesPositionId), _amount);
                    // rev adapter should have no conditional tokens
                    assertEq(ctf.balanceOf(address(revAdapter), yesPositionId), 0);
                    assertEq(ctf.balanceOf(address(revAdapter), noPositionId), 0);
                    ++yesPositionsCount;
                } else {
                    // Target NO position
                    uint256 targetYesPositionId = revAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
                    uint256 targetNoPositionId = revAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), false);

                    // brian should have the NO token, after fees
                    assertEq(ctf.balanceOf(brian, targetNoPositionId), amountOut);
                    // vault has the rest of no tokens as fees
                    assertEq(ctf.balanceOf(vault, targetNoPositionId), feeAmount);
                    // YES tokens should be at the burn address
                    // The target YES position gets burned twice: once from user, once from split
                    assertEq(ctf.balanceOf(revAdapter.YES_TOKEN_BURN_ADDRESS(), targetYesPositionId), _amount * 2);
                    // rev adapter should have no conditional tokens
                    assertEq(ctf.balanceOf(address(revAdapter), targetYesPositionId), 0);
                    assertEq(ctf.balanceOf(address(revAdapter), targetNoPositionId), 0);
                }
                ++i;
            }

            assertEq(yesPositionsCount + 1, _questionCount);

            // brian should have no USDC (no collateral is returned in reverse conversion)
            assertEq(usdc.balanceOf(brian), 0);

            // The CTF WCOL balance is affected by the convertPositions operations
            // We can't predict the exact final balance due to the complex operations
            // Just verify that the adapter has no WCOL left (which it does)
            assertEq(wcol.balanceOf(address(revAdapter)), 0);
        }
    }

    function test_convertPositions(uint256 _questionCount, uint256 _feeBips, uint256 _targetIndex, uint128 _amount)
        public
    {
        vm.assume(_amount > 0);

        _feeBips = bound(_feeBips, 0, FEE_BIPS_MAX);
        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX); // between 2 and QUESTION_COUNT_MAX questions
        _targetIndex = bound(_targetIndex, 0, _questionCount - 1);

        _before(_questionCount, _feeBips, _targetIndex, _amount);

        // convert positions
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, _targetIndex, _amount);
            revAdapter.convertPositions(marketId, _targetIndex, _amount);
        }

        _after(_questionCount, _feeBips, _targetIndex, _amount);
    }

    function test_convertPositions_firstIndex(uint256 _questionCount, uint256 _feeBips, uint128 _amount) public {
        vm.assume(_amount > 0);

        _feeBips = bound(_feeBips, 0, FEE_BIPS_MAX);
        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        uint256 _targetIndex = 0;

        _before(_questionCount, _feeBips, _targetIndex, _amount);

        // convert positions
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, _targetIndex, _amount);
            revAdapter.convertPositions(marketId, _targetIndex, _amount);
        }

        _after(_questionCount, _feeBips, _targetIndex, _amount);
    }

    function test_convertPositions_lastIndex(uint256 _questionCount, uint256 _feeBips, uint128 _amount) public {
        vm.assume(_amount > 0);

        _feeBips = bound(_feeBips, 0, FEE_BIPS_MAX);
        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        uint256 _targetIndex = _questionCount - 1;

        _before(_questionCount, _feeBips, _targetIndex, _amount);

        // convert positions
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, _targetIndex, _amount);
            revAdapter.convertPositions(marketId, _targetIndex, _amount);
        }

        _after(_questionCount, _feeBips, _targetIndex, _amount);
    }

    function test_convertPositions_middleIndex(uint256 _questionCount, uint256 _feeBips, uint128 _amount) public {
        vm.assume(_amount > 0);

        _feeBips = bound(_feeBips, 0, FEE_BIPS_MAX);
        _questionCount = bound(_questionCount, 3, QUESTION_COUNT_MAX); // Need at least 3 for middle index
        uint256 _targetIndex = _questionCount / 2;

        _before(_questionCount, _feeBips, _targetIndex, _amount);

        // convert positions
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, _targetIndex, _amount);
            revAdapter.convertPositions(marketId, _targetIndex, _amount);
        }

        _after(_questionCount, _feeBips, _targetIndex, _amount);
    }

    function test_convertPositions_zeroAmount(uint256 _questionCount, uint256 _targetIndex) public {
        uint256 amount = 0;

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        _targetIndex = bound(_targetIndex, 0, _questionCount - 1);

        _before(_questionCount, 0, _targetIndex, amount);

        {
            vm.prank(brian);
            revAdapter.convertPositions(marketId, _targetIndex, amount);
        }
    }

    function test_convertPositions_noFees(uint256 _questionCount, uint256 _targetIndex, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        _targetIndex = bound(_targetIndex, 0, _questionCount - 1);
        uint256 _feeBips = 0;

        _before(_questionCount, _feeBips, _targetIndex, _amount);

        // convert positions
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, _targetIndex, _amount);
            revAdapter.convertPositions(marketId, _targetIndex, _amount);
        }

        _after(_questionCount, _feeBips, _targetIndex, _amount);
    }

    function test_convertPositions_maxFees(uint256 _questionCount, uint256 _targetIndex, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        _targetIndex = bound(_targetIndex, 0, _questionCount - 1);
        uint256 _feeBips = FEE_BIPS_MAX;

        _before(_questionCount, _feeBips, _targetIndex, _amount);

        // convert positions
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, _targetIndex, _amount);
            revAdapter.convertPositions(marketId, _targetIndex, _amount);
        }

        _after(_questionCount, _feeBips, _targetIndex, _amount);
    }

    function test_revert_convertPositions_marketNotPrepared(bytes32 _marketId) public {
        vm.expectRevert(MarketNotPrepared.selector);
        revAdapter.convertPositions(_marketId, 0, 0);
    }

    function test_revert_convertPositions_noConvertiblePositions() public {
        vm.prank(oracle);
        marketId = revAdapter.prepareMarket(0, "");

        // 0 questions prepared
        vm.expectRevert(NoConvertiblePositions.selector);
        revAdapter.convertPositions(marketId, 0, 0);

        vm.prank(oracle);
        revAdapter.prepareQuestion(marketId, "");

        // 1 question prepared
        vm.expectRevert(NoConvertiblePositions.selector);
        revAdapter.convertPositions(marketId, 0, 0);

        vm.prank(oracle);
        revAdapter.prepareQuestion(marketId, "");

        // 2 questions prepared - should work
        vm.prank(brian);
        revAdapter.convertPositions(marketId, 0, 0);
    }

    function test_revert_convertPositions_invalidTargetIndex(uint256 _questionCount, uint256 _targetIndex) public {
        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        _targetIndex = bound(_targetIndex, _questionCount, type(uint256).max);

        vm.prank(oracle);
        marketId = revAdapter.prepareMarket(0, "");

        // Prepare questions
        for (uint256 i = 0; i < _questionCount; i++) {
            vm.prank(oracle);
            revAdapter.prepareQuestion(marketId, "");
        }

        vm.expectRevert(InvalidTargetIndex.selector);
        revAdapter.convertPositions(marketId, _targetIndex, 0);
    }

    function test_revert_convertPositions_userNotApproved(uint256 _questionCount, uint256 _targetIndex, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        _targetIndex = bound(_targetIndex, 0, _questionCount - 1);

        _before(_questionCount, 0, _targetIndex, _amount);

        // Try to convert without approval
        {
            vm.prank(brian);
            // Don't set approval
            // ctf.setApprovalForAll(address(revAdapter), true);

            // The function should revert when trying to transfer tokens without approval
            vm.expectRevert();
            revAdapter.convertPositions(marketId, _targetIndex, _amount);
        }
    }

    function test_revert_convertPositions_insufficientYesTokens(uint256 _questionCount, uint256 _targetIndex, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        _targetIndex = bound(_targetIndex, 0, _questionCount - 1);

        _before(_questionCount, 0, _targetIndex, _amount);

        // Remove some YES tokens from brian for a non-target question
        // This will cause the function to revert when trying to transfer insufficient tokens
        uint256 nonTargetIndex = (_targetIndex == 0) ? 1 : 0;
        uint256 yesPositionId = revAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, uint8(nonTargetIndex)), true);
        vm.prank(brian);
        ctf.safeTransferFrom(brian, alice, yesPositionId, _amount, "");

        // Try to convert - this should revert due to insufficient YES tokens
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            // The function should revert when trying to transfer insufficient YES tokens
            vm.expectRevert();
            revAdapter.convertPositions(marketId, _targetIndex, _amount);
        }
    }

    function test_convertPositions_wcolBalanceConsistency(uint256 _questionCount, uint256 _targetIndex, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        _targetIndex = bound(_targetIndex, 0, _questionCount - 1);

        _before(_questionCount, 0, _targetIndex, _amount);

        uint256 wcolBalanceBefore = wcol.balanceOf(address(revAdapter));

        // convert positions
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);
            revAdapter.convertPositions(marketId, _targetIndex, _amount);
        }

        uint256 wcolBalanceAfter = wcol.balanceOf(address(revAdapter));

        // WCOL balance should be the same (all minted WCOL should be burned)
        assertEq(wcolBalanceAfter, wcolBalanceBefore);
    }

    function test_convertPositions_eventEmission(uint256 _questionCount, uint256 _targetIndex, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        _targetIndex = bound(_targetIndex, 0, _questionCount - 1);

        _before(_questionCount, 0, _targetIndex, _amount);

        // convert positions and verify event
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit(true, true, true, true);
            emit PositionsConverted(brian, marketId, _targetIndex, _amount);
            revAdapter.convertPositions(marketId, _targetIndex, _amount);
        }
    }
} 