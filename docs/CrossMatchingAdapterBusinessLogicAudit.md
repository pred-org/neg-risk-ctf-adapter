# CrossMatchingAdapter Business Logic Documentation

## Overview

The `CrossMatchingAdapter` enables cross-matching of multiple orders across different questions within a NegRisk market, allowing users to trade conditional tokens (YES/NO tokens) across multiple questions simultaneously. The adapter implements a self-financing mechanism that balances token creation and distribution.

### Key Concepts

- **Cross-Matching**: Matching multiple orders across different questions in a single transaction
- **Self-Financing**: All WCOL minted during operations must be burned by the end, ensuring no net token creation
- **Pivot Question**: One question used as the starting point for splitting positions to create YES/NO tokens
- **WCOL (Wrapped Collateral)**: Wrapped USDC used as collateral in the Conditional Tokens Framework (CTF)

### Order Types

- **LONG Intent**:
  - BUY = Buy YES tokens
  - SELL = Sell NO tokens
- **SHORT Intent**:
  - BUY = Buy NO tokens
  - SELL = Sell YES tokens

### Expected Contract Behaviors

- **NegRiskAdapter**: Provides position splitting, merging, and conversion operations
- **RevNegRiskAdapter**: Provides YES token merging operations
- **CTFExchange**: Validates orders and handles single-order matching
- **WrappedCollateral**: Manages USDC wrapping/unwrapping with mint/burn capabilities
- **ConditionalTokens**: Core CTF contract for position splitting and merging

---

## Constructor

### Function: `constructor`

**Functionality:**
Initializes the adapter with required dependencies and sets up token approvals.

**Why Required:**
Establishes immutable dependencies and configures approvals needed for cross-matching operations.

**Inputs:**

- `negOperator_` (NegRiskOperator): The NegRisk operator contract
- `ctfExchange_` (ICTFExchange): CTF exchange contract address
- `revNeg_` (IRevNegRiskAdapter): Reverse NegRisk adapter contract

**Note:** USDC address is derived from `neg.col()` during construction

**Outputs:**
None (constructor)

**Expected Approvals:**

- CTF contract approved for unlimited WCOL transfers
- NegRiskAdapter approved for unlimited USDC transfers
- CTF approval for all tokens to revNeg and neg adapters

---

## Public Functions

### Function: `hybridMatchOrders`

**Functionality:**
Main entry point that processes a mix of single orders (delegated to CTF exchange) and cross-match orders (handled internally). Routes orders based on their type.

**Why Required:**
Allows handling both simple single-order matches and complex cross-matching scenarios in a single transaction, optimizing gas usage.

**Inputs:**

- `marketId` (bytes32): The market identifier
- `takerOrder` (ICTFExchange.OrderIntent): The taker's order intent
- `makerOrders` (MakerOrder[]): Array of maker orders with types (SINGLE or CROSS_MATCH)
- `takerFillAmounts` (uint256[]): Array of fill amounts for each maker order pair
- `singleOrderCount` (uint8): Number of single orders to batch process

**Outputs:**
None (external function)

**Expected Behavior:**

- Separates single orders from cross-match orders
- Routes cross-match orders to `crossMatchLongOrders` or `crossMatchShortOrders` based on intent
- Batches single orders and delegates to `ctfExchange.matchOrders`

---

### Function: `crossMatchLongOrders`

**Functionality:**
Handles cross-matching for LONG intent orders across multiple questions. Supports scenarios where some questions may be resolved while others are unresolved.

**Why Required:**
Enables efficient cross-matching for LONG intent orders (buy YES, sell NO) across multiple questions, allowing users to trade on multiple outcomes simultaneously.

**Inputs:**

- `marketId` (bytes32): The market identifier
- `takerOrder` (ICTFExchange.OrderIntent): The taker's order intent
- `multiOrderMaker` (ICTFExchange.OrderIntent[]): Array of maker orders for cross-matching
- `takerFillAmount` (uint256): Fill amount for the taker order
- `makerFillAmounts` (uint256[]): Array of fill amounts for each maker order

