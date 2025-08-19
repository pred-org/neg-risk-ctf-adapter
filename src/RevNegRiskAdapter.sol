// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ERC1155TokenReceiver} from "lib/solmate/src/tokens/ERC1155.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";
import {WrappedCollateral} from "src/WrappedCollateral.sol";
import {MarketData, MarketStateManager, IMarketStateManagerEE} from "src/modules/MarketDataManager.sol";
import {CTHelpers} from "src/libraries/CTHelpers.sol";
import {Helpers} from "src/libraries/Helpers.sol";
import {NegRiskIdLib} from "src/libraries/NegRiskIdLib.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";
import {Auth} from "src/modules/Auth.sol";
import {IAuthEE} from "src/modules/interfaces/IAuth.sol";

/// @title IRevNegRiskAdapterEE
/// @notice RevNegRiskAdapter Errors and Events
interface IRevNegRiskAdapterEE is IMarketStateManagerEE, IAuthEE {
    error InvalidIndexSet();
    error LengthMismatch();
    error UnexpectedCollateralToken();
    error NoConvertiblePositions();
    error NotApprovedForAll();
    error InvalidTargetIndex();

    event MarketPrepared(bytes32 indexed marketId, address indexed oracle, uint256 feeBips, bytes data);
    event QuestionPrepared(bytes32 indexed marketId, bytes32 indexed questionId, uint256 index, bytes data);
    event OutcomeReported(bytes32 indexed marketId, bytes32 indexed questionId, bool outcome);
    event PositionSplit(address indexed stakeholder, bytes32 indexed conditionId, uint256 amount);
    event PositionsMerge(address indexed stakeholder, bytes32 indexed conditionId, uint256 amount);
    event PositionsConverted(
        address indexed stakeholder, bytes32 indexed marketId, uint256 indexed targetIndex, uint256 amount
    );
    event PayoutRedemption(address indexed redeemer, bytes32 indexed conditionId, uint256[] amounts, uint256 payout);
}

