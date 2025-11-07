// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {console, RevNegRiskAdapter_SetUp} from "src/test/RevNegRiskAdapter/RevNegRiskAdapterSetUp.t.sol";
import {NegRiskIdLib} from "src/libraries/NegRiskIdLib.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";

contract RevNegRiskAdapter_MergeAllYesTokensResolved_Test is RevNegRiskAdapter_SetUp {
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

            // Store the 0th question details
            if (i == 0) {
                questionId0 = questionId;
                conditionId0 = conditionId;
                positionIdFalse0 = nrAdapter.getPositionId(questionId, false);
                positionIdTrue0 = nrAdapter.getPositionId(questionId, true);
            }

            unchecked { ++i; }
        }

        nrAdapter.setPrepared(marketId);

        // resolve the 0th question to true
        vm.prank(oracle);
        nrAdapter.reportOutcome(marketId, true);

        // transfer all YES tokens from alice to brian
        for (uint256 j = 1; j < _questionCount; j++) {
            bytes32 questionId = NegRiskIdLib.getQuestionId(marketId, uint8(j));
            uint256 yesPositionId = nrAdapter.getPositionId(questionId, true);
            uint256 balance = ctf.balanceOf(alice, yesPositionId);
            
            vm.prank(alice);
            ctf.safeTransferFrom(alice, brian, yesPositionId, balance, "");
        }

        // also transfer the 0th question YES tokens to brian
        uint256 balance0 = ctf.balanceOf(alice, positionIdTrue0);
        vm.prank(alice);
        ctf.safeTransferFrom(alice, brian, positionIdTrue0, balance0, "");
    }

    function test_mergeAllYesTokens_resolvedQuestionBehavior() public {
        uint256 questionCount = 3;
        uint256 feeBips = 1000; // 10%
        uint256 amount = 100e6; // 100 USDC

        _before(questionCount, feeBips, amount);

        // check initial balances
        uint256 initialUsdcBalance = usdc.balanceOf(brian);
        uint256 initialWcolBalance = wcol.balanceOf(brian);

        console.log("Initial USDC balance:", initialUsdcBalance);
        console.log("Initial WCOL balance:", initialWcolBalance);

        // approve the adapter to spend brian's tokens
        vm.startPrank(brian);
        usdc.approve(address(revAdapter), amount);
        ctf.setApprovalForAll(address(revAdapter), true);
        vm.stopPrank();

        // call mergeAllYesTokens
        vm.prank(brian);
        revAdapter.mergeAllYesTokens(marketId, amount);

        // check final balances
        uint256 finalUsdcBalance = usdc.balanceOf(brian);
        uint256 finalWcolBalance = wcol.balanceOf(brian);

        console.log("Final USDC balance:", finalUsdcBalance);
        console.log("Final WCOL balance:", finalWcolBalance);

        // The function should work even with resolved questions
        // Brian should receive USDC from the merge operation
        assertTrue(finalUsdcBalance > initialUsdcBalance, "Brian should receive USDC");
        
        // WCOL balance should be 0
        assertEq(finalWcolBalance, 0, "WCOL balance should be 0");

        // Verify all YES tokens are consumed after merge
        // Check that all YES tokens from questions 1 to n-1 are burned
        for (uint256 j = 1; j < questionCount; j++) {
            bytes32 questionId = NegRiskIdLib.getQuestionId(marketId, uint8(j));
            uint256 yesPositionId = nrAdapter.getPositionId(questionId, true);
            assertEq(ctf.balanceOf(brian, yesPositionId), 0, "All YES tokens from non-target questions should be consumed");
        }

        // Check that the 0th question YES tokens are also consumed
        assertEq(ctf.balanceOf(brian, positionIdTrue0), 0, "0th question YES tokens should be consumed");
    }

    function test_mergeAllYesTokens_resolvedQuestionFalse() public {
        uint256 questionCount = 3;
        uint256 feeBips = 1000; // 10%
        uint256 amount = 100e6; // 100 USDC

        // Create a new market for this test to avoid the "payout denominator already set" error
        bytes memory data = new bytes(0);
        vm.prank(oracle);
        bytes32 newMarketId = nrAdapter.prepareMarket(feeBips, data);

        uint8 i = 0;
        // prepare questions and split initial liquidity to alice
        while (i < questionCount) {
            vm.prank(oracle);
            bytes32 questionId = nrAdapter.prepareQuestion(newMarketId, data);
            bytes32 conditionId = nrAdapter.getConditionId(questionId);

            // split position to alice
            vm.startPrank(alice);
            usdc.mint(alice, amount);
            usdc.approve(address(nrAdapter), amount);
            nrAdapter.splitPosition(conditionId, amount);
            vm.stopPrank();

            // Store the 0th question details
            if (i == 0) {
                questionId0 = questionId;
                conditionId0 = conditionId;
                positionIdFalse0 = nrAdapter.getPositionId(questionId, false);
                positionIdTrue0 = nrAdapter.getPositionId(questionId, true);
            }

            unchecked { ++i; }
        }

        nrAdapter.setPrepared(newMarketId);

        // resolve the 0th question to false
        vm.prank(oracle);
        nrAdapter.reportOutcome(newMarketId, false);

        // transfer all YES tokens from alice to brian
        for (uint256 j = 1; j < questionCount; j++) {
            bytes32 questionId = NegRiskIdLib.getQuestionId(newMarketId, uint8(j));
            uint256 yesPositionId = nrAdapter.getPositionId(questionId, true);
            uint256 balance = ctf.balanceOf(alice, yesPositionId);
            
            vm.prank(alice);
            ctf.safeTransferFrom(alice, brian, yesPositionId, balance, "");
        }

        // also transfer the 0th question YES tokens to brian
        uint256 balance0 = ctf.balanceOf(alice, positionIdTrue0);
        vm.prank(alice);
        ctf.safeTransferFrom(alice, brian, positionIdTrue0, balance0, "");

        // check initial balances
        uint256 initialUsdcBalance = usdc.balanceOf(brian);
        uint256 initialWcolBalance = wcol.balanceOf(brian);

        // approve the adapter to spend brian's tokens
        vm.startPrank(brian);
        usdc.approve(address(revAdapter), amount);
        ctf.setApprovalForAll(address(revAdapter), true);
        vm.stopPrank();

        // call mergeAllYesTokens
        vm.prank(brian);
        revAdapter.mergeAllYesTokens(newMarketId, amount);

        // check final balances
        uint256 finalUsdcBalance = usdc.balanceOf(brian);
        uint256 finalWcolBalance = wcol.balanceOf(brian);

        // The function should work even with resolved questions
        // Brian should receive USDC from the merge operation
        assertTrue(finalUsdcBalance > initialUsdcBalance, "Brian should receive USDC");
        
        // WCOL balance should be 0
        assertEq(finalWcolBalance, 0, "WCOL balance should be 0");

        // Verify all YES tokens are consumed after merge
        // Check that all YES tokens from questions 1 to n-1 are burned
        for (uint256 j = 1; j < questionCount; j++) {
            bytes32 questionId = NegRiskIdLib.getQuestionId(newMarketId, uint8(j));
            uint256 yesPositionId = nrAdapter.getPositionId(questionId, true);
            assertEq(ctf.balanceOf(brian, yesPositionId), 0, "All YES tokens from non-target questions should be consumed");
        }

        // Check that the 0th question YES tokens are also consumed
        assertEq(ctf.balanceOf(brian, positionIdTrue0), 0, "0th question YES tokens should be consumed");
    }
}
