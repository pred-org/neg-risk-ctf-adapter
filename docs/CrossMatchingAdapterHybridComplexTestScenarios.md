# CrossMatchingAdapter Hybrid Complex Test Scenarios Documentation

## Overview

This document provides comprehensive coverage of all test scenarios and conditions covered in `CrossMatchingAdapterHybridComplex.t.sol`. The test file validates the hybrid order matching functionality that combines both single orders (processed via CTFExchange) and cross-match orders (processed via custom cross-matching logic).

## Test Architecture

### Core Components

- **CrossMatchingAdapter**: Main contract being tested
- **NegRiskAdapter**: Handles negative risk token operations
- **RevNegRiskAdapter**: Handles reverse negative risk operations
- **CTFExchange**: Processes single orders
- **ConditionalTokens**: ERC1155 token contract for YES/NO positions
- **MockUSDC**: Test USDC token implementation

### Test Users

- **6 test users** (user1-user6) with private keys for order signing
- **Additional users** (vm.addr(1000+i), vm.addr(2000+i)) for large-scale scenarios

## Test Scenarios

### 1. Complex Mixed Scenario (`test_HybridMatchOrders_ComplexMixedScenario`)

**Purpose**: Tests the core hybrid functionality with multiple single orders and cross-match orders.

**Setup**:

- 6 questions created with corresponding YES/NO position tokens
- 3 single orders (SHORT intent) + 1 cross-match order (LONG intent)
- 1 taker order (LONG intent)

**Order Configuration**:

- **Single Order 1**: User2 sells YES tokens (question 0) at price 0.25
- **Single Order 2**: User3 sells YES tokens (question 1) at price 0.15
- **Single Order 3**: User4 sells YES tokens (question 2) at price 0.1
- **Cross-match Order**: User5+User6 buy different tokens (prices 0.4 + 0.3 = 0.7)
- **Taker Order**: User1 buys YES tokens (question 5) at price 0.3

**Price Validation**:

- Single orders: 0.25 + 0.15 + 0.1 = 0.5 (complementary matching)
- Cross-match orders: 0.4 + 0.3 = 0.7 (cross-matching)
- Taker order: 0.3 (participates in cross-match)
- **Total**: 0.7 + 0.3 = 1.0 ✓

**Verification**:

- Token balances correctly updated for all participants
- Cross-match participants receive their respective tokens
- Single order participants have tokens deducted

### 2. Large Scale Scenario (`test_HybridMatchOrders_LargeScaleScenario`)

**Purpose**: Tests system performance and correctness with many orders and questions.

**Setup**:

- 10 questions created
- 5 single orders + 2 cross-match orders
- 1 taker order

**Order Configuration**:

- **5 Single Orders**: Each at price 0.1 (total = 0.5)
- **Cross-match Order 1**: 2 orders at prices 0.2 + 0.35 = 0.55
- **Cross-match Order 2**: 3 orders at prices 0.1 + 0.25 + 0.2 = 0.55
- **Taker Order**: Price 0.45

**Price Validation**:

- Total prices: 0.5 (single) + 0.55 (cross-match 1) + 0.55 (cross-match 2) + 0.45 (taker) = 2.05
- **Note**: This test appears to have price validation issues (sum ≠ 1.0)

### 3. All Sell Orders Scenario (`test_HybridMatchOrders_AllSellOrdersScenario`)

**Purpose**: Tests cross-matching when all participants are selling tokens.

**Setup**:

- 4 questions created
- 1 cross-match order with 3 makers + 1 taker
- All participants selling NO tokens

**Order Configuration**:

- **3 Maker Orders**: Each selling NO tokens at price 0.25
- **Taker Order**: Selling NO tokens at price 0.25
- **Combined Price**: 0.25 + 0.25 + 0.25 + 0.25 = 1.0 ✓

**Key Features**:

- All participants are sellers (side = 1)
- Tests the reverse scenario where users provide tokens instead of USDC
- Validates cross-matching works for sell-side orders

## Edge Case Tests

### 4. Invalid Combined Price (`test_HybridMatchOrders_InvalidCombinedPrice`)

**Purpose**: Ensures system rejects orders when prices don't sum to 1.0.

**Setup**:

- 3 questions created
- 2 maker orders + 1 taker order
- **Invalid Price Sum**: 0.3 + 0.4 + 0.2 = 0.9 ≠ 1.0

**Expected Behavior**:

- Transaction should revert with `InvalidCombinedPrice` error
- System maintains price validation integrity

### 5. Insufficient USDC Balance (`test_HybridMatchOrders_InsufficientUSDCBalance`)

