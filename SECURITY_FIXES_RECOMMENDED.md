# Recommended Security Fixes
**Actionable Code Changes for Neg-Risk CTF Adapter**

---

## Priority 0 - Critical Fixes (Implement Before Mainnet)

### Fix 1: Secure NO Token Burn Address

**File:** `src/NegRiskAdapter.sol`

**Current Code:**
```solidity
address public constant NO_TOKEN_BURN_ADDRESS = address(bytes20(bytes32(keccak256("NO_TOKEN_BURN_ADDRESS"))));
```

**Recommended Fix:**
```solidity
// Use address(1) which is provably uncontrollable
// Address 1 has no known private key and is commonly used as a burn address
address public constant NO_TOKEN_BURN_ADDRESS = address(1);

// Alternative: Use well-known burn address
// address public constant NO_TOKEN_BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
```

**Testing Required:**
```solidity
// Verify CTF accepts transfers to address(1)
function testBurnAddressAcceptance() public {
    uint256[] memory ids = new uint256[](1);
    uint256[] memory amounts = new uint256[](1);
    ids[0] = testPositionId;
    amounts[0] = 100;
    
    // Should not revert
    ctf.safeBatchTransferFrom(
        address(this),
        address(1),
        ids,
        amounts,
        ""
    );
    
    // Verify balance increased
    assertEq(ctf.balanceOf(address(1), testPositionId), 100);
}
```

---

### Fix 2: Add Reentrancy Protection

**File:** `src/NegRiskAdapter.sol`

**Add Dependency:**
```solidity
import {ReentrancyGuard} from "lib/solmate/src/utils/ReentrancyGuard.sol";
```

**Update Contract:**
```solidity
contract NegRiskAdapter is 
    ERC1155TokenReceiver, 
    MarketStateManager, 
    INegRiskAdapterEE, 
    Auth,
    ReentrancyGuard  // Add this
{
    // ... existing code ...
    
    function splitPosition(bytes32 _conditionId, uint256 _amount) 
        public 
        nonReentrant  // Add modifier
    {
        // ... existing implementation ...
    }
    
    function mergePositions(bytes32 _conditionId, uint256 _amount) 
        public 
        nonReentrant  // Add modifier
    {
        // ... existing implementation ...
    }
    
    function convertPositions(
        bytes32 _marketId, 
        uint256 _indexSet, 
        uint256 _amount
    ) external nonReentrant  // Add modifier
    {
        // ... existing implementation ...
    }
    
    function redeemPositions(bytes32 _conditionId, uint256[] calldata _amounts) 
        public 
        nonReentrant  // Add modifier
    {
        // ... existing implementation ...
    }
}
```

---

### Fix 3: Add Oracle Initialization Security

**File:** `src/NegRiskOperator.sol`

**Current Code:**
```solidity
function setOracle(address _oracle) external onlyAdmin {
    if (oracle != address(0)) revert OracleAlreadyInitialized();
    oracle = _oracle;
}
```

**Recommended Fix:**
```solidity
address public pendingOracle;
uint256 public oracleProposalTime;
uint256 public constant ORACLE_TIMELOCK = 48 hours;

event OracleProposed(address indexed oracle, uint256 proposalTime);
event OracleAccepted(address indexed oracle);

function proposeOracle(address _oracle) external onlyAdmin {
    if (oracle != address(0)) revert OracleAlreadyInitialized();
    if (_oracle == address(0)) revert InvalidOracleAddress();
    
    pendingOracle = _oracle;
    oracleProposalTime = block.timestamp;
    
    emit OracleProposed(_oracle, block.timestamp);
}

function acceptOracle() external {
    if (msg.sender != pendingOracle) revert OnlyPendingOracle();
    if (block.timestamp < oracleProposalTime + ORACLE_TIMELOCK) {
        revert TimelockNotExpired();
    }
    if (oracle != address(0)) revert OracleAlreadyInitialized();
    
    oracle = pendingOracle;
    pendingOracle = address(0);
    
    emit OracleAccepted(oracle);
}

function cancelOracleProposal() external onlyAdmin {
    pendingOracle = address(0);
    oracleProposalTime = 0;
}
```

**Update Interface:**
```solidity
interface INegRiskOperatorEE is IAuthEE {
    // ... existing errors ...
    error InvalidOracleAddress();
    error OnlyPendingOracle();
    error TimelockNotExpired();
    
    // ... existing events ...
}
```

---

## Priority 1 - High Severity Fixes

