// SPDX-License-Identifier: MIT

// //What are our invariants?

// // 1. The totalSupply of DSC should be less than the total value of collateral

// // 2. Getter view functions should never revert <- evergreen invariant

// pragma solidity ^0.8.18;

// import {Test,console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "../../src/interfaces/IERC20.sol";

// contract OpenInvariants is StdInvariant, Test {
//     DeployDSC deployer;
//     DSCEngine dsce;
//     DecentralizedStableCoin dsc;
//     HelperConfig config;
//     address weth;
//     address wbtc;

//     function setUp() external {
//         deployer = new DeployDSC();
//         (dsc, dsce, config) = deployer.run();
//         (,, weth, wbtc,) = config.activeNetworkConfig();
//         targetContract(address(dsce));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         uint totalSupply = dsc.totalSupply();
//         uint totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
//         uint totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

//         uint wethValue = dsce.getUsdValue(weth, totalWethDeposited);
//         uint wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

//         // console.log("wethValue: ",wethValue);
//         // console.log("wbtcValue: ",wbtcValue);
//         // console.log("totalSupply: ",totalSupply);

//         assert(wethValue + wbtcValue >= totalSupply);
//     }
// }
