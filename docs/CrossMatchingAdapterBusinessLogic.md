# CrossMatchingAdapter Business Logic Documentation

## Overview

The `CrossMatchingAdapter` is a smart contract that enables cross-matching of multiple orders across different questions within a NegRisk market. It allows users to trade conditional tokens (YES/NO tokens) across multiple questions simultaneously, creating a self-financing mechanism that balances token creation and distribution.

### Key Concepts

- **Cross-Matching**: Matching multiple orders across different questions in a single transaction
- **Self-Financing**: The adapter ensures that all WCOL minted is eventually burned, maintaining balance
- **Pivot Question**: One question used as the starting point for splitting positions to create YES/NO tokens
- **WCOL (Wrapped Collateral)**: Wrapped USDC used as collateral in the Conditional Tokens Framework (CTF)

### Order Types

- **LONG Intent**:
  - BUY = Buy YES tokens
  - SELL = Sell NO tokens
- **SHORT Intent**:
  - BUY = Buy NO tokens
  - SELL = Sell YES tokens

---

## Constructor

### Function: `constructor`

**Functionality:**
Initializes the CrossMatchingAdapter contract with all required dependencies and sets up necessary approvals.

**Why Required:**
The constructor establishes the contract's immutable dependencies and configures token approvals needed for cross-matching operations. Without proper initialization, the adapter cannot interact with the CTF exchange, NegRisk adapter, or handle token transfers.

**Inputs:**

- `negOperator_` (NegRiskOperator): The NegRisk operator contract
- `ctfExchange_` (ICTFExchange): CTF exchange contract address
- `revNeg_` (IRevNegRiskAdapter): Reverse NegRisk adapter contract

**Outputs:**
None (constructor)

**Key Operations:**

1. Stores immutable references to dependencies
2. Approves CTF contract for unlimited WCOL transfers
3. Approves NegRiskAdapter for unlimited USDC transfers
4. Sets approval for all tokens to revNeg and neg adapters

---

## Public Functions

### Function: `hybridMatchOrders`

**Functionality:**
Main entry point that processes a mix of single orders (handled by the CTF exchange) and cross-match orders (handled internally). Routes orders to the appropriate matching mechanism based on their type.

**Why Required:**
This function provides flexibility to handle both simple single-order matches and complex cross-matching scenarios in a single transaction. It optimizes gas usage by batching single orders together while handling complex cross-matches separately.

**Inputs:**

- `marketId` (bytes32): The market identifier
- `takerOrder` (ICTFExchange.OrderIntent): The taker's order intent
- `makerOrders` (MakerOrder[]): Array of maker orders with their types (SINGLE or CROSS_MATCH)
- `takerFillAmounts` (uint256[]): Array of fill amounts for each maker order pair
- `singleOrderCount` (uint8): Number of single orders to batch process

**Outputs:**
None (external function)

**Key Operations:**

1. Separates single orders from cross-match orders
2. For cross-match orders, routes to `crossMatchLongOrders` or `crossMatchShortOrders` based on intent
3. Batches all single orders together and calls `ctfExchange.matchOrders`

---

### Function: `crossMatchLongOrders`

**Functionality:**
Handles cross-matching for LONG intent orders across multiple questions. Supports scenarios where some questions may be resolved while others are unresolved. Uses the taker's question as the pivot for splitting positions.

**Why Required:**
LONG intent orders represent the primary use case where users buy YES tokens or sell NO tokens. This function enables efficient cross-matching across multiple questions, allowing users to trade on multiple outcomes simultaneously. The pivot-based approach ensures the mechanism works even when some questions are resolved.

**Inputs:**

- `marketId` (bytes32): The market identifier
- `takerOrder` (ICTFExchange.OrderIntent): The taker's order intent
- `multiOrderMaker` (ICTFExchange.OrderIntent[]): Array of maker orders for cross-matching
- `takerFillAmount` (uint256): Fill amount for the taker order
- `makerFillAmounts` (uint256[]): Array of fill amounts for each maker order

**Outputs:**
None (public function)

**Key Operations:**

1. Validates all orders using `ctfExchange.performOrderChecks`
2. Parses all orders and validates combined price equals 1
3. Executes cross-matching logic via `_executeLongCrossMatch`
4. Refunds leftover tokens to the taker

