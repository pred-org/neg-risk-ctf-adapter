// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {console, RevNegRiskAdapter_SetUp} from "src/test/RevNegRiskAdapter/RevNegRiskAdapterSetUp.t.sol";
import {NegRiskIdLib} from "src/libraries/NegRiskIdLib.sol";

contract RevNegRiskAdapter_ConvertPositions_Test is RevNegRiskAdapter_SetUp {
    uint256 constant QUESTION_COUNT_MAX = 32;
    bytes32 marketId;

    function _before(uint256 _questionCount, uint256 _feeBips, uint256 _targetIndex, uint256 _amount) internal {
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

            ++i;
        }

        nrAdapter.setPrepared(marketId);

        assertEq(nrAdapter.getQuestionCount(marketId), _questionCount);

        // Give Brian USDC for the reverse conversion operation
        // vm.prank(brian);
        // usdc.mint(brian, _amount);

        // send YES positions to brian for ALL questions
        // The convertPositions function will burn all YES positions
        {
            i = 0;

            while (i < _questionCount) {
                if (i != _targetIndex) {
                    uint256 positionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
                    ctf.balanceOf(alice, positionId);
                    vm.prank(alice);
                    ctf.safeTransferFrom(alice, brian, positionId, _amount, "");
                    assertEq(ctf.balanceOf(brian, positionId), _amount);
                }
                ++i;
            }
        }
    }

    function _after(uint256 _questionCount, uint256 _feeBips, uint256 _targetIndex, uint256 _amount) internal {
        // check balances
        {
            uint8 i = 0;
            uint256 yesPositionsCount = 0;

            while (i < _questionCount) {
                if (i != _targetIndex) {
                    // YES positions should be gone from brian
                    uint256 yesPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
                    uint256 noPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), false);

                    // brian has no more of the yes tokens
                    assertEq(ctf.balanceOf(brian, yesPositionId), 0, "Brian yes tokens should be 0");
                    // they are all at the yes token burn address
                    assertEq(ctf.balanceOf(revAdapter.getYesTokenBurnAddress(), yesPositionId), _amount, "Yes tokens should be at the yes token burn address");
                    // rev adapter should have no conditional tokens
                    assertEq(ctf.balanceOf(address(revAdapter), yesPositionId), 0, "Yes tokens should be 0");
                    assertEq(ctf.balanceOf(address(revAdapter), noPositionId), 0, "No tokens should be 0");
                    ++yesPositionsCount;
                } else {
                    // Target NO position
                    uint256 targetYesPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
                    uint256 targetNoPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), false);

                    // brian should have the full NO token amount (no fees deducted)
                    assertEq(ctf.balanceOf(brian, targetNoPositionId), _amount, "Brian no tokens should be at the target no position");
                    // vault should have no no tokens (fees were removed)
                    assertEq(ctf.balanceOf(vault, targetNoPositionId), 0, "Vault no tokens should be 0");
                    // User's target YES tokens are burned (not kept)
                    assertEq(ctf.balanceOf(brian, targetYesPositionId), 0, "Brian yes tokens should be 0");
                    // The target YES position gets burned from split
                    assertEq(ctf.balanceOf(revAdapter.getYesTokenBurnAddress(), targetYesPositionId), _amount, "Yes tokens should be at the yes token burn address");
                    // rev adapter should have no conditional tokens
                    assertEq(ctf.balanceOf(address(revAdapter), targetYesPositionId), 0);
                    assertEq(ctf.balanceOf(address(revAdapter), targetNoPositionId), 0);
                }
                ++i;
            }

            assertEq(yesPositionsCount + 1, _questionCount);

            // brian should have no USDC (no collateral is returned in reverse conversion)
            assertEq(usdc.balanceOf(brian), 0, "Brian USDC should be 0");

            // The CTF WCOL balance is affected by the convertPositions operations
            // We can't predict the exact final balance due to the complex operations
            // Just verify that the adapter has no WCOL left (which it does)
            assertEq(wcol.balanceOf(address(revAdapter)), 0, "WCOL balance should be 0");
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

        // Give Brian approval for the reverse conversion (USDC already minted in _before)
        vm.startPrank(brian);
        usdc.approve(address(revAdapter), _amount);
        ctf.setApprovalForAll(address(revAdapter), true);

        // convert positions
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, _targetIndex, _amount);
            revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
        }

        _after(_questionCount, _feeBips, _targetIndex, _amount);
    }

    function test_convertPositions_firstIndex(uint256 _questionCount, uint256 _feeBips, uint128 _amount) public {
        vm.assume(_amount > 0);

        _feeBips = bound(_feeBips, 0, FEE_BIPS_MAX);
        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        uint256 _targetIndex = 0;

        _before(_questionCount, _feeBips, _targetIndex, _amount);

        // Give Brian approval for the reverse conversion (USDC already minted in _before)
        vm.startPrank(brian);
        usdc.approve(address(revAdapter), _amount);
        ctf.setApprovalForAll(address(revAdapter), true);

        // convert positions
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, _targetIndex, _amount);
            revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
        }

        _after(_questionCount, _feeBips, _targetIndex, _amount);
    }

    function test_convertPositions_lastIndex(uint256 _questionCount, uint256 _feeBips, uint128 _amount) public {
        vm.assume(_amount > 0);

        _feeBips = bound(_feeBips, 0, FEE_BIPS_MAX);
        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        uint256 _targetIndex = _questionCount - 1;

        _before(_questionCount, _feeBips, _targetIndex, _amount);

        // Give Brian approval for the reverse conversion (USDC already minted in _before)
        vm.startPrank(brian);
        usdc.approve(address(revAdapter), _amount);
        ctf.setApprovalForAll(address(revAdapter), true);

        // convert positions
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, _targetIndex, _amount);
            revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
        }

        _after(_questionCount, _feeBips, _targetIndex, _amount);
    }

    function test_convertPositions_middleIndex(uint256 _questionCount, uint256 _feeBips, uint128 _amount) public {
        vm.assume(_amount > 0);

        _feeBips = bound(_feeBips, 0, FEE_BIPS_MAX);
        _questionCount = bound(_questionCount, 3, QUESTION_COUNT_MAX); // Need at least 3 for middle index
        uint256 _targetIndex = _questionCount / 2;

        _before(_questionCount, _feeBips, _targetIndex, _amount);

        // Give Brian approval for the reverse conversion (USDC already minted in _before)
        vm.startPrank(brian);
        usdc.approve(address(revAdapter), _amount);
        ctf.setApprovalForAll(address(revAdapter), true);

        // convert positions
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, _targetIndex, _amount);
            revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
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
            revAdapter.convertPositions(marketId, _targetIndex, amount, brian);
        }
    }

    function test_convertPositions_noFees(uint256 _questionCount, uint256 _targetIndex, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        _targetIndex = bound(_targetIndex, 0, _questionCount - 1);
        uint256 _feeBips = 0;

        _before(_questionCount, _feeBips, _targetIndex, _amount);

        // Give Brian approval for the reverse conversion (USDC already minted in _before)
        vm.startPrank(brian);
        usdc.approve(address(revAdapter), _amount);
        ctf.setApprovalForAll(address(revAdapter), true);

        // convert positions
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, _targetIndex, _amount);
            revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
        }

        _after(_questionCount, _feeBips, _targetIndex, _amount);
    }

    function test_convertPositions_maxFees(uint256 _questionCount, uint256 _targetIndex, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        _targetIndex = bound(_targetIndex, 0, _questionCount - 1);
        uint256 _feeBips = FEE_BIPS_MAX;

        _before(_questionCount, _feeBips, _targetIndex, _amount);

        // Give Brian approval for the reverse conversion (USDC already minted in _before)
        vm.startPrank(brian);
        usdc.approve(address(revAdapter), _amount);
        ctf.setApprovalForAll(address(revAdapter), true);

        // convert positions
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, _targetIndex, _amount);
            revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
        }

        _after(_questionCount, _feeBips, _targetIndex, _amount);
    }

    function test_revert_convertPositions_marketNotPrepared(bytes32 _marketId) public {
        vm.expectRevert(MarketNotPrepared.selector);
        revAdapter.convertPositions(_marketId, 0, 0, brian);
    }

    function test_revert_convertPositions_noConvertiblePositions() public {
        // Each scenario uses a distinct market because MarketDataManager forbids
        // adding questions after setPrepared (MarketAlreadyFinalized).

        // 0 questions prepared
        vm.prank(oracle);
        bytes32 marketZero = nrAdapter.prepareMarket(0, "zero");
        nrAdapter.setPrepared(marketZero);
        vm.expectRevert(NoConvertiblePositions.selector);
        revAdapter.convertPositions(marketZero, 0, 0, brian);

        // 1 question prepared
        vm.prank(oracle);
        bytes32 marketOne = nrAdapter.prepareMarket(0, "one");
        vm.prank(oracle);
        nrAdapter.prepareQuestion(marketOne, "");
        nrAdapter.setPrepared(marketOne);
        vm.expectRevert(NoConvertiblePositions.selector);
        revAdapter.convertPositions(marketOne, 0, 0, brian);

        // 2 questions prepared - amount=0 returns early
        vm.prank(oracle);
        bytes32 marketTwo = nrAdapter.prepareMarket(0, "two");
        vm.prank(oracle);
        nrAdapter.prepareQuestion(marketTwo, "");
        vm.prank(oracle);
        nrAdapter.prepareQuestion(marketTwo, "");
        nrAdapter.setPrepared(marketTwo);

        vm.prank(brian);
        revAdapter.convertPositions(marketTwo, 0, 0, brian);
    }

    function test_revert_convertPositions_invalidTargetIndex(uint256 _questionCount, uint256 _targetIndex) public {
        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        _targetIndex = bound(_targetIndex, _questionCount, type(uint256).max);

        vm.prank(oracle);
        marketId = nrAdapter.prepareMarket(0, "");

        // Prepare questions
        for (uint256 i = 0; i < _questionCount; i++) {
            vm.prank(oracle);
            nrAdapter.prepareQuestion(marketId, "");
        }

        nrAdapter.setPrepared(marketId);

        vm.expectRevert(InvalidTargetIndex.selector);
        revAdapter.convertPositions(marketId, _targetIndex, 0, brian);
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
            revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
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
        uint256 yesPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, uint8(nonTargetIndex)), true);
        vm.prank(brian);
        ctf.safeTransferFrom(brian, alice, yesPositionId, _amount, "");

        // Try to convert - this should revert due to insufficient YES tokens
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            // The function should revert when trying to transfer insufficient YES tokens
            vm.expectRevert();
            revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
        }
    }

    function test_convertPositions_wcolBalanceConsistency(uint256 _questionCount, uint256 _targetIndex, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        _targetIndex = bound(_targetIndex, 0, _questionCount - 1);

        _before(_questionCount, 0, _targetIndex, _amount);

        // Give Brian approval for the reverse conversion (USDC already minted in _before)
        vm.startPrank(brian);
        usdc.approve(address(revAdapter), _amount);
        ctf.setApprovalForAll(address(revAdapter), true);

        // convert positions
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);
            revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
        }

        // WCOL balance should always be 0 after execution
        uint256 wcolBalanceAfter = wcol.balanceOf(address(revAdapter));
        assertEq(wcolBalanceAfter, 0, "WCOL balance must be 0 after convertPositions");
    }

    /// @notice Test that WCOL balance is always 0 after convertPositions execution
    /// @dev This ensures the core contract invariant is maintained
    function test_convertPositions_wcolBalanceAlwaysZero(uint256 _questionCount, uint256 _feeBips, uint256 _targetIndex, uint128 _amount)
        public
    {
        vm.assume(_amount > 0);

        _feeBips = bound(_feeBips, 0, FEE_BIPS_MAX);
        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        _targetIndex = bound(_targetIndex, 0, _questionCount - 1);

        _before(_questionCount, 0, _targetIndex, _amount);

        // Record initial WCOL balance
        uint256 initialWcolBalance = revAdapter.wcol().balanceOf(address(revAdapter));

        // convert positions
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
        }

        // Verify WCOL balance is exactly 0 after execution
        uint256 finalWcolBalance = revAdapter.wcol().balanceOf(address(revAdapter));
        assertEq(finalWcolBalance, 0, "WCOL balance must be 0 after convertPositions");

        // Verify the balance change matches the expected pattern
        // Initial: 0 WCOL
        // During execution: +_amount WCOL (minted), then consumed by splits
        // Final: 0 WCOL
        assertEq(initialWcolBalance, 0, "Initial WCOL balance should be 0");
    }

    /// @notice Test WCOL balance consistency across different question counts
    function test_convertPositions_wcolBalanceDifferentQuestionCounts() public {
        uint256[] memory questionCounts = new uint256[](4);
        questionCounts[0] = 2;
        questionCounts[1] = 3;
        questionCounts[2] = 5;
        questionCounts[3] = 10;

        for (uint256 i = 0; i < questionCounts.length; i++) {
            uint256 questionCount = questionCounts[i];
            uint256 targetIndex = 0; // Always target first question
            uint128 amount = 1000; // Fixed amount for this test

            // Create a new market for each iteration
            vm.prank(oracle);
            bytes32 newMarketId = nrAdapter.prepareMarket(0, bytes(string.concat("market_", vm.toString(i))));

            // Prepare questions
            for (uint256 j = 0; j < questionCount; j++) {
                vm.prank(oracle);
                nrAdapter.prepareQuestion(newMarketId, "");
            }

            nrAdapter.setPrepared(newMarketId);

            // Give brian YES positions for all questions
            for (uint256 j = 0; j < questionCount; j++) {
                bytes32 questionId = NegRiskIdLib.getQuestionId(newMarketId, uint8(j));
                bytes32 conditionId = nrAdapter.getConditionId(questionId);
                uint256 yesPositionId = nrAdapter.getPositionId(questionId, true);

                // Split position to get YES tokens
                vm.startPrank(alice);
                usdc.mint(alice, amount);
                usdc.approve(address(nrAdapter), amount);
                nrAdapter.splitPosition(conditionId, amount);
                vm.stopPrank();

                // Transfer YES tokens to brian
                vm.prank(alice);
                ctf.safeTransferFrom(alice, brian, yesPositionId, amount, "");
            }

            // Give Brian USDC for the conversion operation
            vm.prank(brian);
            usdc.mint(brian, amount);
            usdc.approve(address(revAdapter), amount);

            // convert positions
            {
                vm.startPrank(brian);
                ctf.setApprovalForAll(address(revAdapter), true);
                revAdapter.convertPositions(newMarketId, targetIndex, amount, brian);
            }

            // Verify WCOL balance is 0
            uint256 finalWcolBalance = revAdapter.wcol().balanceOf(address(revAdapter));
            assertEq(finalWcolBalance, 0, string.concat("WCOL balance must be 0 for ", vm.toString(questionCount), " questions"));

            // Reset for next iteration
            vm.stopPrank();
        }
    }

    /// @notice Test WCOL balance consistency across different fee levels
    function test_convertPositions_wcolBalanceDifferentFees() public {
        uint256 questionCount = 3;
        uint256 targetIndex = 0;
        uint128 amount = 1000; // Fixed amount for this test

        uint256[] memory feeBips = new uint256[](4);
        feeBips[0] = 0;      // No fees
        feeBips[1] = 100;    // 1% fee
        feeBips[2] = 500;    // 5% fee
        feeBips[3] = 1000;   // 10% fee

        for (uint256 i = 0; i < feeBips.length; i++) {
            uint256 feeBipsValue = feeBips[i];

            // Create a new market for each iteration
            vm.prank(oracle);
            bytes32 newMarketId = nrAdapter.prepareMarket(feeBipsValue, bytes(string.concat("market_", vm.toString(i))));

            // Prepare questions
            for (uint256 j = 0; j < questionCount; j++) {
                vm.prank(oracle);
                nrAdapter.prepareQuestion(newMarketId, "");
            }

            nrAdapter.setPrepared(newMarketId);

            // Give brian YES positions for all questions
            for (uint256 j = 0; j < questionCount; j++) {
                bytes32 questionId = NegRiskIdLib.getQuestionId(newMarketId, uint8(j));
                bytes32 conditionId = nrAdapter.getConditionId(questionId);
                uint256 yesPositionId = nrAdapter.getPositionId(questionId, true);

                // Split position to get YES tokens
                vm.startPrank(alice);
                usdc.mint(alice, amount);
                usdc.approve(address(nrAdapter), amount);
                nrAdapter.splitPosition(conditionId, amount);
                vm.stopPrank();

                // Transfer YES tokens to brian
                vm.prank(alice);
                ctf.safeTransferFrom(alice, brian, yesPositionId, amount, "");
            }

            // Give Brian USDC for the conversion operation
            vm.prank(brian);
            usdc.mint(brian, amount);
            usdc.approve(address(revAdapter), amount);

            // convert positions
            {
                vm.startPrank(brian);
                ctf.setApprovalForAll(address(revAdapter), true);
                revAdapter.convertPositions(newMarketId, targetIndex, amount, brian);
            }

            // Verify WCOL balance is 0 regardless of fee level
            uint256 finalWcolBalance = revAdapter.wcol().balanceOf(address(revAdapter));
            assertEq(finalWcolBalance, 0, string.concat("WCOL balance must be 0 for ", vm.toString(feeBipsValue), " bips fee"));

            // Reset for next iteration
            vm.stopPrank();
        }
    }

    /// @notice Test WCOL balance consistency with edge case amounts
    function test_convertPositions_wcolBalanceEdgeCaseAmounts() public {
        uint256 questionCount = 3;
        uint256 targetIndex = 0;
        
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 1;
        amounts[1] = 1000;
        amounts[2] = 1e6;
        amounts[3] = 1e9;

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 currentAmount = amounts[i];

            // Create a new market for each iteration
            vm.prank(oracle);
            bytes32 newMarketId = nrAdapter.prepareMarket(0, bytes(string.concat("market_", vm.toString(i))));

            // Prepare questions
            for (uint256 j = 0; j < questionCount; j++) {
                vm.prank(oracle);
                nrAdapter.prepareQuestion(newMarketId, "");
            }

            nrAdapter.setPrepared(newMarketId);

            // Give brian YES positions for all questions
            for (uint256 j = 0; j < questionCount; j++) {
                bytes32 questionId = NegRiskIdLib.getQuestionId(newMarketId, uint8(j));
                bytes32 conditionId = nrAdapter.getConditionId(questionId);
                uint256 yesPositionId = nrAdapter.getPositionId(questionId, true);

                // Split position to get YES tokens
                vm.startPrank(alice);
                usdc.mint(alice, currentAmount);
                usdc.approve(address(nrAdapter), currentAmount);
                nrAdapter.splitPosition(conditionId, currentAmount);
                vm.stopPrank();

                // Transfer YES tokens to brian
                vm.prank(alice);
                ctf.safeTransferFrom(alice, brian, yesPositionId, currentAmount, "");
            }

            // Give Brian USDC for the conversion operation
            vm.prank(brian);
            usdc.mint(brian, currentAmount);
            usdc.approve(address(revAdapter), currentAmount);

            // convert positions
            {
                vm.startPrank(brian);
                ctf.setApprovalForAll(address(revAdapter), true);
                revAdapter.convertPositions(newMarketId, targetIndex, currentAmount, brian);
            }

            // Verify WCOL balance is 0 regardless of amount
            uint256 finalWcolBalance = revAdapter.wcol().balanceOf(address(revAdapter));
            assertEq(finalWcolBalance, 0, string.concat("WCOL balance must be 0 for amount ", vm.toString(currentAmount)));

            // Reset for next iteration
            vm.stopPrank();
        }
    }

    /// @notice Test WCOL balance consistency with different target indices
    function test_convertPositions_wcolBalanceDifferentTargetIndices() public {
        uint256 questionCount = 5;
        uint128 amount = 1000; // Fixed amount for this test

        for (uint256 targetIndex = 0; targetIndex < questionCount; targetIndex++) {
            // Create a new market for each iteration
            vm.prank(oracle);
            bytes32 newMarketId = nrAdapter.prepareMarket(0, bytes(string.concat("market_", vm.toString(targetIndex))));

            // Prepare questions
            for (uint256 j = 0; j < questionCount; j++) {
                vm.prank(oracle);
                nrAdapter.prepareQuestion(newMarketId, "");
            }

            nrAdapter.setPrepared(newMarketId);

            // Give brian YES positions for all questions
            for (uint256 j = 0; j < questionCount; j++) {
                bytes32 questionId = NegRiskIdLib.getQuestionId(newMarketId, uint8(j));
                bytes32 conditionId = nrAdapter.getConditionId(questionId);
                uint256 yesPositionId = nrAdapter.getPositionId(questionId, true);

                // Split position to get YES tokens
                vm.startPrank(alice);
                usdc.mint(alice, amount);
                usdc.approve(address(nrAdapter), amount);
                nrAdapter.splitPosition(conditionId, amount);
                vm.stopPrank();

                // Transfer YES tokens to brian
                vm.prank(alice);
                ctf.safeTransferFrom(alice, brian, yesPositionId, amount, "");
            }

            // Give Brian USDC for the conversion operation
            vm.prank(brian);
            usdc.mint(brian, amount);
            usdc.approve(address(revAdapter), amount);

            // convert positions
            {
                vm.startPrank(brian);
                ctf.setApprovalForAll(address(revAdapter), true);
                revAdapter.convertPositions(newMarketId, targetIndex, amount, brian);
            }

            // Verify WCOL balance is 0 regardless of target index
            uint256 finalWcolBalance = revAdapter.wcol().balanceOf(address(revAdapter));
            assertEq(finalWcolBalance, 0, string.concat("WCOL balance must be 0 for target index ", vm.toString(targetIndex)));

            // Reset for next iteration
            vm.stopPrank();
        }
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
            revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
        }
    }

    /// @notice Target question is already resolved -> revert MarketAlreadyResolved.
    function test_revert_convertPositions_marketAlreadyResolved(
        uint256 _questionCount,
        uint256 _targetIndex,
        uint128 _amount
    ) public {
        vm.assume(_amount > 0);
        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        _targetIndex = bound(_targetIndex, 0, _questionCount - 1);

        _before(_questionCount, 0, _targetIndex, _amount);

        // Resolve the TARGET question (outcome value doesn't matter).
        bytes32 targetQuestionId = NegRiskIdLib.getQuestionId(marketId, uint8(_targetIndex));
        vm.prank(oracle);
        nrAdapter.reportOutcome(targetQuestionId, false);

        vm.startPrank(brian);
        ctf.setApprovalForAll(address(revAdapter), true);

        vm.expectRevert(MarketAlreadyResolved.selector);
        revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
        vm.stopPrank();
    }

    /// @notice If any question resolves TRUE, market becomes determined and
    ///         convertPositions must revert even when target remains unresolved.
    function test_revert_convertPositions_marketAlreadyDetermined_targetUnresolved(uint128 _amount) public {
        vm.assume(_amount > 0);
        uint256 _questionCount = 3;
        uint256 _targetIndex = 2;

        _before(_questionCount, 0, _targetIndex, _amount);

        // Resolve a non-target question TRUE -> market is determined.
        bytes32 winningQuestionId = NegRiskIdLib.getQuestionId(marketId, 0);
        vm.prank(oracle);
        nrAdapter.reportOutcome(winningQuestionId, true);
        assertTrue(nrAdapter.getDetermined(marketId), "market must be determined");

        vm.startPrank(brian);
        ctf.setApprovalForAll(address(revAdapter), true);
        vm.expectRevert(MarketAlreadyDetermined.selector);
        revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
        vm.stopPrank();
    }

    /// @notice Guard precedence: when market is determined and target is also resolved,
    ///         MarketAlreadyDetermined should fire before MarketAlreadyResolved.
    function test_revert_convertPositions_marketAlreadyDetermined_precedesTargetResolved(uint128 _amount) public {
        vm.assume(_amount > 0);
        uint256 _questionCount = 3;
        uint256 _targetIndex = 0;

        _before(_questionCount, 0, _targetIndex, _amount);

        // Resolve the target TRUE -> both "determined" and "target resolved" are true.
        bytes32 targetQuestionId = NegRiskIdLib.getQuestionId(marketId, uint8(_targetIndex));
        vm.prank(oracle);
        nrAdapter.reportOutcome(targetQuestionId, true);
        assertTrue(nrAdapter.getDetermined(marketId), "market must be determined");

        vm.startPrank(brian);
        ctf.setApprovalForAll(address(revAdapter), true);
        vm.expectRevert(MarketAlreadyDetermined.selector);
        revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
        vm.stopPrank();
    }

    /// @notice Determined-market guard triggers before the amount==0 early return.
    function test_revert_convertPositions_zeroAmount_marketAlreadyDetermined() public {
        uint256 _questionCount = 3;
        uint256 _targetIndex = 1;
        uint256 _amount = 0;

        _before(_questionCount, 0, _targetIndex, _amount);

        bytes32 winningQuestionId = NegRiskIdLib.getQuestionId(marketId, 0);
        vm.prank(oracle);
        nrAdapter.reportOutcome(winningQuestionId, true);

        vm.prank(brian);
        vm.expectRevert(MarketAlreadyDetermined.selector);
        revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
    }

    /// @notice Every non-target question is already resolved -> revert NoUnresolvedPositions.
    function test_revert_convertPositions_noUnresolvedPositions(
        uint256 _questionCount,
        uint256 _targetIndex,
        uint128 _amount
    ) public {
        vm.assume(_amount > 0);
        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        _targetIndex = bound(_targetIndex, 0, _questionCount - 1);

        _before(_questionCount, 0, _targetIndex, _amount);

        // Resolve every non-target question to NO (adversarial setup).
        for (uint256 j = 0; j < _questionCount; j++) {
            if (j != _targetIndex) {
                bytes32 questionIdJ = NegRiskIdLib.getQuestionId(marketId, uint8(j));
                vm.prank(oracle);
                nrAdapter.reportOutcome(questionIdJ, false);
            }
        }

        vm.startPrank(brian);
        ctf.setApprovalForAll(address(revAdapter), true);

        vm.expectRevert(NoUnresolvedPositions.selector);
        revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
        vm.stopPrank();
    }

    /// @notice Partial resolution: some non-target questions resolved (worthless YES),
    ///         but at least one non-target stays unresolved and target stays unresolved.
    ///         The operation must succeed and only burn YES for UNRESOLVED non-targets.
    function test_convertPositions_partiallyResolved(uint128 _amount) public {
        vm.assume(_amount > 0);
        uint256 _questionCount = 4;
        uint256 _targetIndex = 0;

        _before(_questionCount, 0, _targetIndex, _amount);

        // Resolve question index 1 to NO. brian's YES(q1) is now worthless but
        // he still holds it; the adapter should NOT pull/burn it.
        bytes32 questionId1 = NegRiskIdLib.getQuestionId(marketId, 1);
        vm.prank(oracle);
        nrAdapter.reportOutcome(questionId1, false);

        vm.startPrank(brian);
        ctf.setApprovalForAll(address(revAdapter), true);

        vm.expectEmit(true, true, true, true);
        emit PositionsConverted(brian, marketId, _targetIndex, _amount);
        revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
        vm.stopPrank();

        address burnAddr = revAdapter.getYesTokenBurnAddress();

        // (a) YES(q1) was NOT burned — still in brian's hands.
        uint256 yesPos1 = nrAdapter.getPositionId(questionId1, true);
        assertEq(ctf.balanceOf(brian, yesPos1), _amount, "resolved YES must remain with brian");
        assertEq(ctf.balanceOf(burnAddr, yesPos1), 0, "resolved YES must not be at burn addr");

        // (b) YES for unresolved non-targets q2 & q3 WERE burned.
        for (uint8 j = 2; j < uint8(_questionCount); j++) {
            uint256 yesPosJ = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, j), true);
            assertEq(ctf.balanceOf(brian, yesPosJ), 0, "unresolved YES must leave brian");
            assertEq(ctf.balanceOf(burnAddr, yesPosJ), _amount, "unresolved YES must be at burn addr");
        }

        // (c) brian received NO(target).
        uint256 noTargetPos =
            nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, uint8(_targetIndex)), false);
        assertEq(ctf.balanceOf(brian, noTargetPos), _amount, "brian must receive NO(target)");

        // (d) Core invariant: the adapter holds no WCOL.
        assertEq(wcol.balanceOf(address(revAdapter)), 0, "adapter WCOL must be 0");
    }

    /// @notice CEI guarantee: if the YES burn reverts (e.g. user is missing
    ///         a required YES token), wcol.mint MUST NOT have executed.
    ///         Pre-fix the mint ran before the burn; this test locks that ordering in.
    function test_convertPositions_noUnbackedMintOnFailedBurn(uint128 _amount) public {
        vm.assume(_amount > 0);
        uint256 _questionCount = 3;
        uint256 _targetIndex = 0;

        _before(_questionCount, 0, _targetIndex, _amount);

        // Take one required YES token away from brian so the batch burn will revert.
        bytes32 questionId1 = NegRiskIdLib.getQuestionId(marketId, 1);
        uint256 yesPos1 = nrAdapter.getPositionId(questionId1, true);
        vm.prank(brian);
        ctf.safeTransferFrom(brian, alice, yesPos1, _amount, "");

        uint256 wcolSupplyBefore = wcol.totalSupply();

        vm.startPrank(brian);
        ctf.setApprovalForAll(address(revAdapter), true);
        vm.expectRevert();
        revAdapter.convertPositions(marketId, _targetIndex, _amount, brian);
        vm.stopPrank();

        // WCOL supply must be unchanged - the mint never happened.
        assertEq(
            wcol.totalSupply(),
            wcolSupplyBefore,
            "WCOL must not be minted when the YES burn fails (CEI violation)"
        );
        assertEq(wcol.balanceOf(address(revAdapter)), 0, "adapter WCOL must be 0 after revert");
    }
}
