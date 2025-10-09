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

**Input Values**:

**Maker Orders**:

- **Single Order 1**: User2 sells YES tokens (question 5) at price 0.25
  - Token: `yesPositionIds[5]` (2e6 tokens minted)
  - Side: SELL (1)
  - Maker Amount: 2e6 tokens
  - Taker Amount: 0.5e6 USDC
  - Fill Amount: 0.1e6 tokens
- **Single Order 2**: User3 sells YES tokens (question 5) at price 0.25
  - Token: `yesPositionIds[5]` (2e6 tokens minted)
  - Side: SELL (1)
  - Maker Amount: 2e6 tokens
  - Taker Amount: 0.5e6 USDC
  - Fill Amount: 0.1e6 tokens
- **Single Order 3**: User4 sells YES tokens (question 5) at price 0.25
  - Token: `yesPositionIds[5]` (2e6 tokens minted)
  - Side: SELL (1)
  - Maker Amount: 2e6 tokens
  - Taker Amount: 0.5e6 USDC
  - Fill Amount: 0.1e6 tokens
- **Cross-match Order**: User5+User6 buy different tokens
  - User5: `yesPositionIds[3]`, price 0.4, fill 0.1e6
  - User6: `yesPositionIds[4]`, price 0.3, fill 0.1e6

**Taker Order**:

- User1 buys YES tokens (question 5) at price 0.3
  - Token: `yesPositionIds[5]`
  - Side: BUY (0)
  - Maker Amount: 0.3e6 USDC
  - Taker Amount: 1e6 tokens

**Price Validation**:

- Single orders: not required (complementary matching)
- Cross-match orders: 0.4 + 0.3 = 0.7 (cross-matching)
- Taker order: 0.3 (participates in cross-match)
- **Total**: 0.7 + 0.3 = 1.0 ✓

**Expected Outputs**:

**Token Balances After Execution**:

- **User1**: Receives 0.4e6 YES tokens from `yesPositionIds[5]` (from cross-match)
- **User2**: Loses 0.1e6 YES tokens (2e6 - 0.1e6 = 1.9e6 remaining)
- **User3**: Loses 0.1e6 YES tokens (2e6 - 0.1e6 = 1.9e6 remaining)
- **User4**: Loses 0.1e6 YES tokens (2e6 - 0.1e6 = 1.9e6 remaining)
- **User5**: Receives 0.1e6 YES tokens from `yesPositionIds[3]` (from cross-match)
- **User6**: Receives 0.1e6 YES tokens from `yesPositionIds[4]` (from cross-match)

**USDC Balance Changes**:

- **User1**: Loses USDC calculated as:
  - Single orders: `(0.1e6 * makerOrders[0][0].order.price) / 1e6 + (0.1e6 * makerOrders[1][0].order.price) / 1e6 + (0.1e6 * makerOrders[2][0].order.price) / 1e6`
  - Cross-match: `(0.1e6 * takerOrder.order.price) / 1e6`
- **Users 2,3,4**: Receive USDC for tokens sold via single orders
- **Users 5,6**: Pay USDC for tokens received via cross-match

**System Verification**:

- Adapter holds 0 YES tokens for all position IDs
- All token transfers completed successfully

**Order Structs**:

Single Order

```
makerOrders[0] = new ICTFExchange.OrderIntent[](1);
makerOrders[0][0] = _createAndSignOrder(user2, yesPositionIds[5], 1, 2e6, 0.5e6, questionIds[5], 1, _user2PK);
makerFillAmounts[0] = 0.1e6;

makerOrders[1] = new ICTFExchange.OrderIntent[](1);
makerOrders[1][0] = _createAndSignOrder(user3, yesPositionIds[5], 1, 2e6, 0.5e6, questionIds[5], 1, _user3PK);
makerFillAmounts[1] = 0.1e6;

makerOrders[2] = new ICTFExchange.OrderIntent[](1);
makerOrders[2][0] = _createAndSignOrder(user4, yesPositionIds[5], 1, 2e6, 0.5e6, questionIds[5], 1, _user4PK);
makerFillAmounts[2] = 0.1e6;
```

