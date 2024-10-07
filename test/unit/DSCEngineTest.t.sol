// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransferFromDSC} from "../mocks/MockFailedTransferFromDSC.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    /////////////////
    //  Events     //
    /////////////////
    event CollateralDeposited(
        address indexed depositor, address indexed tokenCollateralAddress, uint256 amountCollateral
    );
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed tokenCollateralAddress,
        uint256 amountCollateral
    );
    event Liquidated(address indexed user, address indexed liquidator, uint256 collateralAmount);

    DSCEngine public dsce;
    DecentralizedStableCoin public dsc;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;

    uint256 amountCollateralWETH = 10 ether; //10weth
    uint256 amountCollateralWBTC = 10e8; // 10wbtc
    uint256 amountToMint = 100 ether;
    uint256 amountToBurn = 10 ether;
    uint256 amountToRedeem = 10 ether;

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant LIQUIDATION_BONUS = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;

    address public user = makeAddr("user");
    address public liquidator = makeAddr("liquidator");

    function setUp() external {
        DeployDSC deployer = new DeployDSC();
        (dsc, dsce, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();

        if (block.chainid == 31_337) {
            vm.deal(user, STARTING_USER_BALANCE);
            vm.deal(liquidator, STARTING_USER_BALANCE);
        }

        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(user, STARTING_USER_BALANCE);

        ERC20Mock(weth).mint(liquidator, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(liquidator, STARTING_USER_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public feedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        feedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
    }

    ///////////////////
    //  Price Tests  //
    ///////////////////

    function test_getUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 btcAmount = 0.5e8;

        // 15e18 ETH * $2000/ETH = $30,000e18
        // 0.5e8 ETH * $60000/BTC = $30,000e18
        uint256 expectedUsd = 30_000e18;

        uint256 usdValueWeth = dsce.getUsdValue(weth, ethAmount);
        uint256 usdValueWbtc = dsce.getUsdValue(wbtc, btcAmount);
        assertEq(usdValueWeth, expectedUsd);
        assertEq(usdValueWbtc, expectedUsd);
    }

    function test_getTokenAmountFromUsd() public view {
        uint256 expectedEthAmount = 15e18;
        uint256 expectedBtcAmount = 0.5e8;

        // 15e18 ETH * $2000/ETH = $30,000e18
        // 0.5e8 ETH * $60000/BTC = $30,000e18
        uint256 usdValue = 30_000e18;

        uint256 usdValueWeth = dsce.getTokenAmountFromUsd(weth, usdValue);
        uint256 usdValueWbtc = dsce.getTokenAmountFromUsd(wbtc, usdValue);
        assertEq(expectedEthAmount, usdValueWeth);
        assertEq(expectedBtcAmount, usdValueWbtc);
    }

    /////////////////////////////////
    //  depositCollateral() Tests  //
    /////////////////////////////////

    function test_RevertsDepositIfTransferFailed() public {
        address owner = address(this);
        MockFailedTransferFrom mockWeth = new MockFailedTransferFrom();
        mockWeth.mint(user, amountCollateralWETH);

        DecentralizedStableCoin _dsc = new DecentralizedStableCoin();
        tokenAddresses = [address(mockWeth), wbtc];
        feedAddresses = [ethUsdPriceFeed, btcUsdPriceFeed];

        vm.prank(owner);
        DSCEngine dscEngine = new DSCEngine(tokenAddresses, feedAddresses, address(_dsc));
        _dsc.transferOwnership(address(dscEngine));

        vm.startPrank(user);
        mockWeth.approve(address(dscEngine), amountCollateralWETH);

        vm.expectRevert(DSCEngine.DSCEngine_TransferFailed.selector);
        dscEngine.depositCollateral(address(mockWeth), amountCollateralWETH);
        vm.stopPrank();
    }

    function test_RevertsIfCollateralZero() public {
        uint256 amount = 0;

        vm.expectRevert(DSCEngine.DSCEngine_AmountMustBeMoreThanZero.selector);
        dsce.depositCollateral(weth, amount);
        vm.expectRevert(DSCEngine.DSCEngine_AmountMustBeMoreThanZero.selector);
        dsce.depositCollateral(wbtc, amount);
    }

    function test_RevertsIfTokenNotAllowed() public {
        uint256 amount = 1e18;
        vm.startPrank(user);
        ERC20Mock randomToken = new ERC20Mock("RNDM", "RNDM", msg.sender, 1e18, 18);
        vm.expectRevert(DSCEngine.DSCEngine_TokenIsNotAllowed.selector);
        dsce.depositCollateral(address(randomToken), amount);
        vm.stopPrank();
    }

    modifier depositedWethCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateralWETH);
        dsce.depositCollateral(weth, amountCollateralWETH);
        vm.stopPrank();
        _;
    }

    modifier depositedWbtcCollateral() {
        vm.startPrank(user);
        ERC20Mock(wbtc).approve(address(dsce), amountCollateralWBTC);
        dsce.depositCollateral(wbtc, amountCollateralWBTC);
        vm.stopPrank();
        _;
    }

    function test_CanDepositCollateralWithoutMinting() public depositedWethCollateral {
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function test_EmitsCollateralDeposited() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateralWETH);

        vm.expectEmit(true, true, false, true, address(dsce));
        emit CollateralDeposited(user, weth, amountCollateralWETH);
        dsce.depositCollateral(weth, amountCollateralWETH);
        vm.stopPrank();
    }

    function test_CanDepositCollateralAndGetAccountInfo() public depositedWethCollateral {
        uint256 expectedDscMinted = 0;
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assert(expectedDscMinted == totalDscMinted);
        assert(expectedDepositAmount == amountCollateralWETH);
    }

    ///////////////////////////////////////////
    //  depositCollateralAndMintDsc() Tests  //
    ///////////////////////////////////////////

    function test_CanDepositAndMintDsc() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateralWETH);
        dsce.depositCollateralAndMintDsc(weth, amountCollateralWETH, amountToMint);
        vm.stopPrank();

        assert(amountToMint == dsc.balanceOf(user));
    }

    function test_DepositAndMintRevertsIfBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        uint8 decimals = ERC20Mock(weth).decimals();

        uint256 _amountToMint = (
            amountCollateralWETH * (10 ** (18 - decimals)) * (uint256(price) * dsce.getAdditionalFeedPrecision())
        ) / dsce.getPrecision();

        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateralWETH);
        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(_amountToMint, dsce.getUsdValue(weth, amountCollateralWETH));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine_BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.depositCollateralAndMintDsc(weth, amountCollateralWETH, _amountToMint);
        vm.stopPrank();
    }

    ////////////////////////
    //  mintDsc() Tests   //
    ////////////////////////

    function test_MintRevertsIfTransferFailed() public {
        address owner = msg.sender;

        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth, wbtc];
        feedAddresses = [ethUsdPriceFeed, btcUsdPriceFeed];

        vm.prank(owner);
        DSCEngine dscEngine = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));

        mockDsc.transferOwnership(address(dscEngine));

        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateralWETH);
        dscEngine.depositCollateral(weth, amountCollateralWETH);

        vm.expectRevert(DSCEngine.DSCEngine_MintFailed.selector);
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function test_DepositCollateralWETHAndMint() public depositedWethCollateral {
        vm.prank(user);
        dsce.mintDsc(amountToMint);

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    function test_DepositCollateralWBTCAndMint() public depositedWbtcCollateral {
        vm.prank(user);
        dsce.mintDsc(amountToMint);
        uint256 expectedWBTCValue = dsce.getTokenAmountFromUsd(wbtc, amountToMint);

        uint256 userBalance = dsc.balanceOf(user);
        uint256 userWBTCBalance = dsce.getTokenAmountFromUsd(wbtc, userBalance);

        assertEq(expectedWBTCValue, userWBTCBalance);
    }

    function test_MintRevertsIfZeroAmount() public depositedWethCollateral {
        vm.prank(user);
        vm.expectRevert(DSCEngine.DSCEngine_AmountMustBeMoreThanZero.selector);
        dsce.mintDsc(0);
    }

    function test_MintRevertsIfBreaksHealthFactorEthCollateral() public depositedWethCollateral {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        uint8 decimals = ERC20Mock(weth).decimals();

        uint256 _amountToMint = (
            amountCollateralWETH * (10 ** (18 - decimals)) * (uint256(price) * dsce.getAdditionalFeedPrecision())
        ) / dsce.getPrecision();

        vm.startPrank(user);
        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(_amountToMint, dsce.getUsdValue(weth, amountCollateralWETH));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine_BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(_amountToMint);
        vm.stopPrank();
    }

    function test_MintRevertsIfBreaksHealthFactorBtcCollateral() public depositedWbtcCollateral {
        (, int256 price,,,) = MockV3Aggregator(btcUsdPriceFeed).latestRoundData();
        uint8 decimals = ERC20Mock(wbtc).decimals();

        uint256 _amountToMint = (
            amountCollateralWBTC * (10 ** (18 - decimals)) * (uint256(price) * dsce.getAdditionalFeedPrecision())
        ) / dsce.getPrecision();

        vm.startPrank(user);
        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(_amountToMint, dsce.getUsdValue(wbtc, amountCollateralWBTC));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine_BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(_amountToMint);
        vm.stopPrank();
    }

    function test_CanMintWithTwoTokensAsCollateral() public {
        vm.startPrank(user);
        ERC20Mock(wbtc).approve(address(dsce), amountCollateralWBTC);
        ERC20Mock(weth).approve(address(dsce), amountCollateralWETH);
        dsce.depositCollateral(wbtc, amountCollateralWBTC);
        dsce.depositCollateral(weth, amountCollateralWETH);

        // This amount cannot be secured by only WETH amountCollateralWETH collateral
        uint256 _amountToMint = dsce.getUsdValue(weth, amountCollateralWETH);
        dsce.mintDsc(_amountToMint);

        vm.stopPrank();
        assert(dsc.balanceOf(user) == _amountToMint);
    }

    ////////////////////////
    //  burnDsc() Tests   //
    ////////////////////////

    function test_BurnRevertsIfZeroAmount() public depositedWethCollateral {
        vm.startPrank(user);
        dsce.mintDsc(amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine_AmountMustBeMoreThanZero.selector);
        dsce.burnDsc(0);
    }

    function test_CanBurn() public depositedWethCollateral {
        vm.startPrank(user);
        dsce.mintDsc(amountToMint);
        uint256 startingBalance = dsc.balanceOf(user);
        dsc.approve(address(dsce), amountToBurn);
        dsce.burnDsc(amountToBurn);
        uint256 endingBalance = dsc.balanceOf(user);
        vm.stopPrank();
        assert(startingBalance - endingBalance == amountToBurn);
    }

    function test_CantBurnMoreThanUserHas() public {
        vm.prank(user);
        vm.expectRevert();
        dsce.burnDsc(1);
    }

    function test_BurnRevertsIfTransferFailed() public {
        address owner = msg.sender;

        MockFailedTransferFromDSC mockDsc = new MockFailedTransferFromDSC();
        tokenAddresses = [weth, wbtc];
        feedAddresses = [ethUsdPriceFeed, btcUsdPriceFeed];

        vm.prank(owner);
        DSCEngine dscEngine = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(dscEngine));

        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateralWETH);
        dscEngine.depositCollateral(weth, amountCollateralWETH);
        dscEngine.mintDsc(amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine_TransferFailed.selector);
        dscEngine.burnDsc(amountToMint);
        vm.stopPrank();
    }

    /////////////////////////////////
    //  redeemCollateral() Tests   //
    /////////////////////////////////

    function test_RedeemCollateralRevertsIfZeroAmount() public depositedWethCollateral depositedWbtcCollateral {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine_AmountMustBeMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);

        vm.expectRevert(DSCEngine.DSCEngine_AmountMustBeMoreThanZero.selector);
        dsce.redeemCollateral(wbtc, 0);
    }

    function test_RedeemCollateralRevertsIfTokenNotAllowed() public {
        uint256 amount = 1e18;
        vm.startPrank(user);
        ERC20Mock randomToken = new ERC20Mock("RNDM", "RNDM", msg.sender, 1e18, 18);
        vm.expectRevert(DSCEngine.DSCEngine_TokenIsNotAllowed.selector);
        dsce.redeemCollateral(address(randomToken), amount);
    }

    function test_CanRedeemCollateralAndEmitEvent() public depositedWethCollateral {
        uint256 startingCollateralAmount = dsce.getCollateralBalanceOfUser(user, weth);
        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(dsce));
        emit CollateralRedeemed(user, user, weth, amountToRedeem);
        dsce.redeemCollateral(weth, amountToRedeem);
        uint256 endingCollateralAmount = dsce.getCollateralBalanceOfUser(user, weth);
        assert(startingCollateralAmount - endingCollateralAmount == amountToRedeem);
    }

    function test_RedeemRevertsIfTransferFailed() public {
        address owner = address(this);
        MockFailedTransfer mockWeth = new MockFailedTransfer();
        mockWeth.mint(user, amountCollateralWETH);

        DecentralizedStableCoin _dsc = new DecentralizedStableCoin();
        tokenAddresses = [address(mockWeth), wbtc];
        feedAddresses = [ethUsdPriceFeed, btcUsdPriceFeed];

        vm.prank(owner);
        DSCEngine dscEngine = new DSCEngine(tokenAddresses, feedAddresses, address(_dsc));
        _dsc.transferOwnership(address(dscEngine));

        vm.startPrank(user);
        mockWeth.approve(address(dscEngine), amountCollateralWETH);
        dscEngine.depositCollateral(address(mockWeth), amountCollateralWETH);

        vm.expectRevert(DSCEngine.DSCEngine_TransferFailed.selector);
        dscEngine.redeemCollateral(address(mockWeth), amountCollateralWETH);
        vm.stopPrank();
    }

    ////////////////////////////////////
    // redeemCollateralForDsc() Tests //
    ////////////////////////////////////
    modifier depositedCollateralWethAndMintedDsc(address depositor) {
        vm.startPrank(depositor);
        ERC20Mock(weth).approve(address(dsce), amountCollateralWETH);
        dsce.depositCollateralAndMintDsc(weth, amountCollateralWETH, amountToMint);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralWbtcAndMintedDsc(address depositor) {
        vm.startPrank(depositor);
        ERC20Mock(wbtc).approve(address(dsce), amountCollateralWBTC);
        dsce.depositCollateralAndMintDsc(wbtc, amountCollateralWBTC, amountToMint);
        vm.stopPrank();
        _;
    }

    function testMustRedeemMoreThanZero() public depositedCollateralWethAndMintedDsc(user) {
        vm.startPrank(user);
        dsc.approve(address(dsce), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine_AmountMustBeMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateralWETH);
        dsce.depositCollateralAndMintDsc(weth, amountCollateralWETH, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.redeemCollateralForDsc(weth, amountCollateralWETH, amountToMint);
        vm.stopPrank();
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralWethAndMintedDsc(user) {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dsce.getHealthFactor(user);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralWethAndMintedDsc(user) {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Rememeber, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dsce.getHealthFactor(user);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    ////////////////////////
    // liquidate() Tests  //
    ////////////////////////

    function test_CanLiquidateSingleCollateral()
        public
        depositedCollateralWethAndMintedDsc(user)
        depositedCollateralWethAndMintedDsc(liquidator)
    {
        int256 ethUsdUpdatedPrice = 150e7;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 wethLiquidatorBalanceBeforeLiquidating = ERC20Mock(weth).balanceOf(liquidator);

        uint256 dscLiquidatorBalanceBeforeLiquidating = dsc.balanceOf(liquidator);
        vm.startPrank(liquidator);
        dsc.approve(address(dsce), amountToMint);

        uint256 valueToLiquidate = dsce.getTokenAmountFromUsd(weth, amountToMint);
        uint256 wethCollateralValue = amountCollateralWETH;
        //uint256 wethBaseCollateralUsdValue = amountToMint;
        uint256 wethBaseCollateralValue = valueToLiquidate;
        uint256 liquidationBonus =
            ((wethCollateralValue - wethBaseCollateralValue) * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        vm.expectEmit(true, true, false, true, address(dsce));
        emit Liquidated(user, liquidator, dsce.getAccountCollateralValue(user));

        dsce.liquidate(user);
        vm.stopPrank();

        uint256 finalHealthFactor = dsce.getHealthFactor(user);

        uint256 wethLiquidatorBalanceAfterLiquidating = ERC20Mock(weth).balanceOf(liquidator);
        uint256 dscLiquidatorBalanceAfterLiquidating = dsc.balanceOf(liquidator);

        assertEq(finalHealthFactor, type(uint256).max);

        assert(
            wethLiquidatorBalanceAfterLiquidating - wethLiquidatorBalanceBeforeLiquidating
                == wethBaseCollateralValue + liquidationBonus
        );

        assert(dscLiquidatorBalanceBeforeLiquidating - dscLiquidatorBalanceAfterLiquidating == amountToMint);
        assert(dsce.getAccountCollateralValue(user) == 0);
    }

    function test_CanLiquidateMultiplyCollateralWBTCCollateralMoreThanWETHCollateral()
        public
        depositedCollateralWethAndMintedDsc(liquidator)
        depositedCollateralWbtcAndMintedDsc(liquidator)
    {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateralWETH);
        ERC20Mock(wbtc).approve(address(dsce), amountCollateralWBTC);
        dsce.depositCollateralAndMintDsc(weth, amountCollateralWETH, amountToMint);
        dsce.depositCollateralAndMintDsc(wbtc, amountCollateralWBTC, amountToMint);
        vm.stopPrank();

        int256 ethUsdUpdatedPrice = 100e4; // 1eth = 0.01$
        int256 btcUsdUpdatedPrice = 250e7; // 1btc = 25$
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(btcUsdUpdatedPrice);

        uint256 wethCollateralUsdValue = dsce.getUsdValue(weth, amountCollateralWETH);
        uint256 wbtcCollateralUsdValue = dsce.getUsdValue(wbtc, amountCollateralWBTC);
        uint256 wbtcBaseCollateralUsdValue = 2 * amountToMint - wethCollateralUsdValue;
        uint256 wbtcBaseCollateralValue = dsce.getTokenAmountFromUsd(wbtc, wbtcBaseCollateralUsdValue);
        uint256 liquidationBonusUsd =
            ((wbtcCollateralUsdValue - wbtcBaseCollateralUsdValue) * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 liquidationBonus = dsce.getTokenAmountFromUsd(wbtc, liquidationBonusUsd);
        uint256 wethLiquidationAmount = amountCollateralWETH;

        uint256 wethLiquidatorBalanceBeforeLiquidating = ERC20Mock(weth).balanceOf(liquidator);
        uint256 wbtcLiquidatorBalanceBeforeLiquidating = ERC20Mock(wbtc).balanceOf(liquidator);
        uint256 dscLiquidatorBalanceBeforeLiquidating = dsc.balanceOf(liquidator);
        vm.startPrank(liquidator);
        dsc.approve(address(dsce), 2 * amountToMint);

        vm.expectEmit(true, true, false, true, address(dsce));
        emit Liquidated(user, liquidator, dsce.getAccountCollateralValue(user));

        dsce.liquidate(user);
        vm.stopPrank();

        uint256 finalHealthFactor = dsce.getHealthFactor(user);

        uint256 wethLiquidatorBalanceAfterLiquidating = ERC20Mock(weth).balanceOf(liquidator);
        uint256 dscLiquidatorBalanceAfterLiquidating = dsc.balanceOf(liquidator);
        uint256 wbtcLiquidatorBalanceAfterLiquidating = ERC20Mock(wbtc).balanceOf(liquidator);
        uint256 wethBalanceChangingInUsd =
            dsce.getUsdValue(weth, wethLiquidatorBalanceAfterLiquidating - wethLiquidatorBalanceBeforeLiquidating);
        uint256 wbtcBalanceChangingInUsd =
            dsce.getUsdValue(wbtc, wbtcLiquidatorBalanceAfterLiquidating - wbtcLiquidatorBalanceBeforeLiquidating);

        uint256 endingDSCEngineBalanceWeth = ERC20Mock(weth).balanceOf(address(dsce));
        //uint256 endingDSCEngineBalanceWbtc = ERC20Mock(wbtc).balanceOf(address(dsce));

        assert(finalHealthFactor == type(uint256).max);
        assert(wethLiquidatorBalanceAfterLiquidating - wethLiquidatorBalanceBeforeLiquidating == amountCollateralWETH);
        assert(
            wbtcLiquidatorBalanceAfterLiquidating - wbtcLiquidatorBalanceBeforeLiquidating
                == liquidationBonus + wbtcBaseCollateralValue
        );
        assert(2 * amountCollateralWETH - endingDSCEngineBalanceWeth == wethLiquidationAmount);
        assert(dsce.getAccountCollateralValue(user) == 0);

        console.log(
            "Profit: ",
            wethBalanceChangingInUsd + wbtcBalanceChangingInUsd
                - (dscLiquidatorBalanceBeforeLiquidating - dscLiquidatorBalanceAfterLiquidating)
        );
        console.log(
            "Relative Profit: ",
            (
                (
                    wethBalanceChangingInUsd + wbtcBalanceChangingInUsd
                        - (dscLiquidatorBalanceBeforeLiquidating - dscLiquidatorBalanceAfterLiquidating)
                ) * 1e18
            ) / (dscLiquidatorBalanceBeforeLiquidating - dscLiquidatorBalanceAfterLiquidating)
        );
    }

    function test_CanLiquidateMultiplyCollateralWETHCollateralMoreThanWBTCCollateral()
        public
        depositedCollateralWethAndMintedDsc(liquidator)
        depositedCollateralWbtcAndMintedDsc(liquidator)
    {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateralWETH);
        ERC20Mock(wbtc).approve(address(dsce), amountCollateralWBTC);
        dsce.depositCollateralAndMintDsc(weth, amountCollateralWETH, amountToMint);
        dsce.depositCollateralAndMintDsc(wbtc, amountCollateralWBTC, amountToMint);
        vm.stopPrank();

        int256 ethUsdUpdatedPrice = 25e8; // 1eth = 25$ 10eth=250$
        int256 btcUsdUpdatedPrice = 5e8; // 1btc = 5$ 10btc=50$
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(btcUsdUpdatedPrice);

        uint256 wethCollateralUsdValue = dsce.getUsdValue(weth, amountCollateralWETH);
        uint256 wbtcCollateralUsdValue = dsce.getUsdValue(wbtc, amountCollateralWBTC);
        uint256 wethBaseCollateralUsdValue = 2 * amountToMint;
        //uint256 wbtcBaseCollateralUsdValue = 2 * amountToMint - wethBaseCollateralUsdValue;
        uint256 wethBaseCollateralValue = dsce.getTokenAmountFromUsd(weth, wethBaseCollateralUsdValue);
        uint256 liquidationBonusUsdWeth =
            ((wethCollateralUsdValue - wethBaseCollateralUsdValue) * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 liquidationBonusUsdWbtc = (wbtcCollateralUsdValue * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 liquidationBonusWeth = dsce.getTokenAmountFromUsd(weth, liquidationBonusUsdWeth);
        uint256 liquidationBonusWbtc = dsce.getTokenAmountFromUsd(wbtc, liquidationBonusUsdWbtc);
        uint256 wethLiquidationAmount = liquidationBonusWeth + wethBaseCollateralValue;

        uint256 wethLiquidatorBalanceBeforeLiquidating = ERC20Mock(weth).balanceOf(liquidator);
        uint256 wbtcLiquidatorBalanceBeforeLiquidating = ERC20Mock(wbtc).balanceOf(liquidator);
        //uint256 dscLiquidatorBalanceBeforeLiquidating = dsc.balanceOf(liquidator);
        vm.startPrank(liquidator);
        dsc.approve(address(dsce), 2 * amountToMint);

        vm.expectEmit(true, true, false, true, address(dsce));
        emit Liquidated(user, liquidator, dsce.getAccountCollateralValue(user));

        dsce.liquidate(user);
        vm.stopPrank();

        uint256 finalHealthFactor = dsce.getHealthFactor(user);

        uint256 wethLiquidatorBalanceAfterLiquidating = ERC20Mock(weth).balanceOf(liquidator);
        //uint256 dscLiquidatorBalanceAfterLiquidating = dsc.balanceOf(liquidator);
        uint256 wbtcLiquidatorBalanceAfterLiquidating = ERC20Mock(wbtc).balanceOf(liquidator);
        //uint256 wethBalanceChangingInUsd = dsce.getUsdValue(weth, wethLiquidatorBalanceAfterLiquidating - wethLiquidatorBalanceBeforeLiquidating);
        //uint256 wbtcBalanceChangingInUsd = dsce.getUsdValue(wbtc, wbtcLiquidatorBalanceAfterLiquidating - wbtcLiquidatorBalanceBeforeLiquidating);

        //uint256 endingDSCEngineBalanceWeth = ERC20Mock(weth).balanceOf(address(dsce));
        //uint256 endingDSCEngineBalanceWbtc = ERC20Mock(wbtc).balanceOf(address(dsce));

        assert(finalHealthFactor == type(uint256).max);
        assert(wbtcLiquidatorBalanceAfterLiquidating - wbtcLiquidatorBalanceBeforeLiquidating == liquidationBonusWbtc);
        assert(wethLiquidatorBalanceAfterLiquidating - wethLiquidatorBalanceBeforeLiquidating == wethLiquidationAmount);
    }

    function test_RevertsLiquidateIfHealthFactorIsOk()
        public
        depositedCollateralWethAndMintedDsc(user)
        depositedCollateralWethAndMintedDsc(liquidator)
    {
        int256 ethUsdUpdatedPrice = 1000e8;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        //uint256 wethLiquidatorBalanceBeforeLiquidating = ERC20Mock(weth).balanceOf(liquidator);

        //uint256 dscLiquidatorBalanceBeforeLiquidating = dsc.balanceOf(liquidator);
        vm.startPrank(liquidator);
        dsc.approve(address(dsce), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine_HealthFactorOK.selector);

        dsce.liquidate(user);
        vm.stopPrank();
    }

    function test_CanLiquidateIfHealthFactorUnder50Percents()
        public
        depositedCollateralWethAndMintedDsc(user)
        depositedCollateralWethAndMintedDsc(liquidator)
    {
        int256 ethUsdUpdatedPrice = 90e7;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        //(uint256 totalDSCMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);

        uint256 wethLiquidatorBalanceBeforeLiquidating = ERC20Mock(weth).balanceOf(liquidator);

        uint256 dscLiquidatorBalanceBeforeLiquidating = dsc.balanceOf(liquidator);
        vm.startPrank(liquidator);
        dsc.approve(address(dsce), amountToMint);

        vm.expectEmit(true, true, false, true, address(dsce));
        emit Liquidated(user, liquidator, dsce.getAccountCollateralValue(user));

        dsce.liquidate(user);
        vm.stopPrank();

        uint256 finalHealthFactor = dsce.getHealthFactor(user);

        uint256 wethLiquidatorBalanceAfterLiquidating = ERC20Mock(weth).balanceOf(liquidator);
        uint256 dscLiquidatorBalanceAfterLiquidating = dsc.balanceOf(liquidator);
        //uint256 wethBalanceChangingInUsd = dsce.getUsdValue(weth, wethLiquidatorBalanceAfterLiquidating - wethLiquidatorBalanceBeforeLiquidating);

        assert(finalHealthFactor == type(uint256).max);
        assert(wethLiquidatorBalanceAfterLiquidating - wethLiquidatorBalanceBeforeLiquidating == amountCollateralWETH);
        assert(dscLiquidatorBalanceBeforeLiquidating - dscLiquidatorBalanceAfterLiquidating == amountToMint);
    }

    function test_CanLiquidateIfHealthFactorIs50Percents()
        public
        depositedCollateralWethAndMintedDsc(user)
        depositedCollateralWethAndMintedDsc(liquidator)
    {
        int256 ethUsdUpdatedPrice = 10e8;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 wethLiquidatorBalanceBeforeLiquidating = ERC20Mock(weth).balanceOf(liquidator);

        uint256 dscLiquidatorBalanceBeforeLiquidating = dsc.balanceOf(liquidator);
        vm.startPrank(liquidator);
        dsc.approve(address(dsce), amountToMint);

        vm.expectEmit(true, true, false, true, address(dsce));
        emit Liquidated(user, liquidator, dsce.getAccountCollateralValue(user));

        dsce.liquidate(user);
        vm.stopPrank();

        uint256 finalHealthFactor = dsce.getHealthFactor(user);

        uint256 wethLiquidatorBalanceAfterLiquidating = ERC20Mock(weth).balanceOf(liquidator);
        uint256 dscLiquidatorBalanceAfterLiquidating = dsc.balanceOf(liquidator);
        uint256 wethBalanceChangingInUsd =
            dsce.getUsdValue(weth, wethLiquidatorBalanceAfterLiquidating - wethLiquidatorBalanceBeforeLiquidating);

        assert(finalHealthFactor == type(uint256).max);
        assert(wethLiquidatorBalanceAfterLiquidating - wethLiquidatorBalanceBeforeLiquidating == amountCollateralWETH);
        assert(wethBalanceChangingInUsd == amountToMint);
        assert(dscLiquidatorBalanceBeforeLiquidating - dscLiquidatorBalanceAfterLiquidating == amountToMint);
    }
}

// uint256 amountCollateralWETH = 10 ether;
// uint256 amountCollateralWBTC = 10e8;
// uint256 amountToMint = 100 ether;
// uint256 amountToBurn = 10 ether;
// uint256 amountToRedeem = 10 ether;
