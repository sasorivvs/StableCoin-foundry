// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    uint256 constant MAX_DEPOSIT_NUMBER = type(uint96).max;
    //address user = makeAddr("user");
    address[] public usersWithCollateralDeposited;
    mapping( address => bool) isDepositor;
    
    uint256 public timesMintIsCalled;

    constructor(DSCEngine _dsce, DecentralizedStableCoin _dsc, HelperConfig _config) {
        dsc = _dsc;
        dsce = _dsce;
        config = _config;
        (,, weth, wbtc,) = config.activeNetworkConfig();
    }

    //redeem collateral

    //call when u have collateral

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        (ERC20Mock collateraltoken) = _getCollateralfromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_NUMBER);
        vm.startPrank(msg.sender);
        collateraltoken.mint(msg.sender, amountCollateral);
        collateraltoken.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateraltoken), amountCollateral);
        vm.stopPrank();

        //double push
        if(isDepositor[msg.sender] == false){
            usersWithCollateralDeposited.push(msg.sender);
            isDepositor[msg.sender] = true;
        }
        
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        (ERC20Mock collateraltoken) = _getCollateralfromSeed(collateralSeed);
        vm.startPrank(msg.sender);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(msg.sender, address(collateraltoken));
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);

        if (amountCollateral == 0) {
            return;
        }
        dsce.redeemCollateral(address(collateraltoken), amountCollateral);
        vm.stopPrank();
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if(usersWithCollateralDeposited.length == 0){
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        vm.startPrank(sender);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);
        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
        
        if (maxDscToMint < 0) {
            return;
        }
        amount = bound(amount, 0, uint256(maxDscToMint));
        
        if (amount == 0) {
            return;
        }
        dsce.mintDsc(amount);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    function _getCollateralfromSeed(uint256 collateral_seed) private view returns (ERC20Mock) {
        ERC20Mock token_to_deposit;

        if (collateral_seed % 2 == 0) {
            token_to_deposit = ERC20Mock(weth);
        } else {
            token_to_deposit = ERC20Mock(wbtc);
        }

        return (token_to_deposit);
    }
}