/// @title RevNegRiskAdapter
/// @notice Reverse adapter for the CTF enabling the conversion of (n-1) yes positions into 1 no position
/// @notice This is the reverse operation of NegRiskAdapter's convertPositions
/// @notice The adapter allows for the conversion of a set of yes positions to a single no position
/// @author Based on NegRiskAdapter by Mike Shrieve (mike@polymarket.com)
contract RevNegRiskAdapter is ERC1155TokenReceiver, MarketStateManager, IRevNegRiskAdapterEE, Auth {
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    IConditionalTokens public immutable ctf;
    ERC20 public immutable col;
    WrappedCollateral public immutable wcol;
    address public immutable vault;

    address public constant YES_TOKEN_BURN_ADDRESS = address(bytes20(bytes32(keccak256("YES_TOKEN_BURN_ADDRESS"))));
    uint256 public constant FEE_DENOMINATOR = 10_000;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _ctf        - ConditionalTokens address
    /// @param _collateral - collateral address
    constructor(address _ctf, address _collateral, address _vault) {
        ctf = IConditionalTokens(_ctf);
        col = ERC20(_collateral);
        vault = _vault;

        wcol = new WrappedCollateral(_collateral, col.decimals());
        // approve the ctf to transfer wcol on our behalf
        wcol.approve(_ctf, type(uint256).max);
        // approve wcol to transfer collateral on our behalf
        col.approve(address(wcol), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                                  IDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the conditionId for a given questionId
    /// @param _questionId  - the questionId
    /// @return conditionId - the corresponding conditionId
    function getConditionId(bytes32 _questionId) public view returns (bytes32) {
        return CTHelpers.getConditionId(
            address(this), // oracle
            _questionId,
            2 // outcomeCount
        );
    }

    /// @notice Returns the positionId for a given questionId and outcome
    /// @param _questionId  - the questionId
    /// @param _outcome     - the boolean outcome
    /// @return positionId  - the corresponding positionId
    function getPositionId(bytes32 _questionId, bool _outcome) public view returns (uint256) {
        bytes32 collectionId = CTHelpers.getCollectionId(
            bytes32(0),
            getConditionId(_questionId),
            _outcome ? 1 : 2 // 1 (0b01) is yes, 2 (0b10) is no
        );

        uint256 positionId = CTHelpers.getPositionId(address(wcol), collectionId);
        return positionId;
    }

    /*//////////////////////////////////////////////////////////////
                             SPLIT POSITION
    //////////////////////////////////////////////////////////////*/

    /// @notice Splits collateral to a complete set of conditional tokens for a single question
    /// @notice This function signature is the same as the CTF's splitPosition
    /// @param _collateralToken - the collateral token, must be the same as the adapter's collateral token
    /// @param _conditionId - the conditionId for the question
    /// @param _amount - the amount of collateral to split
    function splitPosition(address _collateralToken, bytes32, bytes32 _conditionId, uint256[] calldata, uint256 _amount)
        external
    {
        if (_collateralToken != address(col)) revert UnexpectedCollateralToken();
        splitPosition(_conditionId, _amount);
    }

    /// @notice Splits collateral to a complete set of conditional tokens for a single question
    /// @param _conditionId - the conditionId for the question
    /// @param _amount      - the amount of collateral to split
    function splitPosition(bytes32 _conditionId, uint256 _amount) public {
        col.safeTransferFrom(msg.sender, address(this), _amount);
        wcol.wrap(address(this), _amount);
        ctf.splitPosition(address(wcol), bytes32(0), _conditionId, Helpers.partition(), _amount);
        ctf.safeBatchTransferFrom(
            address(this), msg.sender, Helpers.positionIds(address(wcol), _conditionId), Helpers.values(2, _amount), ""
        );

        emit PositionSplit(msg.sender, _conditionId, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                            MERGE POSITIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Merges a complete set of conditional tokens for a single question to collateral
    /// @notice This function signature is the same as the CTF's mergePositions
    /// @param _collateralToken - the collateral token, must be the same as the adapter's collateral token
    /// @param _conditionId     - the conditionId for the question
    /// @param _amount          - the amount of collateral to merge
    function mergePositions(
        address _collateralToken,
        bytes32,
        bytes32 _conditionId,
        uint256[] calldata,
        uint256 _amount
    ) external {
        if (_collateralToken != address(col)) revert UnexpectedCollateralToken();
        mergePositions(_conditionId, _amount);
    }

    /// @notice Merges a complete set of conditional tokens for a single question to collateral
    /// @param _conditionId - the conditionId for the question
    /// @param _amount      - the amount of collateral to merge
    function mergePositions(bytes32 _conditionId, uint256 _amount) public {
        uint256[] memory positionIds = Helpers.positionIds(address(wcol), _conditionId);

        // get conditional tokens from sender
        ctf.safeBatchTransferFrom(msg.sender, address(this), positionIds, Helpers.values(2, _amount), "");
        ctf.mergePositions(address(wcol), bytes32(0), _conditionId, Helpers.partition(), _amount);
        wcol.unwrap(msg.sender, _amount);

        emit PositionsMerge(msg.sender, _conditionId, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                           ERC1155 OPERATIONS
    //////////////////////////////////////////////////////////////*/

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
                            REDEEM POSITION
    //////////////////////////////////////////////////////////////*/

    /// @notice Redeem a set of conditional tokens for collateral
    /// @param _conditionId - conditionId of the conditional tokens to redeem
    /// @param _amounts     - amounts of conditional tokens to redeem
    /// _amounts should always have length 2, with the first element being the amount of yes tokens to redeem and the
    /// second element being the amount of no tokens to redeem
    function redeemPositions(bytes32 _conditionId, uint256[] calldata _amounts) public {
        uint256[] memory positionIds = Helpers.positionIds(address(wcol), _conditionId);

        // get conditional tokens from sender
        ctf.safeBatchTransferFrom(msg.sender, address(this), positionIds, _amounts, "");
        ctf.redeemPositions(address(wcol), bytes32(0), _conditionId, Helpers.partition());

        uint256 payout = wcol.balanceOf(address(this));
        if (payout > 0) {
            wcol.unwrap(msg.sender, payout);
        }

        emit PayoutRedemption(msg.sender, _conditionId, _amounts, payout);
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
    function convertPositions(bytes32 _marketId, uint256 _targetIndex, uint256 _amount) external {
        MarketData md = getMarketData(_marketId);
        uint256 questionCount = md.questionCount();

        if (md.oracle() == address(0)) revert MarketNotPrepared();
        if (questionCount <= 1) revert NoConvertiblePositions();
        if (_targetIndex >= questionCount) revert InvalidTargetIndex();

        // if _amount is 0, return early
        if (_amount == 0) {
            return;
        }

        // Pre-calculate fee amounts
        uint256 feeAmount = (_amount * md.feeBips()) / FEE_DENOMINATOR;
        uint256 amountOut = _amount - feeAmount;

        // **Seed:** adapter mints **+A WCOL** once.
        wcol.mint(_amount);

        // **For each j ≠ i (loop):**
        for (uint256 j = 0; j < questionCount; j++) {
            if (j != _targetIndex) {
                bytes32 questionId = NegRiskIdLib.getQuestionId(_marketId, uint8(j));
                bytes32 conditionId = getConditionId(questionId);
                uint256 yesPositionId = getPositionId(questionId, true);

                // `split` on j: **−A WCOL**, +A `YES(j)'`, +A `NO(j)`.
                _splitPosition(conditionId, _amount);

                // Get user's YES(j) tokens and merge with our NO(j) to get WCOL back
                ctf.safeTransferFrom(msg.sender, address(this), yesPositionId, _amount, "");
                _mergePositions(conditionId, _amount);

                // burn by-product `YES(j)'`: −A `YES(j)'`.
                ctf.safeTransferFrom(address(this), YES_TOKEN_BURN_ADDRESS, yesPositionId, _amount, "");
                
                // **Net after each j:** WCOL still **+A**; user's `YES(j)` is gone; no stray tokens.
            }
        }

        // **Final step (outcome i):**
        bytes32 targetQuestionId = NegRiskIdLib.getQuestionId(_marketId, uint8(_targetIndex));
        bytes32 targetConditionId = getConditionId(targetQuestionId);
        uint256 targetYesPositionId = getPositionId(targetQuestionId, true);
        uint256 targetNoPositionId = getPositionId(targetQuestionId, false);

        // `split` on i: **−A WCOL**, +A `YES(i)`, +A `NO(i)`.
        _splitPosition(targetConditionId, _amount);

        // Get user's target YES position and burn it: −A `YES(i)`.
        ctf.safeTransferFrom(msg.sender, YES_TOKEN_BURN_ADDRESS, targetYesPositionId, _amount, "");

        // burn the YES(i) we created from split: −A `YES(i)`.
        ctf.safeTransferFrom(address(this), YES_TOKEN_BURN_ADDRESS, targetYesPositionId, _amount, "");

        // transfer `NO(i)` to user (and fee to vault if any).
        if (feeAmount > 0) {
            // transfer no token fees to vault
            ctf.safeTransferFrom(address(this), vault, targetNoPositionId, feeAmount, "");
        }

        // transfer no tokens to sender
        ctf.safeTransferFrom(address(this), msg.sender, targetNoPositionId, amountOut, "");

        // **Net after final split:** **0 WCOL** left.
        // Verify we have no WCOL left (should be 0)
        uint256 remainingWcol = wcol.balanceOf(address(this));
        if (remainingWcol > 0) {
            // Burn any remaining WCOL
            wcol.burn(remainingWcol);
        }

        emit PositionsConverted(msg.sender, _marketId, _targetIndex, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                             PREPARE MARKET
    //////////////////////////////////////////////////////////////*/

    /// @notice Prepare a multi-outcome market
    /// @param _feeBips  - the fee for the market, out of 10_000
    /// @param _metadata     - metadata for the market
    /// @return marketId - the marketId
    function prepareMarket(uint256 _feeBips, bytes calldata _metadata) external returns (bytes32) {
        bytes32 marketId = _prepareMarket(_feeBips, _metadata);

        emit MarketPrepared(marketId, msg.sender, _feeBips, _metadata);

        return marketId;
    }

    /*//////////////////////////////////////////////////////////////
                            PREPARE QUESTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Prepare a question for a given market
    /// @param _marketId   - the id of the market for which to prepare the question
    /// @param _metadata   - the question metadata
    /// @return questionId - the id of the resulting question
    function prepareQuestion(bytes32 _marketId, bytes calldata _metadata) external returns (bytes32) {
        (bytes32 questionId, uint256 questionIndex) = _prepareQuestion(_marketId);
        bytes32 conditionId = getConditionId(questionId);

        // check to see if the condition has already been prepared on the ctf
        if (ctf.getOutcomeSlotCount(conditionId) == 0) {
            ctf.prepareCondition(address(this), questionId, 2);
        }

        emit QuestionPrepared(_marketId, questionId, questionIndex, _metadata);

        return questionId;
    }

    /*//////////////////////////////////////////////////////////////
                             REPORT OUTCOME
    //////////////////////////////////////////////////////////////*/

    /// @notice Report the outcome of a question
    /// @param _questionId - the questionId to report
    /// @param _outcome    - the outcome of the question
    function reportOutcome(bytes32 _questionId, bool _outcome) external {
        _reportOutcome(_questionId, _outcome);

        ctf.reportPayouts(_questionId, Helpers.payouts(_outcome));

        emit OutcomeReported(NegRiskIdLib.getMarketId(_questionId), _questionId, _outcome);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev internal function to avoid stack too deep in convertPositions
    function _splitPosition(bytes32 _conditionId, uint256 _amount) internal {
        ctf.splitPosition(address(wcol), bytes32(0), _conditionId, Helpers.partition(), _amount);
    }

    /// @dev internal function to merge positions and avoid stack too deep
    function _mergePositions(bytes32 _conditionId, uint256 _amount) internal {
        ctf.mergePositions(address(wcol), bytes32(0), _conditionId, Helpers.partition(), _amount);
    }
}