### Fix 4: Add Collateral Accounting to WrappedCollateral

**File:** `src/WrappedCollateral.sol`

**Add State Variables:**
```solidity
/// @notice Tracks virtual collateral minted without backing
uint256 public virtualCollateral;

/// @notice Tracks total collateral that should be in contract
function expectedCollateral() public view returns (uint256) {
    return totalSupply - virtualCollateral;
}

/// @notice Checks if contract has sufficient collateral
function checkInvariant() external view returns (bool) {
    uint256 actualCollateral = ERC20(underlying).balanceOf(address(this));
    return actualCollateral >= expectedCollateral();
}
```

**Update mint() function:**
```solidity
function mint(uint256 _amount) external onlyOwner {
    virtualCollateral += _amount;
    _mint(msg.sender, _amount);
    
    emit VirtualCollateralMinted(_amount, virtualCollateral);
}
```

**Update release() function:**
```solidity
function release(address _to, uint256 _amount) external onlyOwner {
    if (virtualCollateral < _amount) revert InsufficientVirtualCollateral();
    
    virtualCollateral -= _amount;
    ERC20(underlying).safeTransfer(_to, _amount);
    
    emit VirtualCollateralReleased(_amount, virtualCollateral);
}
```

**Update unwrap() function:**
```solidity
function unwrap(address _to, uint256 _amount) external {
    uint256 actualBalance = ERC20(underlying).balanceOf(address(this));
    uint256 requiredBalance = expectedCollateral();
    
    if (actualBalance < requiredBalance) revert InsufficientActualCollateral();
    
    _burn(msg.sender, _amount);
    ERC20(underlying).safeTransfer(_to, _amount);
}
```

**Add Events:**
```solidity
interface IWrappedCollateralEE {
    error OnlyOwner();
    error InsufficientVirtualCollateral();
    error InsufficientActualCollateral();
    
    event VirtualCollateralMinted(uint256 amount, uint256 totalVirtual);
    event VirtualCollateralReleased(uint256 amount, uint256 totalVirtual);
}
```

---

### Fix 5: Add Approval Check to mergePositionsOperator

**File:** `src/NegRiskAdapter.sol`

**Current Code:**
```solidity
function mergePositionsOperator(bytes32 _conditionId, uint256 _amount, address _user) 
    public 
    onlyOperator 
{
    uint256[] memory positionIds = Helpers.positionIds(address(wcol), _conditionId);
    
    ctf.safeBatchTransferFrom(_user, address(this), positionIds, Helpers.values(2, _amount), "");
    // ... rest
}
```

**Recommended Fix:**
```solidity
function mergePositionsOperator(bytes32 _conditionId, uint256 _amount, address _user) 
    public 
    onlyOperator 
{
    // Verify approval
    bool approvedToAdapter = ctf.isApprovedForAll(_user, address(this));
    bool approvedToOperator = ctf.isApprovedForAll(_user, msg.sender);
    
    if (!approvedToAdapter && !approvedToOperator) {
        revert NotApprovedForAll();
    }
    
    uint256[] memory positionIds = Helpers.positionIds(address(wcol), _conditionId);
    
    ctf.safeBatchTransferFrom(_user, address(this), positionIds, Helpers.values(2, _amount), "");
    ctf.mergePositions(address(wcol), bytes32(0), _conditionId, Helpers.partition(), _amount);
    wcol.unwrap(_user, _amount);
    
    emit PositionsMerge(_user, _conditionId, _amount);
}
```

---

### Fix 6: Add Emergency Resolution Timelock

**File:** `src/NegRiskOperator.sol`

**Current Code:**
```solidity
function emergencyResolveQuestion(bytes32 _questionId, bool _result) 
    external 
    onlyAdmin 
{
    uint256 flaggedAt_ = flaggedAt[_questionId];
    
    if (flaggedAt_ == 0) revert OnlyFlagged();
    
    nrAdapter.reportOutcome(_questionId, _result);
    emit QuestionEmergencyResolved(_questionId, _result);
}
```

**Recommended Fix:**
```solidity
uint256 public constant EMERGENCY_RESOLUTION_DELAY = 7 days;

function emergencyResolveQuestion(bytes32 _questionId, bool _result) 
    external 
    onlyAdmin 
{
    uint256 flaggedAt_ = flaggedAt[_questionId];
    
    if (flaggedAt_ == 0) revert OnlyFlagged();
    if (block.timestamp < flaggedAt_ + EMERGENCY_RESOLUTION_DELAY) {
        revert EmergencyResolutionDelayNotPassed();
    }
    
    nrAdapter.reportOutcome(_questionId, _result);
    emit QuestionEmergencyResolved(_questionId, _result);
}
```