**Outputs:**
None (public function)

**Validation Requirements:**

- All unresolved questions must be present in orders (via `allUnresolvedQuestionsPresent` modifier)
- Combined price of all orders must be greater than or equal to 1 (required for self-financing)
- Fill amount must be non-zero
- All orders validated via `ctfExchange.performOrderChecks`

**Expected Behavior:**

- Executes cross-matching logic via `_executeLongCrossMatch`
- Refunds any leftover tokens to the taker

---

### Function: `crossMatchShortOrders`

**Functionality:**
Handles cross-matching for SHORT intent orders across multiple questions. In SHORT orders, users buy NO tokens or sell YES tokens.

**Why Required:**
Enables cross-matching for SHORT intent orders, providing users with the ability to take opposite positions (buying NO instead of YES, selling YES instead of NO).

**Inputs:**

- `marketId` (bytes32): The market identifier
- `takerOrder` (ICTFExchange.OrderIntent): The taker's order intent
- `multiOrderMaker` (ICTFExchange.OrderIntent[]): Array of maker orders for cross-matching
- `takerFillAmount` (uint256): Fill amount for the taker order
- `makerFillAmounts` (uint256[]): Array of fill amounts for each maker order

**Outputs:**
None (public function)

**Validation Requirements:**

- All unresolved questions must be present in orders
- Combined price of all orders must be greater than or equal to 1
- Fill amount must be non-zero
- All orders validated via `ctfExchange.performOrderChecks`

**Expected Behavior:**

- Executes short cross-matching via `_executeShortCrossMatch`
- Refunds any leftover tokens to the taker

---

### Function: `getCollateral`

**Functionality:**
Returns the address of the collateral token (WCOL) used by this adapter.

**Why Required:**
Required by the `AssetOperations` interface for external contracts to query the collateral token.

**Inputs:**
None

**Outputs:**

- `address`: The address of the WrappedCollateral (WCOL) contract

---

### Function: `getCtf`

**Functionality:**
Returns the address of the Conditional Tokens Framework (CTF) contract used by this adapter.

**Why Required:**
Required by the `AssetOperations` interface for external contracts to query the CTF contract.

**Inputs:**
None

**Outputs:**

- `address`: The address of the ConditionalTokens contract

---

## Internal Functions

### Function: `_executeLongCrossMatch`

**Functionality:**
Core execution logic for LONG cross-matching. Handles USDC collection, position splitting, token conversion, distribution, and self-financing.

**Why Required:**
Encapsulates the cross-matching logic for LONG orders, ensuring self-financing by managing WCOL minting and burning.

**Inputs:**

- `parsedOrders` (Parsed[]): Array of parsed order data
- `marketId` (bytes32): The market identifier
- `totalSellUSDC` (uint256): Total USDC amount needed for sell orders
- `fillAmount` (uint256): The fill amount for all orders

**Outputs:**
None (internal function)

**Expected Behavior:**

