// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {NegRiskAdapter} from "src/NegRiskAdapter.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";
import {WrappedCollateral} from "src/WrappedCollateral.sol";
import {ERC1155TokenReceiver} from "lib/solmate/src/tokens/ERC1155.sol";
import {Helpers} from "src/libraries/Helpers.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";

/// @title INegRiskBatchRedeemEE
/// @notice NegRiskBatchRedeem Errors and Events
interface INegRiskBatchRedeemEE {
    error NotAdmin();
    error NotOperator();
    error InvalidArrayLength();
    error NoTokensToRedeem();
    error TransferFailed();

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
        bytes32 indexed questionId,
        address[] indexed users,
        uint256[] indexed amounts,
        uint256 totalPayout
    );
}

/// @title NegRiskBatchRedeem
/// @notice Contract that provides batch redemption functionality for whitelisted operators
/// @notice Operators can redeem positions for multiple users who have given token allowance to this contract
/// @author Pred
contract NegRiskBatchRedeem is ERC1155TokenReceiver, INegRiskBatchRedeemEE {
    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    NegRiskAdapter public immutable negRiskAdapter;
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

    /// @param _negRiskAdapter - NegRiskAdapter address
    constructor(address _negRiskAdapter) {
        negRiskAdapter = NegRiskAdapter(_negRiskAdapter);
        ctf = negRiskAdapter.ctf();
        col = negRiskAdapter.col();
        
        // Approve the NegRiskAdapter to transfer tokens on behalf of this contract
        ctf.setApprovalForAll(address(negRiskAdapter), true);
        
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

        // Redeem the positions using the adapter's redeemPositions function
        negRiskAdapter.redeemPositions(_conditionId, userAmounts);

        payout = col.balanceOf(address(this));
        if (payout > 0) {
            // Transfer the payout to the user
            col.transfer(_user, payout);
        }
    }

    /// @notice Batch redeem positions for multiple users with custom amounts for yes/no tokens
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
            uint256 userPayout = _redeemUserPositions(conditionId, user, yesPositionId, noPositionId, yesAmount, noAmount);
            totalPayout += userPayout;
        }

        emit BatchRedemption(_questionId, _users, _yesAmounts, totalPayout);
    }
}
