// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";
import {ERC1155TokenReceiver} from "lib/solmate/src/tokens/ERC1155.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {CTHelpers} from "src/libraries/CTHelpers.sol";
import {Helpers} from "src/libraries/Helpers.sol";

/// @title ICtfExchangeBatchRedeemEE
/// @notice CTF Exchange Batch Redeem Errors and Events
interface ICtfExchangeBatchRedeemEE {
    error NotAdmin();
    error NotOperator();
    error InvalidArrayLength();
    error NoTokensToRedeem();

    /// @notice Emitted when a new admin is added
    event NewAdmin(address indexed admin, address indexed newAdminAddress);

    /// @notice Emitted when an admin is removed
    event RemovedAdmin(address indexed admin, address indexed removedAdmin);

    /// @notice Emitted when a new operator is added
    event NewOperator(address indexed admin, address indexed newOperatorAddress);

    /// @notice Emitted when an operator is removed
    event RemovedOperator(address indexed admin, address indexed removedOperator);

    /// @notice Emitted when batch redemption is performed
    event BatchRedemption(
        bytes32 indexed conditionId,
        address[] indexed users,
        uint256[] yesAmounts,
        uint256[] noAmounts,
        uint256 totalPayout
    );
}

/// @title CtfExchangeBatchRedeem
/// @notice Contract that provides batch redemption functionality for CTF Exchange markets
/// @notice Operators can redeem positions for multiple users who have given token allowance to this contract
/// @notice Works directly with ConditionalTokens, bypassing NegRiskAdapter
/// @author Pred
contract CtfExchangeBatchRedeem is ERC1155TokenReceiver, ICtfExchangeBatchRedeemEE {
    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    IConditionalTokens public immutable ctf;
    ERC20 public immutable col;

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

    /// @param _ctf - ConditionalTokens contract address
    /// @param _collateral - Collateral token address (e.g., USDC)
    constructor(address _ctf, address _collateral) {
        ctf = IConditionalTokens(_ctf);
        col = ERC20(_collateral);
        
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

    /// @notice Internal helper to redeem positions for a single user
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

        // Redeem the positions directly using ConditionalTokens
        // For binary markets, we need to redeem both index sets [1, 2]
        uint256[] memory indexSets = Helpers.partition(); // [1, 2]
        ctf.redeemPositions(address(col), bytes32(0), _conditionId, indexSets);

        payout = col.balanceOf(address(this));
        if (payout > 0) {
            // Transfer the payout to the user
            col.transfer(_user, payout);
        }
    }

    /// @notice Batch redeem positions for multiple users with custom amounts for yes/no tokens
    /// @notice Can only be called by whitelisted operators
    /// @notice Assumes all users have given token allowance to this contract
    /// @param _conditionId - the conditionId to redeem positions for
    /// @param _users - array of user addresses to redeem for
    /// @param _yesAmounts - array of yes token amounts to redeem for each user
    /// @param _noAmounts - array of no token amounts to redeem for each user
    function batchRedeemCondition(
        bytes32 _conditionId,
        address[] calldata _users,
        uint256[] calldata _yesAmounts,
        uint256[] calldata _noAmounts
    ) external onlyOperator {
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
            uint256 userPayout = _redeemUserPositions(_conditionId, user, yesPositionId, noPositionId, yesAmount, noAmount);
            totalPayout += userPayout;
        }

        emit BatchRedemption(_conditionId, _users, _yesAmounts, _noAmounts, totalPayout);
    }
}