Cross Match Maker Order

```
makerOrders[3] = new ICTFExchange.OrderIntent[](2);
makerOrders[3][0] = _createAndSignOrder(user5, yesPositionIds[3], 0, 0.4e6, 1e6, questionIds[3], 0, _user5PK);
makerOrders[3][1] = _createAndSignOrder(user6, yesPositionIds[4], 0, 0.3e6, 1e6, questionIds[4], 0, _user6PK);
```

Taker Order

```
takerOrder = _createAndSignOrder(user1, yesPositionIds[5], 0, 0.3e6, 1e6, questionIds[5], 0, _user1PK)
```

### 2. Large Scale Scenario (`test_HybridMatchOrders_LargeScaleScenario`)

**Purpose**: Tests system performance and correctness with many orders and questions.

**Setup**:

- 10 questions created
- 5 single orders + 2 cross-match orders
- 1 taker order

**Input Values**:

**Maker Orders**:

- **5 Single Orders**: Each buying NO tokens at price 0.55
  - Token: `noPositionId0` (NO tokens for question 0)
  - Side: BUY (0)
  - Maker Amount: 0.55e6 USDC
  - Taker Amount: 1e6 tokens
  - Fill Amount: 0.05e6 tokens each
- **Cross-match Order 1**: 2 orders buying YES tokens
  - User2: `yesPositionIds[5]`, price 0.2, fill 0.05e6
  - User3: `yesPositionIds[6]`, price 0.35, fill 0.05e6
- **Cross-match Order 2**: 3 orders buying YES tokens
  - User4: `yesPositionIds[7]`, price 0.1, fill 0.05e6
  - User5: `yesPositionIds[8]`, price 0.25, fill 0.05e6
  - User6: `yesPositionIds[9]`, price 0.2, fill 0.05e6

**Taker Order**:

- User1 buys YES tokens (question 0) at price 0.45
  - Token: `yesPositionIds[0]`
  - Side: BUY (0)
  - Maker Amount: 0.45e6 USDC
  - Taker Amount: 1e6 tokens

**Price Validation**:

- Single orders: 0.55 (NO token purchases)
- Cross-match 1: 0.2 + 0.35 = 0.55
- Cross-match 2: 0.1 + 0.25 + 0.2 = 0.55
- Taker order: 0.45
- Maker Order + Taker order = 1
- **Note**: This test has complex price validation with mixed token types

**Expected Outputs**:

**Token Balances After Execution**:

- **User1**: Receives `2*0.05e6 + 5 * (0.05e6 * 1e6 / 0.55e6) = 0.1e6 + 454545 = 554545` YES tokens from `yesPositionIds[0]`
- **Single Order Makers (vm.addr(1000+i))**: Each receives `0.05e6 * 1e6 / 0.55e6 = 90909` NO tokens from `noPositionId0`
- **Cross-match 1 Makers**:
  - User2 gets 0.05e6 YES from `yesPositionIds[5]`
  - User3 gets 0.05e6 YES from `yesPositionIds[6]`
  - User4 gets 0.05e6 YES from `yesPositionIds[7]`
  - User5 gets 0.05e6 YES from `yesPositionIds[8]`
  - User6 gets 0.05e6 YES from `yesPositionIds[9]`
- **Cross-match 2 Makers (vm.addr(2000+i))**:
  - User 2000 gets 0.05e6 YES from `yesPositionIds[7]`
  - User 2001 gets 0.05e6 YES from `yesPositionIds[8]`
  - User 2002 gets 0.05e6 YES from `yesPositionIds[9]`
  - User 2003 gets 0.05e6 YES from `yesPositionIds[5]`
  - User 2004 gets 0.05e6 YES from `yesPositionIds[6]`

**System Verification**:

- Adapter holds 0 YES tokens and 0 NO tokens
- All cross-match participants receive their expected tokens

### 3. All Sell Orders Scenario (`test_HybridMatchOrders_AllSellOrdersScenario`)

