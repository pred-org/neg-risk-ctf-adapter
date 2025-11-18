// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {Script} from "../../lib/forge-std/src/Script.sol";
import {stdStorage, StdStorage} from "../../lib/forge-std/src/StdStorage.sol";
import {Side, Order, SignatureType, Intent} from "../../lib/ctf-exchange/src/exchange/libraries/OrderStructs.sol";

import {vm} from "./libraries/Vm.sol";
import {ICTFExchange} from "../interfaces/index.sol";

using stdStorage for StdStorage;

contract OrderHelper is Script {
    function _createAndSignOrder(
        address _exchange,
        uint256 _pk,
        uint256 _tokenId,
        uint256 _makerAmount,
        uint256 _takerAmount,
        Side _side,
        Intent _intent,
        bytes32 _questionId
    ) internal view returns (Order memory) {
        address maker = vm.addr(_pk);
        Order memory order = _createOrder(maker, _tokenId, _makerAmount, _takerAmount, _side, _intent, _questionId);
        order.signature = _signMessage(_pk, ICTFExchange(_exchange).hashOrder(order));
        return order;
    }

    function _signMessage(uint256 _pk, bytes32 _message) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_pk, _message);
        return abi.encodePacked(r, s, v);
    }

    function _createOrder(address _maker, uint256 _tokenId, uint256 _makerAmount, uint256 _takerAmount, Side _side, Intent _intent, bytes32 _questionId)
        internal
        pure
        returns (Order memory)
    {
        // Calculate price: for BUY orders, price = (takerAmount * ONE_SIX) / makerAmount
        // This ensures that makerAmount = (price * fillAmount) / ONE_SIX
        uint256 price;
        uint256 quantity;
        if (_side == Side.BUY) {
            price = (_makerAmount * 1e6) / _takerAmount;
            quantity = _takerAmount;
        } else {
            price = (_takerAmount * 1e6) / _makerAmount;
            quantity = _makerAmount;
        }
        
        Order memory order = Order({
            salt: 1,
            signer: _maker,
            maker: _maker,
            taker: address(0),
            price: price,
            quantity: quantity, // This should be the amount of tokens to receive
            expiration: 0,
            nonce: 0,
            questionId: _questionId,
            intent: _intent,
            feeRateBps: 0,
            signatureType: SignatureType.EOA,
            signature: new bytes(0)
        });
        return order;
    }
}