**Validation:**

- Ensures all unresolved questions are present in orders via `allUnresolvedQuestionsPresent` modifier
- Validates combined price of all orders equals 1 (required for self-financing)
- Reverts if fill amount is zero

---

### Function: `crossMatchShortOrders`

**Functionality:**
Handles cross-matching for SHORT intent orders across multiple questions. In SHORT orders, users buy NO tokens or sell YES tokens. This function processes the reverse flow compared to LONG orders.

**Why Required:**
SHORT intent orders provide users with the ability to take opposite positions (buying NO instead of YES, selling YES instead of NO). This function enables cross-matching for these reverse scenarios, expanding the trading capabilities of the adapter.

**Inputs:**

- `marketId` (bytes32): The market identifier
- `takerOrder` (ICTFExchange.OrderIntent): The taker's order intent
- `multiOrderMaker` (ICTFExchange.OrderIntent[]): Array of maker orders for cross-matching
- `takerFillAmount` (uint256): Fill amount for the taker order
- `makerFillAmounts` (uint256[]): Array of fill amounts for each maker order

**Outputs:**
None (public function)

**Key Operations:**

1. Validates all orders using `ctfExchange.performOrderChecks`
2. Parses all orders and calculates total sell USDC needed
3. Validates combined price equals 1
4. Executes short cross-matching via `_executeShortCrossMatch`
5. Refunds leftover tokens to the taker

**Validation:**

- Ensures all unresolved questions are present in orders
- Validates combined price of all orders equals 1
- Reverts if fill amount is zero

---

### Function: `getCollateral`

**Functionality:**
Returns the address of the collateral token (WCOL) used by this adapter.

**Why Required:**
This function is required by the `AssetOperations` interface and allows external contracts to query which collateral token the adapter uses for operations.

**Inputs:**
None

**Outputs:**

- `address`: The address of the WrappedCollateral (WCOL) contract

---

### Function: `getCtf`

**Functionality:**
Returns the address of the Conditional Tokens Framework (CTF) contract used by this adapter.

**Why Required:**
This function is required by the `AssetOperations` interface and allows external contracts to query which CTF contract the adapter uses for token operations.

**Inputs:**
None

**Outputs:**

- `address`: The address of the ConditionalTokens contract

---

## Internal Functions

### Function: `_executeLongCrossMatch`

**Functionality:**
Core execution logic for LONG cross-matching. Implements a 5-step process:

1. Collect USDC from buyers and wrap to WCOL
2. Split pivot position to create YES + NO tokens
3. Convert NO tokens to YES tokens for other questions
4. Distribute YES tokens to buyers
5. Handle sell orders and burn excess WCOL

**Why Required:**
This function encapsulates the complex cross-matching logic for LONG orders. It ensures self-financing by properly managing WCOL minting and burning, and handles the token conversion process that enables cross-matching across multiple questions.

**Inputs:**

- `parsedOrders` (Parsed[]): Array of parsed order data
- `marketId` (bytes32): The market identifier
- `totalSellUSDC` (uint256): Total USDC amount needed for sell orders
- `fillAmount` (uint256): The fill amount for all orders

**Outputs:**
None (internal function)

**Process Flow:**