**Update Interface:**
```solidity
interface INegRiskOperatorEE is IAuthEE {
    // ... existing errors ...
    error EmergencyResolutionDelayNotPassed();
    // ... rest
}
```

---

## Priority 2 - Medium Severity Fixes

### Fix 7: Add Question Count Overflow Protection

**File:** `src/types/MarketData.sol`

**Current Code:**
```solidity
function incrementQuestionCount(MarketData _data) internal pure returns (MarketData) {
    bytes32 data = MarketData.unwrap(_data);
    data = bytes32(uint256(data) + INCREMENT);
    return MarketData.wrap(data);
}
```

**Recommended Fix:**
```solidity
error MaxQuestionsReached();

function incrementQuestionCount(MarketData _data) internal pure returns (MarketData) {
    uint256 currentCount = questionCount(_data);
    if (currentCount >= 255) revert MaxQuestionsReached();
    
    bytes32 data = MarketData.unwrap(_data);
    data = bytes32(uint256(data) + INCREMENT);
    return MarketData.wrap(data);
}
```

---

### Fix 8: Add Maximum Questions Limit Per Market

**File:** `src/modules/MarketDataManager.sol`

**Add Constant:**
```solidity
uint256 public constant MAX_QUESTIONS_PER_MARKET = 64;  // Reasonable gas limit

interface IMarketStateManagerEE {
    // ... existing errors ...
    error TooManyQuestions();
    // ... rest
}
```

**Update _prepareQuestion:**
```solidity
function _prepareQuestion(bytes32 _marketId) 
    internal 
    returns (bytes32 questionId, uint256 index) 
{
    MarketData md = marketData[_marketId];
    address oracle = marketData[_marketId].oracle();
    
    if (oracle == address(0)) revert MarketNotPrepared();
    if (oracle != msg.sender) revert OnlyOracle();
    
    index = md.questionCount();
    
    // Add gas safety check
    if (index >= MAX_QUESTIONS_PER_MARKET) revert TooManyQuestions();
    
    questionId = NegRiskIdLib.getQuestionId(_marketId, uint8(index));
    marketData[_marketId] = md.incrementQuestionCount();
}
```

---

### Fix 9: Add Maximum Fee Limit

**File:** `src/modules/MarketDataManager.sol`

**Current Code:**
```solidity
if (_feeBips > 10_000) revert FeeBipsOutOfBounds();
```

**Recommended Fix:**
```solidity
uint256 public constant MAX_FEE_BIPS = 1000;  // 10% maximum

function _prepareMarket(uint256 _feeBips, bytes memory _metadata) 
    internal 
    returns (bytes32 marketId) 
{
    address oracle = msg.sender;
    marketId = NegRiskIdLib.getMarketId(oracle, _feeBips, _metadata);
    MarketData md = marketData[marketId];
    
    if (md.oracle() != address(0)) revert MarketAlreadyPrepared();
    if (_feeBips > MAX_FEE_BIPS) revert FeeBipsOutOfBounds();
    
    marketData[marketId] = MarketDataLib.initialize(oracle, _feeBips);
}
```

---

### Fix 10: Add Vault Withdrawal Limits

**File:** `src/Vault.sol`

**Add State Variables:**
```solidity
mapping(address => uint256) public lastWithdrawal;
mapping(address => uint256) public dailyWithdrawn;
uint256 public dailyLimit;
bool public limitsEnabled;

event DailyLimitSet(uint256 newLimit);
event LimitsToggled(bool enabled);
```

**Add Admin Functions:**
```solidity
function setDailyLimit(uint256 _limit) external onlyAdmin {
    dailyLimit = _limit;
    emit DailyLimitSet(_limit);
}

function toggleLimits(bool _enabled) external onlyAdmin {
    limitsEnabled = _enabled;
    emit LimitsToggled(_enabled);
}
```

**Update transferERC20:**
```solidity
function transferERC20(address _erc20, address _to, uint256 _amount) 
    external 
    onlyAdmin 
{
    if (limitsEnabled && dailyLimit > 0) {
        if (block.timestamp >= lastWithdrawal[_erc20] + 1 days) {
            // Reset daily counter
            dailyWithdrawn[_erc20] = _amount;
            lastWithdrawal[_erc20] = block.timestamp;
        } else {
            // Check daily limit
            require(
                dailyWithdrawn[_erc20] + _amount <= dailyLimit,
                "Daily limit exceeded"
            );
            dailyWithdrawn[_erc20] += _amount;
        }
    }
    
    ERC20(_erc20).safeTransfer(_to, _amount);
}
```

