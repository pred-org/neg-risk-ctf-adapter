// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {NegRiskAdapter} from "src/NegRiskAdapter.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";
import {WrappedCollateral} from "src/WrappedCollateral.sol";
import {ERC1155TokenReceiver} from "lib/solmate/src/tokens/ERC1155.sol";
import {Helpers} from "src/libraries/Helpers.sol";
import {CTHelpers} from "src/libraries/CTHelpers.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";

/// @title IUnifiedBatchRedeemEE
/// @notice Unified Batch Redeem Errors and Events
interface IUnifiedBatchRedeemEE {
    error NotAdmin();
    error NotOperator();
    error InvalidArrayLength();
    error NoTokensToRedeem();
    error TransferFailed();
    error InvalidMarketType();
    error InvalidConfiguration();

    /// @notice Emitted when a new admin is added
    event NewAdmin(address indexed admin, address indexed newAdminAddress);

    /// @notice Emitted when an admin is removed
    event RemovedAdmin(address indexed admin, address indexed removedAdmin);

    /// @notice Emitted when a new operator is added
    event NewOperator(address indexed admin, address indexed newOperatorAddress);

    /// @notice Emitted when an operator is removed
    event RemovedOperator(address indexed admin, address indexed removedOperator);

    /// @notice Emitted when batch redemption is performed for NegRisk markets
    event BatchRedemptionNegRisk(
        bytes32 indexed questionId,
        address[] indexed users,
        uint256[] yesAmounts,
        uint256[] noAmounts,
        uint256 totalPayout
    );

    /// @notice Emitted when batch redemption is performed for CTF Exchange markets
    event BatchRedemptionCtfExchange(
        bytes32 indexed conditionId,
        address[] indexed users,
        uint256[] yesAmounts,
        uint256[] noAmounts,
        uint256 totalPayout
    );
}