1. Collects USDC from all buyers and wraps to WCOL
2. Mints additional WCOL if needed for sell orders
3. Splits pivot position (taker's question) to create YES + NO tokens
4. Converts NO tokens from pivot to YES tokens for other questions
5. Distributes YES tokens to buyers (with fee collection)
6. Processes sell orders by merging NO tokens with YES tokens
7. Burns excess WCOL to maintain self-financing

---

### Function: `_executeShortCrossMatch`

**Functionality:**
Core execution logic for SHORT cross-matching. Processes orders where users buy NO tokens or sell YES tokens. The flow is reversed compared to LONG orders.

**Why Required:**
SHORT orders require different handling because the token flow is reversed. This function manages the collection of NO tokens, distribution to buyers, and merging of YES tokens for sellers.

**Inputs:**

- `parsedOrders` (Parsed[]): Array of parsed order data
- `marketId` (bytes32): The market identifier
- `totalSellUSDC` (uint256): Total USDC amount needed for sell orders
- `fillAmount` (uint256): The fill amount for all orders

**Outputs:**
None (internal function)

**Process Flow:**

1. Collects USDC from buyers
2. Mints WCOL for the total operation amount
3. Splits positions for all questions to create YES + NO tokens
4. Distributes NO tokens to buyers (for buy orders)
5. Merges NO tokens with YES tokens for sellers (for sell orders)
6. Merges all YES tokens to get USDC
7. Wraps generated USDC to WCOL
8. Burns all WCOL to maintain self-financing

---

### Function: `_collectBuyerUSDC`

**Functionality:**
Collects USDC from all buyers and wraps it to WCOL. This function is called before executing cross-matching operations to ensure sufficient collateral is available.

**Why Required:**
Cross-matching requires USDC to be converted to WCOL (the collateral token used in CTF). This function centralizes the collection and wrapping logic, ensuring all buyer funds are properly prepared for the cross-matching process.

**Inputs:**

- `parsedOrders` (Parsed[]): Array of parsed order data
- `isShort` (bool): Whether this is for SHORT orders (affects which USDC amount to collect)

**Outputs:**
None (internal function)

**Key Operations:**

1. Iterates through all parsed orders
2. For BUY orders, transfers USDC from maker to adapter
3. Wraps USDC to WCOL for use in CTF operations

---

### Function: `_parseOrder`

**Functionality:**
Parses an order intent into a structured `Parsed` object containing all relevant information for cross-matching operations.

**Why Required:**
This function normalizes order data and extracts key information (maker, side, price, amounts, question ID, fees) in a consistent format. It also validates that the token ID matches the expected position ID for the question.

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

**Key Operations:**

1. Calculates pay amounts based on price and fill amount
2. Determines if token is YES or NO based on intent and side
3. Validates token ID matches expected position ID
4. Returns structured parsed data

---

### Function: `_distributeYesTokens`

**Functionality:**
Distributes YES tokens to buyers after cross-matching operations. Calculates and collects fees before distribution.

**Why Required:**
After converting positions and creating YES tokens, this function ensures buyers receive their tokens. It also handles fee collection, which is a critical part of the protocol's revenue model.

**Inputs:**

- `parsedOrders` (Parsed[]): Array of parsed order data
- `fillAmount` (uint256): The fill amount for all orders

**Outputs:**
None (internal function)

**Key Operations:**

1. Iterates through all parsed orders
2. For BUY orders, calculates fee amount
3. Transfers fee in YES tokens to NegRiskAdapter vault
4. Transfers remaining YES tokens to buyer

---

### Function: `_distributeNoTokens`

**Functionality:**
Distributes NO tokens to buyers in SHORT cross-matching scenarios. Calculates and collects fees before distribution.

**Why Required:**
In SHORT orders, users buy NO tokens. This function handles the distribution of NO tokens after they are created via position splitting.

**Inputs:**

- `order` (Parsed): Parsed order data
- `fillAmount` (uint256): The fill amount for the order

**Outputs:**
None (internal function)

**Key Operations:**

1. Calculates fee amount based on fee rate
2. Transfers fee in NO tokens to NegRiskAdapter vault
3. Transfers remaining NO tokens to buyer

---

### Function: `_mergeNoTokens`

**Functionality:**
Merges NO tokens with YES tokens to get USDC for sellers in SHORT cross-matching scenarios. Collects fees and distributes USDC to sellers.

**Why Required:**
When users sell NO tokens in SHORT orders, they need to receive USDC. This function merges the NO tokens with YES tokens to unlock the USDC collateral, then distributes it to sellers after fee collection.

**Inputs:**

- `order` (Parsed): Parsed order data
- `fillAmount` (uint256): The fill amount for the order

**Outputs:**
None (internal function)

**Key Operations:**

1. Transfers YES tokens from seller to adapter
2. Merges NO tokens (already in adapter) with YES tokens to get USDC
3. Calculates fee amount
4. Unwraps WCOL to USDC for fee collection (to vault)
5. Unwraps remaining WCOL to USDC for seller

---

### Function: `_handleSellOrders`

**Functionality:**
Processes all sell orders in LONG cross-matching scenarios. Iterates through parsed orders and processes each sell order individually.

**Why Required:**
This function centralizes the handling of sell orders in LONG cross-matching. It ensures all sell orders are processed consistently and tracks the total USDC needed for vault operations.

**Inputs:**

- `parsedOrders` (Parsed[]): Array of parsed order data
- `fillAmount` (uint256): The fill amount for all orders

**Outputs:**

- `uint256`: Total USDC amount that needs to be returned to the vault

**Key Operations:**

1. Iterates through all parsed orders
2. For SELL orders, calls `_processSellOrder`
3. Accumulates total vault USDC amount
4. Returns total for WCOL burning calculation

---

### Function: `_processSellOrder`

**Functionality:**
Processes a single sell order in LONG cross-matching. Merges user's NO tokens with generated YES tokens to unlock USDC, then distributes it to the seller after fee collection.

**Why Required:**
Sell orders require merging NO tokens with YES tokens to unlock the USDC collateral. This function handles the merging, fee collection, and USDC distribution for individual sell orders.

**Inputs:**

- `order` (Parsed): Parsed order data (must be a SELL order)
- `fillAmount` (uint256): The fill amount for the order

**Outputs:**

- `uint256`: The pay amount for this order (for vault accounting)

**Key Operations:**

1. Validates order is a SELL order
2. Transfers NO tokens from user to adapter
3. Merges NO tokens with YES tokens to get USDC
4. Calculates fee amount
5. Unwraps WCOL to USDC for fee collection (to vault)
6. Unwraps remaining WCOL to USDC for seller

---

### Function: `_getQuestionIndexFromPositionId`

**Functionality:**
Maps a position ID to its corresponding question index within a market. This is used to determine which question a position belongs to.

**Why Required:**
Position IDs are used throughout the CTF, but sometimes we need to know which question index they correspond to within a market. This function provides that mapping, enabling operations like pivot selection and position conversion.

**Inputs:**

- `positionId` (uint256): The position token ID to map
- `marketId` (bytes32): The market ID for context

**Outputs:**

- `uint8`: The question index (0-based) within the market

**Key Operations:**

1. Gets total question count for the market
2. Iterates through all questions
3. Checks if position ID matches YES or NO position for each question
4. Returns the matching question index
5. Reverts if no match is found

---

### Function: `_refundLeftoverTokens`

**Functionality:**
Refunds any leftover tokens (WCOL or CTF tokens) that were pulled from the taker but not used in the cross-matching operation.

**Why Required:**
The CTF exchange may pull tokens from the taker before validation. If not all tokens are used, this function ensures they are refunded to maintain fairness and prevent token loss.

**Inputs:**

- `takerOrder` (ICTFExchange.OrderIntent): The taker's order intent

**Outputs:**
None (internal function)

**Key Operations:**

1. Determines which asset ID to check based on order side
2. Gets balance of that asset in the adapter
3. Unwraps WCOL or transfers CTF tokens back to taker

---

### Function: `_mergePositions`

**Functionality:**
Internal wrapper for merging conditional token positions using the CTF contract.

**Why Required:**
This function provides a clean interface for merging positions while using the correct parameters (WCOL collateral, partition, etc.). It abstracts away the complexity of the CTF merge operation.

**Inputs:**

- `_conditionId` (bytes32): The condition ID to merge positions for
- `_amount` (uint256): The amount of tokens to merge

**Outputs:**
None (internal function)

**Key Operations:**
Calls `ctf.mergePositions` with WCOL as collateral and the partition helper

---

### Function: `_splitPosition`

**Functionality:**
Internal wrapper for splitting conditional token positions using the CTF contract.

**Why Required:**
This function provides a clean interface for splitting positions while using the correct parameters (WCOL collateral, partition, etc.). It abstracts away the complexity of the CTF split operation.

**Inputs:**

- `_conditionId` (bytes32): The condition ID to split positions for
- `_amount` (uint256): The amount of tokens to split

**Outputs:**
None (internal function)

**Key Operations:**
Calls `ctf.splitPosition` with WCOL as collateral and the partition helper

---

## Validation Functions

### Function: `validateAllUnresolvedQuestionsPresentLength`

**Functionality:**
Validates that all unresolved questions in a market are represented in the maker orders array. This ensures complete coverage for cross-matching operations.

**Why Required:**
Cross-matching requires all unresolved questions to be present in the orders to ensure proper token creation and distribution. Missing questions would cause the mechanism to fail or create incorrect positions.

**Inputs:**

- `marketId` (bytes32): The market identifier
- `makerOrders` (ICTFExchange.OrderIntent[]): Array of maker orders

**Outputs:**
None (internal view function)

**Key Operations:**

1. Gets total question count for the market
2. Counts unresolved questions
3. Validates that makerOrders.length + 1 equals unresolvedQuestionCount
4. Reverts with `MissingUnresolvedQuestion` if validation fails

---

### Function: `_isQuestionUnresolved`

**Functionality:**
Checks if a question is currently unresolved by checking if it has been reported and if the delay period has passed.

**Why Required:**
Cross-matching should only process orders for unresolved questions. Resolved questions have different payout mechanisms and should not be included in cross-matching operations.

**Inputs:**

- `questionId` (bytes32): The question ID to check

**Outputs:**

- `bool`: True if the question is unresolved, false if resolved

**Key Operations:**

1. Checks if question has been reported
2. If reported, checks if delay period has passed
3. Checks if condition has been resolved (payoutDenominator > 0)
4. Returns true if unresolved, false if resolved

---

## Modifiers

### Modifier: `allUnresolvedQuestionsPresent`

**Functionality:**
Modifier that ensures all unresolved questions in a market are present in the maker orders before executing cross-matching.

**Why Required:**
This modifier provides a security check to ensure cross-matching operations are only executed when all required questions are present. It prevents incomplete cross-matches that could lead to incorrect token distributions.

**Usage:**
Applied to `crossMatchLongOrders` and `crossMatchShortOrders` functions

---

## Error Definitions

- `UnsupportedToken()`: Order token ID is not recognized as YES or NO
- `SideNotSupported()`: Only BUY-YES and SELL-NO are supported in this adapter
- `PriceOutOfRange()`: Price must be ≤ 1
- `BootstrapShortfall()`: Not enough buyer USDC to bootstrap pivot split
- `SupplyInvariant()`: Insufficient YES supply computed
- `NotSelfFinancing()`: Net WCOL minted ≠ 0 after operations
- `InvalidFillAmount()`: Fill amount is invalid (zero or exceeds order quantity)
- `InvalidCombinedPrice()`: Combined price of all orders must equal total shares
- `InsufficientUSDCBalance()`: Insufficient USDC balance for WCOL minting
- `InvalidUSDCBalance()`: Invalid USDC balance for WCOL minting
- `MissingUnresolvedQuestion()`: Some unresolved questions are missing from orders

---

## Key Design Principles

1. **Self-Financing**: All WCOL minted during operations must be burned by the end, ensuring no net token creation
2. **Price Validation**: Combined prices of all orders must equal 1, ensuring balanced cross-matching
3. **Complete Coverage**: All unresolved questions must be present in orders for cross-matching to work
4. **Fee Collection**: Fees are collected in the appropriate token type (YES tokens for buy orders, USDC for sell orders)
5. **Pivot-Based Conversion**: Uses one question as a pivot to create initial tokens, then converts to other questions
6. **Reentrancy Protection**: All public/external functions use `nonReentrant` modifier

---

## Order Flow Examples

### Example 1: All Buy Orders (LONG)

1. 4 users want to buy Yes1, Yes2, Yes3, Yes4
2. Collect USDC from all 4 buyers
3. Wrap USDC to WCOL
4. Split pivot position (Yes1) to get Yes1 + No1
5. Convert No1 to Yes2 + Yes3 + Yes4
6. Distribute Yes tokens to respective buyers

### Example 2: Mixed Buy/Sell Orders (LONG)

1. Users buying Yes1/Yes3, selling No2/No4
2. Collect USDC from buyers
3. Collect NO tokens from sellers
4. Split pivot position to create tokens
5. Convert and distribute YES tokens to buyers
6. Merge NO tokens with YES tokens for sellers
7. Return USDC to sellers
8. Burn excess WCOL

### Example 3: SHORT Orders

1. Users buying NO tokens or selling YES tokens
2. Collect USDC from buyers
3. Split all positions to create YES + NO tokens
4. Distribute NO tokens to buyers
5. Merge NO tokens with YES tokens for sellers
6. Merge remaining YES tokens to get USDC
7. Return USDC to sellers
8. Burn all WCOL
