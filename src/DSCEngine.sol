// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import {console} from "forge-std/Test.sol";

/**
 * @title DSCEngine
 * @author Sasorivvs
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Pegged
 * - Dollar Pegged
 * - Algoritmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no pont, should the value of collateral <= the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for minting and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is Very Loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    ///////////////////
    //  Errors       //
    ///////////////////
    error DSCEngine_AmountMustBeMoreThanZero();
    error DSCEngine_TokenIsNotAllowed();
    error DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine_DSCAddressMustBeNonZero();
    error DSCEngine_TransferFailed();
    error DSCEngine_BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine_HealthFactorOK();
    error DSCEngine_HealthFactorNotImporoved();

    /////////////////////////
    //  State variables    //
    /////////////////////////
    uint256 private constant PRECISION = 1e18;
    uint256 private constant DOUBLE_PRECISION = 1e36;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_FACTOR = 75;
    uint256 private constant LIQUIDATION_BONUS = 50;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

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

    ///////////////////
    //  Modifiers    //
    ///////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine_AmountMustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine_TokenIsNotAllowed();
        }
        _;
    }

    ///////////////////
    //  Functions    //
    ///////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        //USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        if (dscAddress == address(0)) {
            revert DSCEngine_DSCAddressMustBeNonZero();
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////
    /// External Functions /////
    ////////////////////////////

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender, true);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param amountDscToMint The amount of dsc to mint
     * @notice they must have more collateral value than minimum theshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine_MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
    }

    /*
     * @param collateral The erc20 collateral address to liquidate from the user
     * @param user The user who have broken the health factor. Their _healthFactor should be bellow MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users funds.
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators.
     * For example, if the price of the collateral plummed before anyone could be liquidated.
     *
     * Follows CEI: Checks, Effects, Interactions
     */
    function liquidate(address user) external nonReentrant {
        // need to check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        uint256 startingLiquidatorHealthFactor = _healthFactor(msg.sender);
        uint256 startingUserCollateralValue = getAccountCollateralValue(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorOK();
        }

        //We want to burn their DSC debt and give a share of the collateral equal to the value of the DSC with which the debt is repaid
        // And give them a 50% of the remaining collateral

        // For example, Bob deposited some ETH and borrowed Y$ DSC. ETH price has dropped, healthFactor has fallen below 1.
        // Now Bob has X$ ETH as collateral and Y$ DSC debt.
        // Alice calls liquidate(), burns Y$ DSC and gets Y$+0.5(X$ - Y$) ETH.
        // The remaining collateral amount is swept into the treasury

        uint256 debtToCover = s_DSCMinted[user];

        address[] memory tokenCollateralAddresses = getAddressesOfUserDepositedCollateral(user);

        if (startingUserHealthFactor > 0.5e18) {
            _redeemBaseCollateralValue(tokenCollateralAddresses, debtToCover, user);
            tokenCollateralAddresses = getAddressesOfUserDepositedCollateral(user);
            uint256 tokenLength = tokenCollateralAddresses.length;
            for (uint256 i = 0; i < tokenLength; i++) {
                address token = tokenCollateralAddresses[i];
                uint256 seizeAmount = s_collateralDeposited[user][token];
                uint256 collateralToRedeem = (seizeAmount * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
                _redeemCollateral(token, collateralToRedeem, user, msg.sender, false);
                s_collateralDeposited[user][token] = 0;
            }
        } else {
            uint256 tokenLength = tokenCollateralAddresses.length;
            for (uint256 i = 0; i < tokenLength; i++) {
                address token = tokenCollateralAddresses[i];
                uint256 seizeAmount = s_collateralDeposited[user][token];
                uint256 collateralToRedeem = seizeAmount;
                _redeemCollateral(token, collateralToRedeem, user, msg.sender, false);
                s_collateralDeposited[user][token] = 0;
            }
        }

        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        uint256 endingLiquidatorHealthFactor = _healthFactor(msg.sender);

        if (
            endingUserHealthFactor <= startingUserHealthFactor
                || endingLiquidatorHealthFactor < startingLiquidatorHealthFactor
        ) {
            revert DSCEngine_HealthFactorNotImporoved();
        }

        emit Liquidated(user, msg.sender, startingUserCollateralValue);

        //_revertIfHealthFactorIsBroken(msg.sender);
    }

    //////////////////////////////////////
    //  Internal & Private Functions    //
    //////////////////////////////////////

    /**
     * @dev low-level internal function, do not call unless the function calling it is checking for health factor being broken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemBaseCollateralValue(address[] memory collaterals, uint256 valueToLiquidate, address user)
        internal
    {
        uint256 remainingAmount = valueToLiquidate;
        uint256 totalTokens = collaterals.length;
        uint256 i;
        uint256 liquidateAmount;
        uint256[] memory usdAmounts = _getUsdValueOfUserDepositedCollaterals(user, collaterals);

        while (remainingAmount != 0 || i < totalTokens) {
            address token = collaterals[i];
            if (remainingAmount >= usdAmounts[i]) {
                liquidateAmount = s_collateralDeposited[user][collaterals[i]];
                _redeemCollateral(collaterals[i], liquidateAmount, user, msg.sender, false);
                remainingAmount -= usdAmounts[i];
            } else {
                liquidateAmount = getTokenAmountFromUsd(token, remainingAmount);
                _redeemCollateral(collaterals[i], liquidateAmount, user, msg.sender, false);
                remainingAmount = 0;
            }
            i++;
        }
    }

    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to,
        bool shouldEmitEvent
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;

        if (shouldEmitEvent) {
            emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        }

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, then he can get liuqidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        uint256 tokenDecimals = uint256(IERC20(token).decimals());
        uint256 powerOfDecimalsPrecision = uint256(i_dsc.decimals()) - tokenDecimals;
        uint256 decimalsPrecision = 10 ** powerOfDecimalsPrecision;

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION * decimalsPrecision) * amount) / PRECISION;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine_BreaksHealthFactor(userHealthFactor);
        }
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }
        uint256 collateralAdjustedForTheshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForTheshold * PRECISION / totalDscMinted);
    }

    function _getCollateralBalanceOfUser(address user, address token) internal view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function _getUsdValueOfUserDepositedCollaterals(address user, address[] memory collaterals)
        internal
        view
        returns (uint256[] memory)
    {
        //address[] memory tokenCollateralAddresses = getAddressesOfUserDepositedCollateral(user);
        uint256[] memory collateralAmounts = new uint256[](collaterals.length);
        for (uint256 i = 0; i < collaterals.length; i++) {
            address token = collaterals[i];
            uint256 amount = s_collateralDeposited[user][token];
            collateralAmounts[i] = _getUsdValue(token, amount);
        }

        return collateralAmounts;
    }

    //////////////////////////////////////////
    //  Public & External view Functions    //
    //////////////////////////////////////////

    function getAddressesOfUserDepositedCollateral(address user) public view returns (address[] memory) {
        uint256 totalCollateralTokens = s_collateralTokens.length;
        address[] memory collateralAddresses = new address[](totalCollateralTokens);
        uint256 count = 0;
        for (uint256 i = 0; i < totalCollateralTokens; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            if (amount != 0) {
                collateralAddresses[i] = token;
                count++;
            }
        }

        // Create result array with only non-zero amounts
        uint256 _count = 0;
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < totalCollateralTokens; i++) {
            if (s_collateralDeposited[user][s_collateralTokens[i]] != 0) {
                result[_count] = collateralAddresses[i];
                _count++;
            }
        }

        return result;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // price of ETH (token)
        //  $/ETH ETH ??
        // $2000 / ETH. $1000 = 0.5 ETH
        uint256 tokenDecimals = uint256(IERC20(token).decimals());
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * 10 ** tokenDecimals) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalCollateralTokens = s_collateralTokens.length;
        uint256 tokenCollateralValueInUsd = 0;
        for (uint256 i = 0; i < totalCollateralTokens; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            tokenCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return tokenCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getAccountInformation(address user)
        public
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return _getCollateralBalanceOfUser(user, token);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        console.log("PERVIY: ", s_collateralTokens[0]);
        console.log("VTOROY: ", s_collateralTokens[1]);
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