- Collects USDC from buyers and wraps to WCOL
- Mints WCOL if needed for sell orders
- Splits pivot position (taker's question) to create YES + NO tokens
- Converts NO tokens from pivot to YES tokens for other questions
- Distributes YES tokens to buyers (with fee collection)
- Processes sell orders by merging NO tokens with YES tokens
- Burns excess WCOL to maintain self-financing

**Self-Financing Invariant:**
All WCOL minted must be burned by the end of the operation.

---

### Function: `_executeShortCrossMatch`

**Functionality:**
Core execution logic for SHORT cross-matching. Processes orders where users buy NO tokens or sell YES tokens.

**Why Required:**
SHORT orders require different handling due to reversed token flow (NO tokens for buyers, YES tokens for sellers).

**Inputs:**

- `parsedOrders` (Parsed[]): Array of parsed order data
- `marketId` (bytes32): The market identifier
- `totalSellUSDC` (uint256): Total USDC amount needed for sell orders
- `fillAmount` (uint256): The fill amount for all orders

**Outputs:**
None (internal function)

**Expected Behavior:**

- Collects USDC from buyers
- Mints WCOL for the total operation amount
- Splits positions for all questions to create YES + NO tokens
- Distributes NO tokens to buyers (for buy orders)
- Merges NO tokens with YES tokens for sellers (for sell orders)
- Merges all remaining YES tokens to get USDC
- Burns all WCOL to maintain self-financing

**Self-Financing Invariant:**
All WCOL minted must be burned by the end of the operation.

---

### Function: `_collectBuyerUSDC`

**Functionality:**
Collects USDC from all buyers and wraps it to WCOL.

**Why Required:**
Cross-matching requires USDC to be converted to WCOL (the collateral token used in CTF).

**Inputs:**

- `parsedOrders` (Parsed[]): Array of parsed order data
- `isShort` (bool): Whether this is for SHORT orders (affects which USDC amount to collect)

**Outputs:**
None (internal function)

**Expected Behavior:**

- Transfers USDC from buyers (makers of BUY orders) to adapter
- Wraps USDC to WCOL for use in CTF operations

---

### Function: `_parseOrder`

**Functionality:**
Parses an order intent into a structured `Parsed` object containing all relevant information for cross-matching operations.

**Why Required:**
Normalizes order data and extracts key information in a consistent format. Validates token ID matches expected position ID.

**Inputs:**

- `order` (ICTFExchange.OrderIntent): The order intent to parse
- `fillAmount` (uint256): The fill amount for the order

**Outputs:**

- `Parsed`: Struct containing:
  - `maker` (address): Order maker address
  - `side` (uint8): BUY (0) or SELL (1)
  - `tokenId` (uint256): Position token ID
  - `priceQ6` (uint256): Price in 6-decimal fixed point
  - `payAmount` (uint256): USDC amount to pay (for buy orders)
  - `counterPayAmount` (uint256): USDC amount to return (for sell orders)
  - `questionId` (bytes32): Question identifier
  - `feeRateBps` (uint256): Fee rate in basis points

**Validation:**

- Reverts if token ID does not match expected position ID for the question

---

### Function: `_distributeYesTokens`

**Functionality:**
Distributes YES tokens to buyers after cross-matching operations. Collects fees before distribution.

**Why Required:**
Ensures buyers receive their YES tokens and handles fee collection for the protocol.

**Inputs:**

- `parsedOrders` (Parsed[]): Array of parsed order data
- `fillAmount` (uint256): The fill amount for all orders

**Outputs:**
None (internal function)

**Expected Behavior:**

- For BUY orders, calculates fee amount based on fee rate
- Transfers fee in YES tokens to NegRiskAdapter vault
- Transfers remaining YES tokens to buyer

---

### Function: `_distributeNoTokens`

**Functionality:**
Distributes NO tokens to buyers in SHORT cross-matching scenarios. Collects fees before distribution.

**Why Required:**
Handles NO token distribution for SHORT buy orders where users buy NO tokens.

**Inputs:**

- `order` (Parsed): Parsed order data
- `fillAmount` (uint256): The fill amount for the order

**Outputs:**
None (internal function)

**Expected Behavior:**

- Calculates fee amount based on fee rate
- Transfers fee in NO tokens to NegRiskAdapter vault
- Transfers remaining NO tokens to buyer

---

### Function: `_mergeNoTokens`

**Functionality:**
Merges NO tokens with YES tokens to get USDC for sellers in SHORT cross-matching scenarios. Collects fees and distributes USDC to sellers.

**Why Required:**
When users sell NO tokens in SHORT orders, they need to receive USDC. This unlocks the USDC collateral by merging tokens.

**Inputs:**

- `order` (Parsed): Parsed order data
- `fillAmount` (uint256): The fill amount for the order

**Outputs:**
None (internal function)

**Expected Behavior:**

- Transfers YES tokens from seller to adapter
- Merges NO tokens (already in adapter) with YES tokens to get USDC
- Calculates fee amount
- Unwraps WCOL to USDC for fee collection (to vault)
- Unwraps remaining WCOL to USDC for seller

---

### Function: `_handleSellOrders`

**Functionality:**
Processes all sell orders in LONG cross-matching scenarios.

**Why Required:**
Centralizes the handling of sell orders in LONG cross-matching and tracks total USDC needed for vault operations.

**Inputs:**

- `parsedOrders` (Parsed[]): Array of parsed order data
- `fillAmount` (uint256): The fill amount for all orders

**Outputs:**

- `uint256`: Total USDC amount that needs to be returned to the vault

**Expected Behavior:**

- Processes each SELL order via `_processSellOrder`
- Accumulates total vault USDC amount
- Returns total for WCOL burning calculation

---

### Function: `_processSellOrder`

**Functionality:**
Processes a single sell order in LONG cross-matching. Merges user's NO tokens with generated YES tokens to unlock USDC, then distributes it to the seller after fee collection.

**Why Required:**
Sell orders require merging NO tokens with YES tokens to unlock the USDC collateral.

**Inputs:**

- `order` (Parsed): Parsed order data (must be a SELL order)
- `fillAmount` (uint256): The fill amount for the order

**Outputs:**

- `uint256`: The pay amount for this order (for vault accounting)

**Expected Behavior:**

- Validates order is a SELL order
- Transfers NO tokens from user to adapter
- Merges NO tokens with YES tokens to get USDC
- Calculates fee amount
- Unwraps WCOL to USDC for fee collection (to vault)
- Unwraps remaining WCOL to USDC for seller

---

### Function: `_getQuestionIndexFromPositionId`

**Functionality:**
Maps a position ID to its corresponding question index within a market.

**Why Required:**
Enables operations like pivot selection and position conversion by determining which question a position belongs to.

**Inputs:**

- `positionId` (uint256): The position token ID to map
- `marketId` (bytes32): The market ID for context

**Outputs:**

- `uint8`: The question index (0-based) within the market

**Expected Behavior:**

- Iterates through all questions in the market
- Checks if position ID matches YES or NO position for each question
- Returns matching question index
- Reverts with `UnsupportedToken` if no match found

---

### Function: `_refundLeftoverTokens`

**Functionality:**
Refunds any leftover tokens (WCOL or CTF tokens) that were pulled from the taker but not used in the cross-matching operation.

**Why Required:**
The CTF exchange may pull tokens from the taker before validation. Unused tokens must be refunded to prevent token loss.

**Inputs:**

- `takerOrder` (ICTFExchange.OrderIntent): The taker's order intent

**Outputs:**
None (internal function)

**Expected Behavior:**

- Determines which asset ID to check based on order side
- Gets balance of that asset in the adapter
- Unwraps WCOL or transfers CTF tokens back to taker

---

### Function: `_mergePositions`

**Functionality:**
Wrapper for merging conditional token positions using the CTF contract.

**Why Required:**
Provides a clean interface for merging positions with correct parameters (WCOL collateral, partition).

**Inputs:**

- `_conditionId` (bytes32): The condition ID to merge positions for
- `_amount` (uint256): The amount of tokens to merge

**Outputs:**
None (internal function)

**Expected Behavior:**
Calls `ctf.mergePositions` with WCOL as collateral and the partition helper

---

### Function: `_splitPosition`

**Functionality:**
Wrapper for splitting conditional token positions using the CTF contract.

**Why Required:**
Provides a clean interface for splitting positions with correct parameters (WCOL collateral, partition).

**Inputs:**

- `_conditionId` (bytes32): The condition ID to split positions for
- `_amount` (uint256): The amount of tokens to split

**Outputs:**
None (internal function)

**Expected Behavior:**
Calls `ctf.splitPosition` with WCOL as collateral and the partition helper

---

## Validation Functions

### Function: `validateAllUnresolvedQuestionsPresentLength`

**Functionality:**
Validates that all unresolved questions in a market are represented in the maker orders array.

**Why Required:**
Cross-matching requires all unresolved questions to be present in orders to ensure proper token creation and distribution.

**Inputs:**

- `marketId` (bytes32): The market identifier
- `makerOrders` (ICTFExchange.OrderIntent[]): Array of maker orders

**Outputs:**
None (internal view function)

**Validation:**

- Reverts with `MissingUnresolvedQuestion` if `makerOrders.length + 1 != unresolvedQuestionCount`

---

### Function: `_isQuestionUnresolved`

**Functionality:**
Checks if a question is currently unresolved.

**Why Required:**
Cross-matching should only process orders for unresolved questions.

**Inputs:**

- `questionId` (bytes32): The question ID to check

**Outputs:**

- `bool`: True if the question is unresolved, false if resolved

**Expected Behavior:**

- Returns true if question has not been reported
- Returns true if reported but delay period has not passed
- Returns true if reported and delay passed but condition not resolved (payoutDenominator == 0)
- Returns false otherwise

---

## Modifiers

### Modifier: `allUnresolvedQuestionsPresent`

**Functionality:**
Ensures all unresolved questions in a market are present in the maker orders before executing cross-matching.

**Why Required:**
Prevents incomplete cross-matches that could lead to incorrect token distributions.

**Usage:**
Applied to `crossMatchLongOrders` and `crossMatchShortOrders` functions

---

## Key Design Principles

1. **Self-Financing**: All WCOL minted during operations must be burned by the end, ensuring no net token creation
2. **Price Validation**: Combined prices of all orders must be greater than or equal to 1, ensuring balanced cross-matching
3. **Complete Coverage**: All unresolved questions must be present in orders for cross-matching to work
4. **Fee Collection**: Fees collected in appropriate token type (YES tokens for buy orders, USDC for sell orders)
5. **Pivot-Based Conversion**: Uses one question as a pivot to create initial tokens, then converts to other questions
6. **Reentrancy Protection**: All public/external functions use `nonReentrant` modifier

---

## Critical Invariants

1. **WCOL Balance**: After any cross-matching operation, the adapter's WCOL balance should return to zero (all minted WCOL must be burned)
2. **Price Sum**: For all orders in a cross-match, `sum(prices) >= 1` (in 6-decimal fixed point)
3. **Question Coverage**: For a market with N unresolved questions, exactly N orders must be provided (one per question)
4. **Token Conservation**: All tokens created must be distributed or burned (no tokens left in adapter after operation)
5. **Fee Accounting**: Fees must be correctly calculated and transferred to the NegRiskAdapter vault

---

## Order Flow Scenarios

### Scenario 1: All Buy Orders (LONG)

- 4 users want to buy Yes1, Yes2, Yes3, Yes4
- Collect USDC from all buyers
- Split pivot position to create tokens
- Convert NO tokens to YES tokens for other questions
- Distribute YES tokens to buyers

### Scenario 2: Mixed Buy/Sell Orders (LONG)

- Users buying Yes1/Yes3, selling No2/No4
- Collect USDC from buyers and NO tokens from sellers
- Split pivot position to create tokens
- Convert and distribute YES tokens to buyers
- Merge NO tokens with YES tokens for sellers
- Return USDC to sellers
- Burn excess WCOL

### Scenario 3: SHORT Orders

- Users buying NO tokens or selling YES tokens
- Collect USDC from buyers
- Split all positions to create YES + NO tokens
- Distribute NO tokens to buyers
- Merge NO tokens with YES tokens for sellers
- Merge remaining YES tokens to get USDC
- Return USDC to sellers
- Burn all WCOL
