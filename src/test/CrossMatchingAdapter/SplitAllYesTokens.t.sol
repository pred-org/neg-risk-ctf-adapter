// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {CrossMatchingAdapter, ICrossMatchingAdapterEE} from "src/CrossMatchingAdapter.sol";
import {NegRiskAdapter} from "src/NegRiskAdapter.sol";
import {NegRiskOperator} from "src/NegRiskOperator.sol";
import {RevNegRiskAdapter} from "src/RevNegRiskAdapter.sol";
import {IRevNegRiskAdapter} from "src/interfaces/IRevNegRiskAdapter.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {INegRiskAdapter} from "src/interfaces/INegRiskAdapter.sol";
import {ICTFExchange} from "src/interfaces/ICTFExchange.sol";
import {CTFExchange} from "lib/ctf-exchange/src/exchange/CTFExchange.sol";
import {Deployer} from "lib/ctf-exchange/src/dev/util/Deployer.sol";
import {TestHelper} from "lib/ctf-exchange/src/dev/TestHelper.sol";
import {WrappedCollateral} from "src/WrappedCollateral.sol";

contract SplitAllYesTokensTest is Test, TestHelper {
    CrossMatchingAdapter public adapter;
    NegRiskAdapter public negRiskAdapter;
    NegRiskOperator public negRiskOperator;
    RevNegRiskAdapter public revNegRiskAdapter;
    CTFExchange public ctfExchange;
    IConditionalTokens public ctf;
    IERC20 public usdc;
    address public vault;
    WrappedCollateral public wcol;

    address public oracle;
    
    // Test user
    address public user1;
    
    // Market and question IDs
    bytes32 public marketId;
    bytes32[] public questionIds;
    uint256[] public yesPositionIds;
    uint256[] public noPositionIds;
    bytes32[] public conditionIds;

    uint256[] public dummyPayout;

    function setUp() public {
        dummyPayout = [0, 1];
        oracle = vm.createWallet("oracle").addr;
        
        // Deploy mock USDC first
        usdc = IERC20(address(new MockUSDC()));
        vm.label(address(usdc), "USDC");
        
        // Deploy real ConditionalTokens contract using Deployer
        ctf = IConditionalTokens(Deployer.ConditionalTokens());
        vm.label(address(ctf), "ConditionalTokens");
        
        // Deploy mock vault
        vault = address(new MockVault());
        vm.label(vault, "Vault");

        // Deploy NegRiskAdapter
        negRiskAdapter = new NegRiskAdapter(address(ctf), address(usdc), vault);
        negRiskOperator = new NegRiskOperator(address(negRiskAdapter));
        negRiskOperator.setOracle(address(oracle));
        vm.label(address(negRiskOperator), "NegRiskOperator");
        vm.label(address(negRiskAdapter), "NegRiskAdapter");

        // Deploy real CTFExchange contract
        ctfExchange = new CTFExchange(address(usdc), address(negRiskAdapter), address(0), address(0));
        vm.label(address(ctfExchange), "CTFExchange");

        // Deploy RevNegRiskAdapter
        revNegRiskAdapter = new RevNegRiskAdapter(address(ctf), address(usdc), vault, INegRiskAdapter(address(negRiskAdapter)));
        vm.label(address(revNegRiskAdapter), "RevNegRiskAdapter");
        
        negRiskAdapter.addAdmin(address(ctfExchange));

        vm.startPrank(address(ctfExchange));
        ctf.setApprovalForAll(address(negRiskAdapter), true);
        ctf.setApprovalForAll(address(ctfExchange), true);
        vm.stopPrank();

        // Deploy CrossMatchingAdapter
        adapter = new CrossMatchingAdapter(negRiskOperator, ICTFExchange(address(ctfExchange)), IRevNegRiskAdapter(address(revNegRiskAdapter)));
        vm.label(address(adapter), "CrossMatchingAdapter");

        // Add RevNegRiskAdapter as owner of WrappedCollateral so it can mint tokens
        vm.startPrank(address(negRiskAdapter));
        ctf.setApprovalForAll(address(ctfExchange), true);
        negRiskAdapter.wcol().addOwner(address(revNegRiskAdapter));
        negRiskAdapter.wcol().addOwner(address(adapter));
        vm.stopPrank();

        // Get WCOL reference
        wcol = WrappedCollateral(address(negRiskAdapter.wcol()));

        // Setup vault with USDC and approve adapter
        MockUSDC(address(usdc)).mint(address(vault), 1000000000e6);
        vm.startPrank(address(vault));
        MockUSDC(address(usdc)).approve(address(adapter), type(uint256).max);
        vm.stopPrank();

        // Set up test user
        user1 = vm.addr(0x1111);
        vm.label(user1, "User1");
        
        // Set up market with 5 questions for testing
        marketId = negRiskOperator.prepareMarket(0, "Test Market");
        
        // Create 5 questions for testing
        questionIds = new bytes32[](5);
        yesPositionIds = new uint256[](5);
        noPositionIds = new uint256[](5);
        conditionIds = new bytes32[](5);
        
        for (uint256 i = 0; i < 5; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            noPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], false);
            conditionIds[i] = negRiskAdapter.getConditionId(questionIds[i]);
        }
        
        // Set market as prepared (required for convertPositions)
        negRiskAdapter.setPrepared(marketId);
        
        // Set up initial token balances for user
        _setupUser(user1, 100000000e6);
        
        // Set CTFExchange as operator for ConditionalTokens (ERC1155)
        ctf.setApprovalForAll(address(ctfExchange), true);
    }
    
    function _setupUser(address user, uint256 usdcBalance) internal {
        vm.startPrank(user);
        deal(address(usdc), user, usdcBalance);
        usdc.approve(address(adapter), type(uint256).max);
        usdc.approve(address(ctfExchange), type(uint256).max);
        ctf.setApprovalForAll(address(ctfExchange), true);
        ctf.setApprovalForAll(address(adapter), true);
        vm.stopPrank();
    }

    function testSplitAllYesTokens_Basic() public {
        console.log("=== Testing splitAllYesTokens: User sends 1 USDC and gets YES tokens for all questions ===");
        
        uint256 fillAmount = 1e6; // 1 USDC
        
        // Record initial balances
        uint256 initialUSDC = usdc.balanceOf(user1);
        uint256[] memory initialYES = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            initialYES[i] = ctf.balanceOf(user1, yesPositionIds[i]);
            console.log("Initial YES tokens for question %s: %s", i, initialYES[i]);
        }
        
        // Verify market is prepared
        assertTrue(negRiskAdapter.getPrepared(marketId), "Market should be prepared");
        assertTrue(negRiskAdapter.getOracle(marketId) != address(0), "Market should have an oracle");
        assertEq(negRiskAdapter.getQuestionCount(marketId), 5, "Market should have 5 questions");
        
        // Execute splitAllYesTokens
        vm.prank(user1);
        adapter.splitAllYesTokens(marketId, fillAmount);
        
        // Verify USDC was transferred from user1
        uint256 finalUSDC = usdc.balanceOf(user1);
        assertEq(finalUSDC, initialUSDC - fillAmount, "User1 should have paid 1 USDC");
        console.log("User1 USDC balance: %s (paid %s)", finalUSDC, fillAmount);
        
        // Verify user1 received YES tokens for ALL questions
        // Each question should have received fillAmount (1e6) YES tokens
        for (uint256 i = 0; i < 5; i++) {
            uint256 finalYES = ctf.balanceOf(user1, yesPositionIds[i]);
            uint256 expectedYES = initialYES[i] + fillAmount;
            assertEq(
                finalYES,
                expectedYES,
                string(abi.encodePacked("User1 should have received ", vm.toString(fillAmount), " YES tokens for question ", vm.toString(i)))
            );
            console.log("User1 YES tokens for question %s: %s (received %s)", i, finalYES, fillAmount);
        }
        
        // Verify adapter has no remaining YES tokens (all were transferred to user)
        for (uint256 i = 0; i < 5; i++) {
            uint256 adapterYES = ctf.balanceOf(address(adapter), yesPositionIds[i]);
            assertEq(
                adapterYES,
                0,
                string(abi.encodePacked("Adapter should have no remaining YES tokens for question ", vm.toString(i)))
            );
        }
        
        // Verify adapter has no remaining NO tokens (all were consumed by convertPositions)
        for (uint256 i = 0; i < 5; i++) {
            uint256 adapterNO = ctf.balanceOf(address(adapter), noPositionIds[i]);
            assertEq(
                adapterNO,
                0,
                string(abi.encodePacked("Adapter should have no remaining NO tokens for question ", vm.toString(i)))
            );
        }
        
        // Verify adapter has no remaining USDC
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no remaining USDC");
        
        console.log("Test passed: User successfully received YES tokens for all 5 questions!");
    }
}

// Mock USDC contract
contract MockUSDC {
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
}

// Mock Vault contract
contract MockVault {
    mapping(address => uint256) public balanceOf;
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