**Purpose**: Tests system behavior when user lacks sufficient USDC.

**Setup**:

- User1 has only 1 USDC
- Taker order requires 2 USDC
- Maker order available for matching

**Expected Behavior**:

- Transaction should revert due to insufficient USDC balance
- System prevents partial execution

### 6. Invalid Single Order Count (`test_HybridMatchOrders_InvalidSingleOrderCount`)

**Purpose**: Tests system robustness with incorrect single order count parameter.

**Setup**:

- 2 single orders created
- Incorrect single order count passed (1 instead of 2)

**Expected Behavior**:

- Transaction should revert due to array bounds issues
- System prevents processing with incorrect parameters

## Stress Tests

### 7. Extreme Price Distribution (`test_HybridMatchOrders_ExtremePriceDistribution`)

**Purpose**: Tests system with highly skewed price distributions.

**Setup**:

- 5 questions created
- 4 maker orders at price 0.1 each
- 1 taker order at price 0.6
- **Total Price**: 0.1 + 0.1 + 0.1 + 0.1 + 0.6 = 1.0 ✓

**Key Features**:

- Tests system with one dominant price (0.6) and many small prices (0.1)
- Validates system handles extreme price distributions correctly

## Self-Financing Verification Tests

### 8. Self-Financing Property (`test_HybridMatchOrders_SelfFinancingProperty`)

**Purpose**: Verifies the adapter maintains self-financing property (no net token changes).

**Setup**:

- 4 questions created
- 1 single order + 1 cross-match order + 1 taker order
- **Total Price**: 0.25 + 0.5 + 0.25 = 1.0 ✓

**Verification**:

- Adapter USDC balance unchanged
- Adapter WCOL balance unchanged
- System maintains financial neutrality

### 9. Self-Financing with Mint/Sell Order (`test_HybridMatchOrders_SelfFinancingProperty_mint_sell_order`)

**Purpose**: Tests self-financing property with mint and sell operations.

**Setup**:

- Similar to test #8 but with mint/sell operations
- Includes USDC minting to users and vault
- Tests more complex financial flows

**Verification**:

- Adapter maintains zero net balance changes
- System handles mint/sell operations correctly

### 10. Balance Conservation (`test_HybridMatchOrders_BalanceConservation`)

**Purpose**: Verifies total system balance conservation.

**Setup**:

- 3 questions created
- 1 cross-match order + 1 taker order
- **Total Price**: 0.3 + 0.4 + 0.3 = 1.0 ✓

**Verification**:

- Total USDC supply unchanged
- Vault USDC balance unchanged
- System maintains global balance conservation

## Key Test Conditions

### Price Validation

- **Valid**: All order prices must sum to exactly 1.0
- **Invalid**: Any price sum ≠ 1.0 should revert
- **Extreme**: System handles skewed price distributions

### Token Operations

- **Minting**: Users receive appropriate tokens
- **Burning**: Users have tokens deducted correctly
- **Transfers**: Cross-match participants receive their tokens

### Financial Integrity

- **Self-Financing**: Adapter maintains zero net balance
- **Conservation**: Total system balances preserved
- **Sufficiency**: Users must have adequate USDC

### Order Processing

- **Single Orders**: Processed via CTFExchange
- **Cross-Match Orders**: Processed via custom logic
- **Hybrid**: Both types processed in single transaction

### Error Handling

- **Invalid Prices**: Reverts with specific error
- **Insufficient Balance**: Prevents partial execution
- **Invalid Parameters**: Handles incorrect input gracefully

## Test Coverage Summary

| Test Category     | Count  | Coverage                           |
| ----------------- | ------ | ---------------------------------- |
| Complex Scenarios | 3      | Core hybrid functionality          |
| Edge Cases        | 3      | Error conditions and validation    |
| Stress Tests      | 1      | Performance and extreme conditions |
| Self-Financing    | 3      | Financial integrity verification   |
| **Total**         | **10** | **Comprehensive coverage**         |

## Key Assertions

1. **Token Balance Updates**: All participants receive/deduct correct token amounts
2. **Price Validation**: Combined prices always equal 1.0
3. **Financial Integrity**: Adapter maintains zero net balance
4. **Error Handling**: Invalid conditions properly revert
5. **Balance Conservation**: Total system balances preserved
6. **Order Processing**: Both single and cross-match orders processed correctly

This test suite provides comprehensive coverage of the CrossMatchingAdapter's hybrid order matching functionality, ensuring robust operation across various scenarios and edge cases.
