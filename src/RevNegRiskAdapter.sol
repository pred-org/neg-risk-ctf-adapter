// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ERC1155TokenReceiver} from "lib/solmate/src/tokens/ERC1155.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";
import {WrappedCollateral} from "src/WrappedCollateral.sol";
import {CTHelpers} from "src/libraries/CTHelpers.sol";
import {Helpers} from "src/libraries/Helpers.sol";
import {NegRiskIdLib} from "src/libraries/NegRiskIdLib.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";
import {Auth} from "src/modules/Auth.sol";
import {IAuthEE} from "src/modules/interfaces/IAuth.sol";
import {INegRiskAdapter} from "src/interfaces/INegRiskAdapter.sol";

/// @title IRevNegRiskAdapterEE
/// @notice RevNegRiskAdapter Errors and Events
interface IRevNegRiskAdapterEE is IAuthEE {
    error InvalidIndexSet();
    error LengthMismatch();
    error UnexpectedCollateralToken();
    error NoConvertiblePositions();
    error NotApprovedForAll();
    error InvalidTargetIndex();
    error MarketNotPrepared();

    event PositionsConverted(
        address indexed stakeholder, bytes32 indexed marketId, uint256 indexed targetIndex, uint256 amount
    );
}

/// @title RevNegRiskAdapter
/// @notice Reverse adapter for the CTF enabling the conversion of (n-1) yes positions into 1 no position
/// @notice This is the reverse operation of NegRiskAdapter's convertPositions
/// @notice The adapter allows for the conversion of a set of yes positions to a single no position
/// @author Pred
contract RevNegRiskAdapter is ERC1155TokenReceiver, IRevNegRiskAdapterEE, Auth {
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    IConditionalTokens public immutable ctf;
    ERC20 public immutable col;
    WrappedCollateral public immutable wcol;
    address public immutable vault;
    INegRiskAdapter public immutable neg;
    address public constant YES_TOKEN_BURN_ADDRESS = address(bytes20(bytes32(keccak256("YES_TOKEN_BURN_ADDRESS"))));
    uint256 public constant FEE_DENOMINATOR = 10_000;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _ctf        - ConditionalTokens address
    /// @param _collateral - collateral address
    /// @param _vault      - vault address
    /// @param _neg        - NegRiskAdapter address
    constructor(address _ctf, address _collateral, address _vault, INegRiskAdapter _neg) {
        ctf = IConditionalTokens(_ctf);
        col = ERC20(_collateral);
        vault = _vault;
        neg = _neg;
        // Use the same WCOL instance as the NegRiskAdapter
        wcol = WrappedCollateral(address(_neg.wcol()));
        // approve the ctf to transfer wcol on our behalf
        wcol.approve(_ctf, type(uint256).max);
        // approve wcol to transfer collateral on our behalf
        col.approve(address(wcol), type(uint256).max);
        col.approve(address(neg), type(uint256).max);
        ctf.setApprovalForAll(address(neg), true);
    }

    /*//////////////////////////////////////////////////////////////
                           ERC1155 OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the YES_TOKEN_BURN_ADDRESS constant
    function getYesTokenBurnAddress() external view returns (address) {
        return YES_TOKEN_BURN_ADDRESS;
    }

    /// @notice Returns the FEE_DENOMINATOR constant
    function getFeeDenominator() external view returns (uint256) {
        return FEE_DENOMINATOR;
    }

    /// @notice Proxies ERC1155 balanceOf to the CTF
    /// @param _owner   - the owner of the tokens
    /// @param _id      - the positionId
    /// @return balance - the owner's balance
    function balanceOf(address _owner, uint256 _id) external view returns (uint256) {
        return ctf.balanceOf(_owner, _id);
    }

    /// @notice Proxies ERC1155 balanceOfBatch to the CTF
    /// @param _owners   - the owners of the tokens
    /// @param _ids      - the positionIds
    /// @return balances - the owners' balances
    function balanceOfBatch(address[] memory _owners, uint256[] memory _ids) external view returns (uint256[] memory) {
        return ctf.balanceOfBatch(_owners, _ids);
    }

    /// @notice Proxies ERC1155 safeTransferFrom to the CTF
    /// @notice Can only be called by an admin
    /// @notice Requires this contract to be approved for all
    /// @notice Requires the sender to be approved for all
    /// @param _from  - the owner of the tokens
    /// @param _to    - the recipient of the tokens
    /// @param _id    - the positionId
    /// @param _value - the amount of tokens to transfer
    /// @param _data  - the data to pass to the recipient
    function safeTransferFrom(address _from, address _to, uint256 _id, uint256 _value, bytes calldata _data)
        external
        onlyAdmin
    {
        if (!ctf.isApprovedForAll(_from, msg.sender)) {
            revert NotApprovedForAll();
        }

        return ctf.safeTransferFrom(_from, _to, _id, _value, _data);
    }

    /*//////////////////////////////////////////////////////////////
                            CONVERT POSITIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Convert a set of (n-1) yes positions to 1 no position
    /// @notice This is the reverse operation of NegRiskAdapter's convertPositions
    /// @notice If the market has a fee, the fee is taken from the no position
    /// @param _marketId - the marketId
    /// @param _targetIndex - the index of the question for which to get the NO position
    /// @param _amount   - the amount of tokens to convert
    function convertPositions(bytes32 _marketId, uint256 _targetIndex, uint256 _amount, address _recipient) public {
        if (!neg.getPrepared(_marketId)) revert MarketNotPrepared();
        uint256 questionCount = neg.getQuestionCount(_marketId);

        if (questionCount <= 1) revert NoConvertiblePositions();
        if (_targetIndex >= questionCount) revert InvalidTargetIndex();

        // if _amount is 0, return early
        if (_amount == 0) {
            return;
        }

        // Get fee information from the NegRiskAdapter
        uint256 feeBips = neg.getFeeBips(_marketId);
        uint256 feeAmount = (_amount * feeBips) / FEE_DENOMINATOR;
        uint256 amountOut = _amount - feeAmount;

        // **Seed:** adapter mints **+A WCOL** once.
        wcol.mint(_amount);

        // Collect all yesPositionIds that need to be burned (skip resolved questions and target index)
        uint256[] memory yesPositionIds = new uint256[](questionCount - 1);
        uint256 positionCount = 0;
        
        // **For each j ≠ i (loop):**
        for (uint256 j = 0; j < questionCount;) {
            if (j != _targetIndex) {
                bytes32 questionId = NegRiskIdLib.getQuestionId(_marketId, uint8(j));
                bytes32 conditionId = neg.getConditionId(questionId);
                
                // Skip resolved questions - they don't have YES tokens to burn
                // A question is resolved if payoutDenominator >= 1
                if (ctf.payoutDenominator(conditionId) >= 1) {
                    unchecked { ++j; }
                    continue;
                }
                
                uint256 yesPositionId = neg.getPositionId(questionId, true);
                yesPositionIds[positionCount] = yesPositionId;
                unchecked { ++positionCount; }
            }
            unchecked { ++j; }
        }

        // Batch transfer all YES tokens to burn address in a single call (gas optimization)
        if (positionCount > 0) {
            // Resize array to actual size if needed
            if (positionCount < yesPositionIds.length) {
                assembly {
                    mstore(yesPositionIds, positionCount)
                }
            }
            ctf.safeBatchTransferFrom(msg.sender, YES_TOKEN_BURN_ADDRESS, yesPositionIds, Helpers.values(positionCount, _amount), "");
        }

        // Process target question - use the collected USDC to get WCOL for the split
        _processTargetQuestion(_marketId, _targetIndex, _amount, feeAmount, amountOut, _recipient);

        // **Net result:** user's YES tokens burned for non-target questions,
        // and user receives NO tokens for the target question

        emit PositionsConverted(msg.sender, _marketId, _targetIndex, _amount);
    }

    /// @notice Convert all yes positions to a single no position and then merge to get collateral
    /// @param _marketId - the marketId
    /// @param _amount   - the amount of tokens to convert
    function mergeAllYesTokens(bytes32 _marketId, uint256 _amount) public {
        mergeAllYesTokens(_marketId, _amount, 0);
    }

    /// @notice Convert all yes positions to a single no position and then merge to get collateral
    /// @param _marketId - the marketId
    /// @param _amount   - the amount of tokens to convert
    /// @param _pivotId  - the index of the question to use as pivot for merging
    function mergeAllYesTokens(bytes32 _marketId, uint256 _amount, uint256 _pivotId) public {
        // convert all yes positions to the pivot no position
        // Then merge the pivot no position with pivot yes position to get USDC
        convertPositions(_marketId, _pivotId, _amount, address(this));
        
        // Get the actual amount of NO tokens the adapter has (after fees)
        uint256 noPositionId = neg.getPositionId(NegRiskIdLib.getQuestionId(_marketId, uint8(_pivotId)), false);
        uint256 actualNoAmount = ctf.balanceOf(address(this), noPositionId);
        
        // Transfer the YES tokens from the user to the adapter for merging
        uint256 yesPositionId = neg.getPositionId(NegRiskIdLib.getQuestionId(_marketId, uint8(_pivotId)), true);
        ctf.safeTransferFrom(msg.sender, address(this), yesPositionId, _amount, "");
        
        // Merge the NO and YES tokens to get USDC (adapter has both tokens)
        neg.mergePositions(neg.getConditionId(NegRiskIdLib.getQuestionId(_marketId, uint8(_pivotId))), actualNoAmount);
        
        // Transfer the USDC to the user (amount after fees)
        col.transfer(msg.sender, actualNoAmount);
    }

    /// @dev internal function to process target question and avoid stack too deep
    function _processTargetQuestion(
        bytes32 _marketId, 
        uint256 _targetIndex, 
        uint256 _amount, 
        uint256 _feeAmount, 
        uint256 _amountOut,
        address _recipient
    ) internal {
        bytes32 targetQuestionId = NegRiskIdLib.getQuestionId(_marketId, uint8(_targetIndex));
        bytes32 targetConditionId = neg.getConditionId(targetQuestionId);
        uint256 targetYesPositionId = neg.getPositionId(targetQuestionId, true);
        uint256 targetNoPositionId = neg.getPositionId(targetQuestionId, false);

        // `split` on i: **−A WCOL**, +A `YES(i)`, +A `NO(i)`.
        _splitPosition(targetConditionId, _amount);

        // neg.splitPosition(targetConditionId, _amount);

        // burn the YES(i) we created from split: −A `YES(i)`.
        ctf.safeTransferFrom(address(this), YES_TOKEN_BURN_ADDRESS, targetYesPositionId, _amount, "");

        // transfer `NO(i)` to user (and fee to vault if any).
        if (_feeAmount > 0) {
            // transfer no token fees to vault
            ctf.safeTransferFrom(address(this), vault, targetNoPositionId, _feeAmount, "");
        }

        // transfer no tokens to sender
        ctf.safeTransferFrom(address(this), _recipient, targetNoPositionId, _amountOut, "");
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev internal function to avoid stack too deep in convertPositions
    function _splitPosition(bytes32 _conditionId, uint256 _amount) internal {
        ctf.splitPosition(address(wcol), bytes32(0), _conditionId, Helpers.partition(), _amount);
    }
}