**Purpose**: Tests cross-matching when all participants are selling tokens.

**Setup**:

- 4 questions created
- 1 cross-match order with 3 makers + 1 taker
- All participants selling NO tokens

**Input Values**:

**Maker Orders**:

- **Cross-match Order**: 3 makers selling NO tokens
  - User2: `noPositionIds[1]`, price 0.25, fill 1e6 tokens
  - User3: `noPositionIds[2]`, price 0.25, fill 1e6 tokens
  - User4: `noPositionIds[3]`, price 0.25, fill 1e6 tokens

**Taker Order**:

- User1 sells NO tokens (question 0) at price 0.25
  - Token: `noPositionIds[0]`
  - Side: SELL (1)
  - Maker Amount: 1e6 tokens
  - Taker Amount: 0.25e6 USDC

**Price Validation**:

- Combined Price: 0.25 + 0.25 + 0.25 + 0.25 = 1.0 ✓

**Expected Outputs**:

**Token Balances After Execution**:

- **User1**: Loses 1e6 NO tokens from `noPositionIds[0]` (sold all tokens)
- **User2**: Loses 1e6 NO tokens from `noPositionIds[1]` (sold all tokens)
- **User3**: Loses 1e6 NO tokens from `noPositionIds[2]` (sold all tokens)
- **User4**: Loses 1e6 NO tokens from `noPositionIds[3]` (sold all tokens)

**USDC Balance Changes**:

- **User1**: Gains 0.75e6 USDC for tokens sold
- **User2**: Gains 0.75e6 USDC for tokens sold
- **User3**: Gains 0.75e6 USDC for tokens sold
- **User4**: Gains 0.75e6 USDC for tokens sold

**System Verification**:

- Adapter holds 0 NO tokens for all position IDs
- All users successfully sold their tokens and received USDC
- System maintains balance conservation

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

**Input Values**:

**Maker Orders**:

- **Cross-match Order**: 2 makers buying YES tokens
  - User2: `yesPositionIds[0]`, price 0.3, fill 0.1e6
  - User3: `yesPositionIds[1]`, price 0.4, fill 0.1e6

**Taker Order**:

- User1 buys YES tokens (question 2) at price 0.2
  - Token: `yesPositionIds[2]`
  - Side: BUY (0)
  - Maker Amount: 0.2e6 USDC
  - Taker Amount: 1e6 tokens

**Price Validation**:

- **Invalid Price Sum**: 0.3 + 0.4 + 0.2 = 0.9 ≠ 1.0

**Expected Behavior**:

- Transaction should revert with `InvalidCombinedPrice` error
- System maintains price validation integrity
- No token transfers occur

### 5. Insufficient USDC Balance (`test_HybridMatchOrders_InsufficientUSDCBalance`)

**Purpose**: Tests system behavior when user lacks sufficient USDC.

**Setup**:

- User1 has only 1 USDC
- Taker order requires 2 USDC
- Maker order available for matching

**Input Values**:

**Maker Orders**:

- **Single Order**: User2 sells YES tokens
  - Token: `yesPositionId`
  - Side: SELL (1)
  - Maker Amount: 1e6 tokens
  - Taker Amount: 0.5e6 USDC
  - Fill Amount: 0.1e6 tokens

**Taker Order**:

- User1 buys YES tokens (insufficient USDC)
  - Token: `yesPositionId`
  - Side: BUY (0)
  - Maker Amount: 2e6 USDC (but only has 1e6)
  - Taker Amount: 1e6 tokens

**Expected Behavior**:

- Transaction should revert due to insufficient USDC balance
- System prevents partial execution
- No token transfers occur

### 6. Invalid Single Order Count (`test_HybridMatchOrders_InvalidSingleOrderCount`)

**Purpose**: Tests system robustness with incorrect single order count parameter.

**Setup**:

- 2 single orders created
- Incorrect single order count passed (1 instead of 2)

**Input Values**:

**Maker Orders**:

- **Single Order 1**: User2 sells YES tokens
  - Token: `yesPositionId`
  - Side: SELL (1)
  - Maker Amount: 1e6 tokens
  - Taker Amount: 0.5e6 USDC
  - Fill Amount: 0.1e6 tokens
- **Single Order 2**: User3 sells YES tokens
  - Token: `yesPositionId`
  - Side: SELL (1)
  - Maker Amount: 1e6 tokens
  - Taker Amount: 0.5e6 USDC
  - Fill Amount: 0.1e6 tokens

**Taker Order**:

- User1 buys YES tokens
  - Token: `yesPositionId`
  - Side: BUY (0)
  - Maker Amount: 1e6 USDC
  - Taker Amount: 1e6 tokens

**Invalid Parameter**:

- Single order count passed as 1 (should be 2)

**Expected Behavior**:

- Transaction should revert due to array bounds issues
- System prevents processing with incorrect parameters
- No token transfers occur

## Stress Tests

### 7. Extreme Price Distribution (`test_HybridMatchOrders_ExtremePriceDistribution`)

**Purpose**: Tests system with highly skewed price distributions.

**Setup**:

- 5 questions created
- 4 maker orders at price 0.1 each
- 1 taker order at price 0.6
- **Total Price**: 0.1 + 0.1 + 0.1 + 0.1 + 0.6 = 1.0 ✓

**Input Values**:

**Maker Orders**:

- **Cross-match Order**: 4 makers buying YES tokens
  - User2: `yesPositionIds[0]`, price 0.1, fill 0.1e6
  - User3: `yesPositionIds[1]`, price 0.1, fill 0.1e6
  - User4: `yesPositionIds[2]`, price 0.1, fill 0.1e6
  - User5: `yesPositionIds[3]`, price 0.1, fill 0.1e6

**Taker Order**:

- User1 buys YES tokens (question 4) at price 0.6
  - Token: `yesPositionIds[4]`
  - Side: BUY (0)
  - Maker Amount: 0.6e6 USDC
  - Taker Amount: 1e6 tokens

**Price Validation**:

- **Total Price**: 0.1 + 0.1 + 0.1 + 0.1 + 0.6 = 1.0 ✓

**Expected Outputs**:

**Token Balances After Execution**:

- **User1**: Receives 0.1e6 YES tokens from `yesPositionIds[4]` (from taker order)
- **User2**: Receives 0.1e6 YES tokens from `yesPositionIds[0]` (from cross-match)
- **User3**: Receives 0.1e6 YES tokens from `yesPositionIds[1]` (from cross-match)
- **User4**: Receives 0.1e6 YES tokens from `yesPositionIds[2]` (from cross-match)
- **User5**: Receives 0.1e6 YES tokens from `yesPositionIds[3]` (from cross-match)

**USDC Balance Changes**:

- **User1**: Loses `(0.1e6 * takerOrder.order.price) / 1e6` USDC for tokens received
- **User2**: Loses `(0.1e6 * makerOrders[0][0].order.price) / 1e6` USDC for tokens received
- **User3**: Loses `(0.1e6 * makerOrders[0][0].order.price) / 1e6` USDC for tokens received
- **User4**: Loses `(0.1e6 * makerOrders[0][0].order.price) / 1e6` USDC for tokens received
- **User5**: Loses `(0.1e6 * makerOrders[0][0].order.price) / 1e6` USDC for tokens received

**System Verification**:

- Adapter holds 0 YES tokens for all position IDs
- All participants received their expected tokens

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

**Input Values**:

**Maker Orders**:

- **Single Order**: User2 sells YES tokens
  - Token: `yesPositionIds[3]`
  - Side: SELL (1)
  - Maker Amount: 1e6 tokens
  - Taker Amount: 0.25e6 USDC
  - Fill Amount: 0.1e6 tokens
- **Cross-match Order**: 2 makers buying YES tokens
  - User3: `yesPositionIds[1]`, price 0.35, fill 0.1e6
  - User4: `yesPositionIds[2]`, price 0.4, fill 0.1e6

