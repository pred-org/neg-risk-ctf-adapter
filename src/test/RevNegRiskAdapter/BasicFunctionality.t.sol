// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {console, RevNegRiskAdapter_SetUp} from "src/test/RevNegRiskAdapter/RevNegRiskAdapterSetUp.sol";
import {NegRiskIdLib} from "src/libraries/NegRiskIdLib.sol";

contract RevNegRiskAdapter_BasicFunctionality_Test is RevNegRiskAdapter_SetUp {
    bytes32 marketId;

    function test_basicSetup() public {
        assertEq(address(revAdapter.ctf()), address(ctf));
        assertEq(address(revAdapter.col()), address(usdc));
        assertEq(address(revAdapter.wcol()), address(wcol));
        assertEq(revAdapter.vault(), vault);
        assertEq(revAdapter.FEE_DENOMINATOR(), 10_000);
    }

    function test_prepareMarket() public {
        vm.prank(oracle);
        bytes32 marketId = revAdapter.prepareMarket(100, "test market");
        
        assertTrue(marketId != bytes32(0));
        assertEq(revAdapter.getQuestionCount(marketId), 0);
    }

    function test_prepareQuestion() public {
        vm.prank(oracle);
        marketId = revAdapter.prepareMarket(100, "test market");
        
        vm.prank(oracle);
        bytes32 questionId = revAdapter.prepareQuestion(marketId, "test question");
        
        assertTrue(questionId != bytes32(0));
        assertEq(revAdapter.getQuestionCount(marketId), 1);
    }

    function test_splitAndMerge() public {
        vm.prank(oracle);
        marketId = revAdapter.prepareMarket(0, "test market");
        
        vm.prank(oracle);
        bytes32 questionId = revAdapter.prepareQuestion(marketId, "test question");
        bytes32 conditionId = revAdapter.getConditionId(questionId);
        
        uint256 amount = 1000;
        
        // Split position
        vm.startPrank(alice);
        usdc.mint(alice, amount);
        usdc.approve(address(revAdapter), amount);
        revAdapter.splitPosition(conditionId, amount);
        vm.stopPrank();
        
        // Check balances
        uint256 yesPositionId = revAdapter.getPositionId(questionId, true);
        uint256 noPositionId = revAdapter.getPositionId(questionId, false);
        
        assertEq(ctf.balanceOf(alice, yesPositionId), amount);
        assertEq(ctf.balanceOf(alice, noPositionId), amount);
        
        // Merge positions
        vm.startPrank(alice);
        ctf.setApprovalForAll(address(revAdapter), true);
        revAdapter.mergePositions(conditionId, amount);
        vm.stopPrank();
        
        // Check balances after merge
        assertEq(ctf.balanceOf(alice, yesPositionId), 0);
        assertEq(ctf.balanceOf(alice, noPositionId), 0);
        assertEq(usdc.balanceOf(alice), amount);
    }

    function test_convertPositions_basic() public {
        // Setup: 2 questions, target index 0
        vm.prank(oracle);
        marketId = revAdapter.prepareMarket(0, "test market");
        
        vm.prank(oracle);
        revAdapter.prepareQuestion(marketId, "question 0");
        vm.prank(oracle);
        revAdapter.prepareQuestion(marketId, "question 1");
        
        uint256 amount = 1000;
        
        // Split initial positions to alice
        for (uint256 i = 0; i < 2; i++) {
            bytes32 questionId = NegRiskIdLib.getQuestionId(marketId, uint8(i));
            bytes32 conditionId = revAdapter.getConditionId(questionId);
            
            vm.startPrank(alice);
            usdc.mint(alice, amount);
            usdc.approve(address(revAdapter), amount);
            revAdapter.splitPosition(conditionId, amount);
            vm.stopPrank();
        }

        uint targetIndex = 0;
        
        // Give brian YES positions for ALL questions (including target)
        // The convertPositions function will burn the target YES position
        for (uint256 i = 0; i < 2; i++) {
            uint256 yesPositionId = revAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, uint8(i)), true);
            if (i != targetIndex){
                vm.prank(alice);
                ctf.safeTransferFrom(alice, brian, yesPositionId, amount, "");
            }
        }
        
        // Convert positions
        vm.startPrank(brian);
        ctf.setApprovalForAll(address(revAdapter), true);
        revAdapter.convertPositions(marketId, targetIndex, amount); // Target index 0
        vm.stopPrank();
        
        // Check results
        uint256 targetNoPositionId = revAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, 0), false);
        uint256 targetYesPositionId = revAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, 0), true);
        uint256 nonTargetYesPositionId = revAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, 1), true);
        
        // Brian should have NO position for target question
        assertEq(ctf.balanceOf(brian, targetNoPositionId), amount);
        // Brian should have no YES positions
        assertEq(ctf.balanceOf(brian, targetYesPositionId), 0);
        assertEq(ctf.balanceOf(brian, nonTargetYesPositionId), 0);
        // YES positions should be burned
        // The target YES position gets burned twice: once from user, once from split
        assertEq(ctf.balanceOf(revAdapter.YES_TOKEN_BURN_ADDRESS(), targetYesPositionId), amount);
        assertEq(ctf.balanceOf(revAdapter.YES_TOKEN_BURN_ADDRESS(), nonTargetYesPositionId), amount);
    }
}