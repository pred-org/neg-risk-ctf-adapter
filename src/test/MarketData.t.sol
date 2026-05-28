// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {TestHelper, console} from "src/dev/TestHelper.sol";
import {MarketData, MarketDataLib} from "src/types/MarketData.sol";

contract MarketDataTest is TestHelper {
    using MarketDataLib for MarketData;

    function test_initialize(address _oracle, uint256 _feeBips) public {
        uint256 feeBips = bound(_feeBips, 0, 10_000);
        MarketData md = MarketDataLib.initialize(_oracle, feeBips);

        assertEq(md.oracle(), _oracle);
        assertEq(md.feeBips(), feeBips);
        assertEq(md.questionCount(), 0);
    }

    function test_determine(uint8 _result) public {
        MarketData md = MarketData.wrap(bytes32(0));
        md = md.determine(_result);

        assertEq(md.result(), _result);
        assertEq(md.determined(), true);
    }

    function test_initializeAndDetermine(address _oracle, uint256 _feeBips, uint8 _result) public {
        uint256 feeBips = bound(_feeBips, 0, 10_000);

        MarketData md = MarketDataLib.initialize(_oracle, feeBips);
        md = md.determine(_result);

        assertEq(md.result(), _result);
        assertEq(md.determined(), true);
        assertEq(md.oracle(), _oracle);
        assertEq(md.feeBips(), feeBips);
    }

    function test_questionCount(uint8 _initial) public {
        vm.assume(_initial < 256);
        bytes32 d = bytes32(bytes1(_initial));

        MarketData md = MarketData.wrap(d);

        uint256 index;

        while (index < 10 && _initial + index < 255) {
            md = md.incrementQuestionCount();
            ++index;
            assertEq(md.questionCount(), _initial + index);
        }
    }

    function test_reportedCount_initiallyZero(address _oracle, uint256 _feeBips) public {
        uint256 feeBips = bound(_feeBips, 0, 10_000);
        MarketData md = MarketDataLib.initialize(_oracle, feeBips);
        assertEq(md.reportedCount(), 0);
    }

    function test_incrementReportedCount(uint8 _initial) public {
        vm.assume(_initial < 256);
        // Place _initial at byte 6 of the underlying bytes32.
        bytes32 d = bytes32(bytes1(_initial)) >> 48;
        MarketData md = MarketData.wrap(d);

        uint256 index;
        while (index < 10 && _initial + index < 255) {
            md = md.incrementReportedCount();
            ++index;
            assertEq(md.reportedCount(), _initial + index);
        }
    }

    function test_reportedCount_independentFromQuestionCount(address _oracle, uint256 _feeBips) public {
        uint256 feeBips = bound(_feeBips, 0, 10_000);
        MarketData md = MarketDataLib.initialize(_oracle, feeBips);

        md = md.incrementQuestionCount();
        md = md.incrementQuestionCount();
        md = md.incrementQuestionCount();

        assertEq(md.questionCount(), 3);
        assertEq(md.reportedCount(), 0);

        md = md.incrementReportedCount();

        assertEq(md.questionCount(), 3);
        assertEq(md.reportedCount(), 1);
        assertEq(md.oracle(), _oracle);
        assertEq(md.feeBips(), feeBips);
        assertEq(md.determined(), false);
        assertEq(md.prepared(), false);
    }

    function test_integration(address _oracle, uint256 _feeBips, uint8 _result, uint8 _questionCount) public {
        vm.assume(_questionCount < 255);

        uint256 feeBips = bound(_feeBips, 0, 10_000);

        MarketData md = MarketDataLib.initialize(_oracle, feeBips);

        bytes32 d = MarketData.unwrap(md);
        d |= bytes32(bytes1(_questionCount));

        md = MarketData.wrap(d);

        assertEq(md.result(), 0);
        assertEq(md.determined(), false);
        assertEq(md.oracle(), _oracle);
        assertEq(md.questionCount(), _questionCount);
        assertEq(md.feeBips(), feeBips);

        md = md.incrementQuestionCount();

        assertEq(md.result(), 0);
        assertEq(md.determined(), false);
        assertEq(md.oracle(), _oracle);
        assertEq(md.questionCount(), _questionCount + 1);
        assertEq(md.feeBips(), feeBips);

        md = md.determine(_result);

        assertEq(md.result(), _result);
        assertEq(md.determined(), true);
        assertEq(md.oracle(), _oracle);
        assertEq(md.questionCount(), _questionCount + 1);
        assertEq(md.feeBips(), feeBips);
    }
}