---

## Priority 3 - Low Severity Fixes

### Fix 11: Add Circuit Breaker for convertPositions

**File:** `src/NegRiskAdapter.sol`

**Add State Variable:**
```solidity
bool public conversionsPaused;

event ConversionsPaused();
event ConversionsUnpaused();
```

**Add Admin Functions:**
```solidity
function pauseConversions() external onlyAdmin {
    conversionsPaused = true;
    emit ConversionsPaused();
}

function unpauseConversions() external onlyAdmin {
    conversionsPaused = false;
    emit ConversionsUnpaused();
}
```

**Update convertPositions:**
```solidity
function convertPositions(bytes32 _marketId, uint256 _indexSet, uint256 _amount) 
    external 
    nonReentrant 
{
    if (conversionsPaused) revert ConversionsPaused();
    
    // ... rest of implementation
}
```

**Update Interface:**
```solidity
interface INegRiskAdapterEE is IMarketStateManagerEE, IAuthEE {
    // ... existing errors ...
    error ConversionsPaused();
    // ... rest
}
```

---

### Fix 12: Add Events for Critical State Changes

**File:** `src/WrappedCollateral.sol`

**Add Events:**
```solidity
interface IWrappedCollateralEE {
    error OnlyOwner();
    
    event OwnerAdded(address indexed by, address indexed newOwner);
    event OwnerRenounced(address indexed owner);
    event Wrapped(address indexed to, uint256 amount);
    event Unwrapped(address indexed to, uint256 amount);
    event CollateralReleased(address indexed to, uint256 amount);
}
```

**Update Functions:**
```solidity
function wrap(address _to, uint256 _amount) external onlyOwner {
    ERC20(underlying).safeTransferFrom(msg.sender, address(this), _amount);
    _mint(_to, _amount);
    emit Wrapped(_to, _amount);
}

function unwrap(address _to, uint256 _amount) external {
    _burn(msg.sender, _amount);
    ERC20(underlying).safeTransfer(_to, _amount);
    emit Unwrapped(_to, _amount);
}

function release(address _to, uint256 _amount) external onlyOwner {
    ERC20(underlying).safeTransfer(_to, _amount);
    emit CollateralReleased(_to, _amount);
}

function addOwner(address _owner) external onlyOwner {
    owners[_owner] = true;
    emit OwnerAdded(msg.sender, _owner);
}

function renounceOwnerRole() external onlyOwner {
    owners[msg.sender] = false;
    emit OwnerRenounced(msg.sender);
}
```

---

### Fix 13: Standardize Solidity Version

**All Files**

**Update all pragma statements to:**
```solidity
pragma solidity 0.8.19;
```

**Files to update:**
- `src/NegRiskCtfExchange.sol` (currently 0.8.15)
- `src/WrappedCollateral.sol` (currently ^0.8.15)
- `src/modules/MarketDataManager.sol` (currently ^0.8.15)
- `src/modules/Auth.sol` (currently ^0.8.15)
- `src/types/MarketData.sol` (currently ^0.8.15)

---

### Fix 14: Add Documentation Constants

**File:** `src/NegRiskAdapter.sol`

**Replace magic numbers:**
```solidity
// Outcome indices for binary markets
uint256 private constant YES_OUTCOME = 1;  // 0b01
uint256 private constant NO_OUTCOME = 2;   // 0b10
uint256 private constant OUTCOME_SLOTS = 2;

// Update usage throughout contract
function getPositionId(bytes32 _questionId, bool _outcome) public view returns (uint256) {
    bytes32 collectionId = CTHelpers.getCollectionId(
        bytes32(0),
        getConditionId(_questionId),
        _outcome ? YES_OUTCOME : NO_OUTCOME
    );
    
    uint256 positionId = CTHelpers.getPositionId(address(wcol), collectionId);
    return positionId;
}

function getConditionId(bytes32 _questionId) public view returns (bytes32) {
    return CTHelpers.getConditionId(
        address(this),
        _questionId,
        OUTCOME_SLOTS
    );
}
```

---

## Implementation Checklist

### Before Deployment

