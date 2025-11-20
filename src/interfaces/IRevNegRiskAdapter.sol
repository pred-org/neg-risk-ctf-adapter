// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {IAuth} from "./IAuth.sol";
import {IConditionalTokens} from "./IConditionalTokens.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {WrappedCollateral} from "src/WrappedCollateral.sol";

interface IRevNegRiskAdapter is IAuth {
    type MarketData is bytes32;

    error InvalidIndexSet();
    error LengthMismatch();
    error UnexpectedCollateralToken();
    error NoConvertiblePositions();
    error NotApprovedForAll();
    error InvalidTargetIndex();
    error IndexOutOfBounds();
    error OnlyOracle();
    error MarketNotPrepared();
    error MarketAlreadyPrepared();
    error MarketAlreadyDetermined();
    error FeeBipsOutOfBounds();

    event MarketPrepared(bytes32 indexed marketId, address indexed oracle, uint256 feeBips, bytes data);
    event QuestionPrepared(bytes32 indexed marketId, bytes32 indexed questionId, uint256 index, bytes data);
    event OutcomeReported(bytes32 indexed marketId, bytes32 indexed questionId, bool outcome);
    event PositionSplit(address indexed stakeholder, bytes32 indexed conditionId, uint256 amount);
    event PositionsMerge(address indexed stakeholder, bytes32 indexed conditionId, uint256 amount);
    event PositionsConverted(
        address indexed stakeholder, bytes32 indexed marketId, uint256 indexed targetIndex, uint256 amount
    );
    event PayoutRedemption(address indexed redeemer, bytes32 indexed conditionId, uint256[] amounts, uint256 payout);

    // Constants
    function getYesTokenBurnAddress() external view returns (address);
    function getFeeDenominator() external view returns (uint256);

    // Immutable state variables
    function ctf() external view returns (IConditionalTokens);
    function col() external view returns (ERC20);
    function wcol() external view returns (WrappedCollateral);
    function vault() external view returns (address);

    // ID functions
    function getConditionId(bytes32 _questionId) external view returns (bytes32);
    function getPositionId(bytes32 _questionId, bool _outcome) external view returns (bytes32);

    // Split position functions
    function splitPosition(address _collateralToken, bytes32, bytes32 _conditionId, uint256[] calldata, uint256 _amount) external;
    function splitPosition(bytes32 _conditionId, uint256 _amount) external;

    // Merge position functions
    function mergePositions(address _collateralToken, bytes32, bytes32 _conditionId, uint256[] calldata, uint256 _amount) external;
    function mergePositions(bytes32 _conditionId, uint256 _amount) external;
    function mergeAllYesTokens(bytes32 _marketId, uint256 _amount) external;
    function mergeAllYesTokens(bytes32 _marketId, uint256 _amount, uint256 _pivotId) external;
    function splitAllYesTokens(bytes32 _marketId, uint256 _amount) external;

    // ERC1155 operations
    function balanceOf(address _owner, uint256 _id) external view returns (uint256);
    function balanceOfBatch(address[] memory _owners, uint256[] memory _ids) external view returns (uint256[] memory);
    function safeTransferFrom(address _from, address _to, uint256 _id, uint256 _value, bytes calldata _data) external;

    // Redeem position function
    function redeemPositions(bytes32 _conditionId, uint256[] calldata _amounts) external;

    // Convert positions function
    function convertPositions(bytes32 _marketId, uint256 _targetIndex, uint256 _amount) external;

    // Market preparation functions
    function prepareMarket(uint256 _feeBips, bytes calldata _metadata) external returns (bytes32);
    function prepareQuestion(bytes32 _marketId, bytes calldata _metadata) external returns (bytes32);

    // Outcome reporting function
    function reportOutcome(bytes32 _questionId, bool _outcome) external;

    // Market state manager functions
    function getMarketData(bytes32 _marketId) external view returns (MarketData);
    function getOracle(bytes32 _marketId) external view returns (address);
    function getQuestionCount(bytes32 _marketId) external view returns (uint256);
    function getDetermined(bytes32 _marketId) external view returns (bool);
    function getResult(bytes32 _marketId) external view returns (uint256);
    function getFeeBips(bytes32 _marketId) external view returns (uint256);
}