/// @title UnifiedBatchRedeem
/// @notice Unified contract that provides batch redemption functionality for both NegRiskAdapter and CTF Exchange markets
/// @notice Operators can redeem positions for multiple users who have given token allowance to this contract
/// @notice Supports two market types: NegRisk (via adapter) and CTF Exchange (direct CTF)
/// @author Pred
contract UnifiedBatchRedeem is ERC1155TokenReceiver, IUnifiedBatchRedeemEE {
    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Market type enum
    enum MarketType {
        NEG_RISK,      // Uses NegRiskAdapter with wrapped collateral
        CTF_EXCHANGE   // Direct CTF with unwrapped collateral
    }

    MarketType public immutable marketType;
    NegRiskAdapter public immutable negRiskAdapter; // address(0) for CTF Exchange mode
    IConditionalTokens public immutable ctf;
    ERC20 public immutable col;
    WrappedCollateral public immutable wcol; // address(0) for CTF Exchange mode

    /// @dev The set of addresses authorized as Operators
    mapping(address => uint256) public operators;

    /// @dev The set of addresses authorized as Admins
    mapping(address => uint256) public admins;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        if (admins[msg.sender] != 1) revert NotAdmin();
        _;
    }

    modifier onlyOperator() {
        if (operators[msg.sender] != 1) revert NotOperator();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _marketType - Market type: 0 for NEG_RISK, 1 for CTF_EXCHANGE
    /// @param _negRiskAdapter - NegRiskAdapter address (address(0) for CTF Exchange mode)
    /// @param _ctf - ConditionalTokens contract address
    /// @param _collateral - Collateral token address (e.g., USDC)
    /// @param _wcol - WrappedCollateral address (address(0) for CTF Exchange mode)
    constructor(
        MarketType _marketType,
        address _negRiskAdapter,
        address _ctf,
        address _collateral,
        address _wcol
    ) {
        marketType = _marketType;
        ctf = IConditionalTokens(_ctf);
        col = ERC20(_collateral);

        // Validate configuration based on market type
        if (_marketType == MarketType.NEG_RISK) {
            if (_negRiskAdapter == address(0) || _wcol == address(0)) {
                revert InvalidConfiguration();
            }
        } else {
            // CTF Exchange mode
            if (_negRiskAdapter != address(0) || _wcol != address(0)) {
                revert InvalidConfiguration();
            }
        }

        // Initialize immutable variables (must be unconditional)
        negRiskAdapter = _marketType == MarketType.NEG_RISK 
            ? NegRiskAdapter(_negRiskAdapter) 
            : NegRiskAdapter(address(0));
        wcol = _marketType == MarketType.NEG_RISK 
            ? WrappedCollateral(_wcol) 
            : WrappedCollateral(address(0));

        // Approve the NegRiskAdapter to transfer tokens on behalf of this contract (only for NegRisk)
        if (_marketType == MarketType.NEG_RISK) {
            ctf.setApprovalForAll(_negRiskAdapter, true);
        }

        // Deployer is automatically an admin and an operator
        admins[msg.sender] = 1;
        operators[msg.sender] = 1;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks if an address is an admin
    /// @param usr - The address to be checked
    /// @return true if usr is an admin, false if not
    function isAdmin(address usr) external view returns (bool) {
        return admins[usr] == 1;
    }

    /// @notice Adds a new admin
    /// Can only be called by a current admin
    /// @param admin_ - The new admin
    function addAdmin(address admin_) external onlyAdmin {
        admins[admin_] = 1;
        emit NewAdmin(msg.sender, admin_);
    }

    /// @notice Removes an existing admin
    /// Can only be called by a current admin
    /// @param admin - The admin to be removed
    function removeAdmin(address admin) external onlyAdmin {
        admins[admin] = 0;
        emit RemovedAdmin(msg.sender, admin);
    }

    /// @notice Renounces Admin privileges from the caller
    function renounceAdmin() external onlyAdmin {
        admins[msg.sender] = 0;
        emit RemovedAdmin(msg.sender, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            OPERATOR MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks if an address is an operator
    /// @param usr - The address to be checked
    /// @return true if usr is an operator, false if not
    function isOperator(address usr) external view returns (bool) {
        return operators[usr] == 1;
    }

    /// @notice Adds a new operator
    /// Can only be called by a current admin
    /// @param operator_ - The new operator
    function addOperator(address operator_) external onlyAdmin {
        operators[operator_] = 1;
        emit NewOperator(msg.sender, operator_);
    }

    /// @notice Removes an existing operator
    /// Can only be called by a current admin
    /// @param operator - The operator to be removed
    function removeOperator(address operator) external onlyAdmin {
        operators[operator] = 0;
        emit RemovedOperator(msg.sender, operator);
    }

    /*//////////////////////////////////////////////////////////////
                            BATCH REDEMPTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal helper to execute redemption based on market type
    /// @param _conditionId - the conditionId to redeem positions for
    /// @param _userAmounts - array of token amounts to redeem
    function _executeRedemption(bytes32 _conditionId, uint256[] memory _userAmounts) internal {
        if (marketType == MarketType.NEG_RISK) {
            // Redeem the positions using the adapter's redeemPositions function
            negRiskAdapter.redeemPositions(_conditionId, _userAmounts);
        } else {
            // Redeem the positions directly using ConditionalTokens
            // For binary markets, we need to redeem both index sets [1, 2]
            uint256[] memory indexSets = Helpers.partition(); // [1, 2]
            ctf.redeemPositions(address(col), bytes32(0), _conditionId, indexSets);
        }
    }

    /// @notice Internal helper to handle payout based on market type
    /// @param _user - the user address to receive payout
    /// @return payout - the payout amount for this user
    function _handlePayout(address _user) internal returns (uint256 payout) {
        if (marketType == MarketType.NEG_RISK) {
            // NegRiskAdapter returns WCOL, need to unwrap it
            payout = wcol.balanceOf(address(this));
            if (payout > 0) {
                wcol.unwrap(_user, payout);
            }
        } else {
            // CTF Exchange returns direct collateral
            payout = col.balanceOf(address(this));
            if (payout > 0) {
                col.transfer(_user, payout);
            }
        }
    }

    /// @notice Unified internal helper to redeem positions for a single user
    /// @param _conditionId - the conditionId to redeem positions for
    /// @param _user - the user address
    /// @param _yesPositionId - positionId for yes tokens
    /// @param _noPositionId - positionId for no tokens
    /// @param _yesAmount - amount of yes tokens to redeem
    /// @param _noAmount - amount of no tokens to redeem
    /// @return payout - the payout amount for this user
    function _redeemUserPositions(
        bytes32 _conditionId,
        address _user,
        uint256 _yesPositionId,
        uint256 _noPositionId,
        uint256 _yesAmount,
        uint256 _noAmount
    ) internal returns (uint256 payout) {
        if (_yesAmount == 0 && _noAmount == 0) return 0;

        uint256 numTokens = (_yesAmount > 0 ? 1 : 0) + (_noAmount > 0 ? 1 : 0);
        uint256[] memory positionIds = new uint256[](numTokens);
        uint256[] memory userAmounts = new uint256[](numTokens);
        uint256 idx = 0;
        if (_yesAmount > 0) {
            positionIds[idx] = _yesPositionId;
            userAmounts[idx] = _yesAmount;
            idx++;
        }
        if (_noAmount > 0) {
            positionIds[idx] = _noPositionId;
            userAmounts[idx] = _noAmount;
        }

        // Transfer tokens from user to this contract
        ctf.safeBatchTransferFrom(_user, address(this), positionIds, userAmounts, "");

        // Execute redemption based on market type
        _executeRedemption(_conditionId, userAmounts);

        // Handle payout based on market type
        payout = _handlePayout(_user);
    }

    /// @notice Batch redeem positions for NegRisk markets (uses questionId)
    /// @notice Can only be called by whitelisted operators
    /// @notice Assumes all users have given token allowance to this contract
    /// @param _questionId - the questionId to redeem positions for
    /// @param _users - array of user addresses to redeem for
    /// @param _yesAmounts - array of yes token amounts to redeem for each user
    /// @param _noAmounts - array of no token amounts to redeem for each user
    function batchRedeemQuestionCustom(
        bytes32 _questionId,
        address[] calldata _users,
        uint256[] calldata _yesAmounts,
        uint256[] calldata _noAmounts
    ) external onlyOperator {
        if (marketType != MarketType.NEG_RISK) revert InvalidMarketType();
        if (_users.length != _yesAmounts.length || _users.length != _noAmounts.length) {
            revert InvalidArrayLength();
        }
        if (_users.length == 0) revert NoTokensToRedeem();

        bytes32 conditionId = negRiskAdapter.getConditionId(_questionId);
        uint256 yesPositionId = negRiskAdapter.getPositionId(_questionId, true);
        uint256 noPositionId = negRiskAdapter.getPositionId(_questionId, false);
        uint256 totalPayout = 0;

        // Process each user
        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            uint256 yesAmount = _yesAmounts[i];
            uint256 noAmount = _noAmounts[i];

            // Redeem positions for this user with custom amounts
            uint256 userPayout = _redeemUserPositions(
                conditionId,
                user,
                yesPositionId,
                noPositionId,
                yesAmount,
                noAmount
            );
            totalPayout += userPayout;
        }

        emit BatchRedemptionNegRisk(_questionId, _users, _yesAmounts, _noAmounts, totalPayout);
    }

    /// @notice Batch redeem positions for CTF Exchange markets (uses conditionId)
    /// @notice Can only be called by whitelisted operators
    /// @notice Assumes all users have given token allowance to this contract
    /// @param _conditionId - the conditionId to redeem positions for
    /// @param _users - array of user addresses to redeem for
    /// @param _yesAmounts - array of yes token amounts to redeem for each user
    /// @param _noAmounts - array of no token amounts to redeem for each user
    function batchRedeemConditionCustom(
        bytes32 _conditionId,
        address[] calldata _users,
        uint256[] calldata _yesAmounts,
        uint256[] calldata _noAmounts
    ) external onlyOperator {
        if (marketType != MarketType.CTF_EXCHANGE) revert InvalidMarketType();
        if (_users.length != _yesAmounts.length || _users.length != _noAmounts.length) {
            revert InvalidArrayLength();
        }
        if (_users.length == 0) revert NoTokensToRedeem();

        // Calculate position IDs from condition ID
        // CTFExchange uses opposite mapping: index 1 = NO, index 2 = YES (opposite of NegRiskAdapter)
        uint256 yesPositionId = CTHelpers.getPositionId(
            address(col),
            CTHelpers.getCollectionId(bytes32(0), _conditionId, 2)
        );
        uint256 noPositionId = CTHelpers.getPositionId(
            address(col),
            CTHelpers.getCollectionId(bytes32(0), _conditionId, 1)
        );

        uint256 totalPayout = 0;

        // Process each user
        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            uint256 yesAmount = _yesAmounts[i];
            uint256 noAmount = _noAmounts[i];

            // Redeem positions for this user with custom amounts
            uint256 userPayout = _redeemUserPositions(
                _conditionId,
                user,
                yesPositionId,
                noPositionId,
                yesAmount,
                noAmount
            );
            totalPayout += userPayout;
        }

        emit BatchRedemptionCtfExchange(_conditionId, _users, _yesAmounts, _noAmounts, totalPayout);
    }
}