- [ ] Implement all Priority 0 fixes (CRITICAL)
- [ ] Implement all Priority 1 fixes (HIGH)
- [ ] Run comprehensive test suite
- [ ] Perform gas analysis on worst-case scenarios
- [ ] Document all security assumptions
- [ ] Get external audit

### Testing Requirements

- [ ] Test burn address cannot be controlled
- [ ] Test reentrancy protection works
- [ ] Test oracle timelock works correctly
- [ ] Test collateral accounting remains accurate
- [ ] Test overflow protection triggers correctly
- [ ] Test circuit breakers function properly
- [ ] Test withdrawal limits enforce correctly
- [ ] Fuzz test with random inputs
- [ ] Invariant testing for all guarantees

### Documentation Requirements

- [ ] Update natspec for all changes
- [ ] Document security assumptions
- [ ] Create upgrade/deployment guide
- [ ] Document emergency procedures
- [ ] Create runbook for operators

---

## Testing Examples

### Test 1: Burn Address Security
```solidity
function testBurnAddressCannotBeControlled() public {
    // Verify burn address has no known private key
    address burnAddr = adapter.NO_TOKEN_BURN_ADDRESS();
    
    // Should be address(1) or well-known burn
    assertTrue(
        burnAddr == address(1) || 
        burnAddr == 0x000000000000000000000000000000000000dEaD,
        "Burn address not secure"
    );
    
    // Verify tokens can be sent there
    vm.startPrank(user);
    ctf.setApprovalForAll(address(adapter), true);
    adapter.convertPositions(marketId, indexSet, amount);
    
    // Verify NO tokens are at burn address
    uint256 burnBalance = ctf.balanceOf(burnAddr, noPositionId);
    assertGt(burnBalance, 0, "NO tokens not burned");
}
```

### Test 2: Reentrancy Protection
```solidity
function testReentrancyProtection() public {
    ReentrancyAttacker attacker = new ReentrancyAttacker(adapter);
    
    // Give attacker some tokens
    deal(address(usdc), address(attacker), 1000e6);
    
    // Attempt reentrancy attack
    vm.startPrank(address(attacker));
    vm.expectRevert("REENTRANCY");
    attacker.attack();
}

contract ReentrancyAttacker is ERC1155TokenReceiver {
    NegRiskAdapter adapter;
    bool attacked;
    
    function onERC1155BatchReceived(/*...*/) external returns (bytes4) {
        if (!attacked) {
            attacked = true;
            adapter.convertPositions(marketId, indexSet, amount);
        }
        return this.onERC1155BatchReceived.selector;
    }
}
```

### Test 3: Collateral Accounting
```solidity
function testCollateralAccounting() public {
    // Initial state
    uint256 initialCollateral = usdc.balanceOf(address(wcol));
    uint256 initialSupply = wcol.totalSupply();
    
    // Perform operations
    adapter.convertPositions(marketId, indexSet, amount);
    
    // Verify invariant
    uint256 finalCollateral = usdc.balanceOf(address(wcol));
    uint256 finalSupply = wcol.totalSupply();
    uint256 virtualCol = wcol.virtualCollateral();
    
    assertEq(
        finalCollateral,
        finalSupply - virtualCol,
        "Collateral accounting broken"
    );
}
```

---

## Deployment Procedure

### Step 1: Deploy Core Contracts
```solidity
// 1. Deploy WrappedCollateral (with fixes)
WrappedCollateral wcol = new WrappedCollateral(usdc, 6);

// 2. Deploy Vault
Vault vault = new Vault();

// 3. Deploy NegRiskAdapter
NegRiskAdapter adapter = new NegRiskAdapter(
    address(ctf),
    address(usdc),
    address(vault)
);

// 4. Setup permissions
wcol.addOwner(address(adapter));
adapter.addAdmin(operatorAddress);
```

### Step 2: Initialize Oracle (with timelock)
```solidity
// 1. Propose oracle
operator.proposeOracle(oracleAddress);

// 2. Wait 48 hours
vm.warp(block.timestamp + 48 hours);

// 3. Oracle accepts
vm.prank(oracleAddress);
operator.acceptOracle();
```

### Step 3: Security Checks
```solidity
// Verify burn address
require(
    adapter.NO_TOKEN_BURN_ADDRESS() == address(1),
    "Insecure burn address"
);

// Verify collateral accounting
require(
    wcol.checkInvariant(),
    "Collateral accounting failed"
);

// Verify reentrancy protection
require(
    adapter.supportsInterface(type(ReentrancyGuard).interfaceId),
    "Missing reentrancy protection"
);
```

---

**End of Security Fixes Document**
