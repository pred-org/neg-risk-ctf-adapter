// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {TestHelper, console} from "src/dev/TestHelper.sol";

import {RevNegRiskAdapter, IRevNegRiskAdapterEE} from "../../RevNegRiskAdapter.sol";
import {WrappedCollateral} from "../../WrappedCollateral.sol";
import {DeployLib} from "../../dev/libraries/DeployLib.sol";
import {USDC} from "../../test/mock/USDC.sol";
import {IConditionalTokens} from "../../interfaces/IConditionalTokens.sol";

contract RevNegRiskAdapter_SetUp is TestHelper, IRevNegRiskAdapterEE {
    RevNegRiskAdapter revAdapter;
    USDC usdc;
    WrappedCollateral wcol;
    IConditionalTokens ctf;
    address oracle;
    address vault;
    address admin;

    uint256 constant FEE_BIPS_MAX = 10_000;

    function setUp() public virtual {
        admin = vm.createWallet("admin").addr;
        vault = vm.createWallet("vault").addr;
        oracle = vm.createWallet("oracle").addr;
        ctf = IConditionalTokens(DeployLib.deployConditionalTokens());
        usdc = new USDC();
        revAdapter = new RevNegRiskAdapter(address(ctf), address(usdc), vault);
        RevNegRiskAdapter(revAdapter).addAdmin(admin);
        RevNegRiskAdapter(revAdapter).renounceAdmin();
        wcol = revAdapter.wcol();
    }
} 