**Taker Order**:

- User1 buys YES tokens (question 3) at price 0.25
  - Token: `yesPositionIds[3]`
  - Side: BUY (0)
  - Maker Amount: 0.25e6 USDC
  - Taker Amount: 1e6 tokens

**Price Validation**:

- **Total Price**: 0.25 + 0.5 + 0.25 = 1.0 ✓

**Expected Outputs**:

**Token Balances After Execution**:

- **User1**: Receives 0.2e6 YES tokens from `yesPositionIds[3]`
- **User2**: Loses 0.1e6 YES tokens from `yesPositionIds[3]`
- **User3**: Receives 0.1e6 YES tokens from `yesPositionIds[1]`
- **User4**: Receives 0.1e6 YES tokens from `yesPositionIds[2]`

**Financial Verification**:

- Adapter USDC balance unchanged
- Adapter WCOL balance unchanged
- System maintains financial neutrality

### 9. Self-Financing with Mint/Sell Order (`test_HybridMatchOrders_SelfFinancingProperty_mint_sell_order`)

**Purpose**: Tests self-financing property with mint and sell operations.

**Setup**:

- Similar to test #8 but with mint/sell operations
- Includes USDC minting to users and vault
- Tests more complex financial flows

**Input Values**:

**Maker Orders**:

- **Single Order**: User2 buys NO tokens
  - Token: `noPositionId3` (NO tokens for question 3)
  - Side: BUY (0)
  - Maker Amount: 0.25e6 USDC
  - Taker Amount: 1e6 tokens
  - Fill Amount: 0.1e6 tokens
- **Cross-match Order**: 2 makers buying YES tokens
  - User3: `yesPositionIds[1]`, price 0.35, fill 0.1e6
  - User4: `yesPositionIds[2]`, price 0.4, fill 0.1e6

**Taker Order**:

- User1 buys YES tokens (question 3) at price 0.25
  - Token: `yesPositionIds[3]`
  - Side: BUY (0)
  - Maker Amount: 0.25e6 USDC
  - Taker Amount: 1e6 tokens

**Special Operations**:

- USDC minted to users and vault
- Tests mint/sell operations

**Verification**:

- Adapter maintains zero net balance changes
- System handles mint/sell operations correctly

### 10. Balance Conservation (`test_HybridMatchOrders_BalanceConservation`)

**Purpose**: Verifies total system balance conservation.

**Setup**:

- 3 questions created
- 1 cross-match order + 1 taker order
- **Total Price**: 0.3 + 0.4 + 0.3 = 1.0 ✓

**Input Values**:

**Maker Orders**:

- **Cross-match Order**: 2 makers buying YES tokens
  - User2: `yesPositionIds[0]`, price 0.3, fill 0.1e6
  - User3: `yesPositionIds[1]`, price 0.4, fill 0.1e6

**Taker Order**:

- User1 buys YES tokens (question 2) at price 0.3
  - Token: `yesPositionIds[2]`
  - Side: BUY (0)
  - Maker Amount: 0.3e6 USDC
  - Taker Amount: 1e6 tokens

**Price Validation**:

- **Total Price**: 0.3 + 0.4 + 0.3 = 1.0 ✓

**Expected Outputs**:

**Token Balances After Execution**:

- **User1**: Receives 0.1e6 YES tokens from `yesPositionIds[2]` (from taker order)
- **User2**: Receives 0.1e6 YES tokens from `yesPositionIds[0]` (from cross-match)
- **User3**: Receives 0.1e6 YES tokens from `yesPositionIds[1]` (from cross-match)

**USDC Balance Changes**:

- **User1**: Loses `(0.1e6 * takerOrder.order.price) / 1e6` USDC for tokens received
- **User2**: Loses `(0.1e6 * makerOrders[0][0].order.price) / 1e6` USDC for tokens received
- **User3**: Loses `(0.1e6 * makerOrders[0][1].order.price) / 1e6` USDC for tokens received

**System Verification**:

- Adapter holds 0 YES tokens for all position IDs
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
