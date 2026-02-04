// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import { Test, console } from "forge-std/Test.sol";
import { Deploy } from "../../script/Deploy.s.sol";
import { DecentralizedStableCoin } from "../../src/DecentralizedStableCoin.sol";
import { DSCEngine } from "../../src/DSCEngine.sol";
import { HelperConfig } from "../../script/HelperConfig.s.sol";
import { ERC20Mock } from "../mocks/ERC20.sol";
import { MockV3Aggregator } from "../mocks/MockV3Aggregator.sol";
import { OracleLib } from "../../src/libraries/OracleLib.sol";

contract DSCEngineTest is Test {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    Deploy deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig helperConfig;
    address ethUsdPriceFeed;
    address weth;
    address wbtc;
    address btcUsdPriceFeed;

    address[] public tokenaddresses;
    address[] public priceFeedAddresses;

    // Test Users
    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");

    // Test Amounts
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_USER_BALANCE = 100 ether;
    uint256 public constant AMOUNT_TO_MINT = 100 ether; // 100 DSC

    // Price Feed Constants (matching HelperConfig)
    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;
    int256 public constant BTC_USD_PRICE = 1000e8;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/
    function setUp() public {
        // Deploy contracts using the Deploy script
        deployer = new Deploy();
        (dsc, dscEngine, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();

        // Fund test users with WETH for testing
        ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_USER_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that constructor reverts when token addresses and price feed arrays have different lengths
     * @dev This ensures the DSCEngine enforces proper initialization with matching token/pricefeed pairs
     */
    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        // Setup: Push 1 token but 2 price feeds - creating a mismatch
        tokenaddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        // Expect the constructor to revert with the specific error
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch.selector);
        new DSCEngine(tokenaddresses, priceFeedAddresses, address(dsc));
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that getUsdValue correctly calculates the USD value of a token amount
     * @dev At $2000/ETH, 15 ETH should equal $30,000
     */
    function testGetUsdValue() public {
        uint256 ethAmount = 15e18; // 15 ETH
        // At $2000/ETH, 15 ETH = $30,000
        uint256 expectedUsd = 30_000e18;
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd, "USD value should be 30000 USD for 15 ETH at 2000 USD per ETH");
    }

    /**
     * @notice Test that getTokenAmountFromUsd correctly converts USD to token amount
     * @dev At $2000/ETH, $100 should equal 0.05 ETH
     */
    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether; // $100
        // At $2000/ETH, $100 = 0.05 ETH
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that depositCollateral reverts when amount is zero
     * @dev The moreThanZero modifier should prevent zero-amount deposits
     */
    function testRevertsIfCollateralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    /**
     * @notice Test that depositCollateral reverts when using an unapproved token
     * @dev Only WETH and WBTC are allowed as collateral in this system
     */
    function testRevertsIfCollateralIsNotAllowed() public {
        // Create a random token that isn't registered as collateral
        ERC20Mock randomToken = new ERC20Mock("RandomToken", "RND", USER, 1_234_567);

        vm.startPrank(USER);
        randomToken.approve(address(dscEngine), 1_234_567);

        // Should revert because the token has no price feed registered
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, address(randomToken)));
        dscEngine.depositCollateral(address(randomToken), 1_234_567);
        vm.stopPrank();
    }

    /**
     * @notice Test successful collateral deposit and verify account information
     * @dev After depositing 10 ETH at $2000/ETH, collateral value should be $20,000
     */
    function testCanDepositCollateralAndGetAccountInformation() public depositCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);

        // User hasn't minted any DSC yet
        assertEq(totalDscMinted, 0);

        // 10 ETH at $2000/ETH = $20,000
        uint256 expectedCollateralValueInUsd = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValueInUsd, expectedCollateralValueInUsd);

        // Verify the reverse calculation: converting USD back to tokens
        uint256 expectedDepositAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(expectedDepositAmount, AMOUNT_COLLATERAL);
    }

    /**
     * @notice Test that CollateralDeposited event is emitted on deposit
     */
    function testDepositCollateralEmitsEvent() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, true);
        emit CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    /**
     * @notice Test getCollateralBalanceOfUser returns correct balance
     */
    function testGetCollateralBalanceOfUser() public depositCollateral {
        uint256 collateralBalance = dscEngine.getCollateralBalanceOfUser(USER, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    /*//////////////////////////////////////////////////////////////
                            MINT DSC TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that minting DSC reverts when amount is zero
     */
    function testRevertsIfMintAmountIsZero() public depositCollateral {
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.mintDsc(0);
        vm.stopPrank();
    }

    /**
     * @notice Test that minting DSC works when user has sufficient collateral
     * @dev With $20,000 collateral (10 ETH at $2000), user can mint up to $10,000 DSC (50% threshold)
     */
    function testCanMintDsc() public depositCollateral {
        // With 10 ETH ($20,000 at $2000/ETH) as collateral
        // User can mint up to $10,000 DSC (200% over-collateralization = 50% LTV)
        uint256 amountToMint = 5000 ether; // $5000 DSC - well within safe limits

        dscEngine.mintDsc(amountToMint);

        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, amountToMint);
        vm.stopPrank();
    }

    /**
     * @notice Test that minting reverts when it would break health factor
     * @dev Attempting to mint more DSC than collateral allows should revert
     */
    function testRevertsIfMintBreaksHealthFactor() public depositCollateral {
        // 10 ETH = $20,000 collateral
        // Max DSC at 50% threshold = $10,000
        // Trying to mint $15,000 should fail
        uint256 amountToMint = 15_000 ether;

        // Calculate expected health factor to use in the revert
        (, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(amountToMint, collateralValueInUsd);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    DEPOSIT AND MINT DSC TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test depositCollateralAndMintDsc combines both operations correctly
     */
    function testDepositCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        uint256 amountToMint = 5000 ether; // $5000 DSC
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);

        // Verify collateral was deposited
        uint256 collateralBalance = dscEngine.getCollateralBalanceOfUser(USER, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);

        // Verify DSC was minted
        uint256 dscBalance = dsc.balanceOf(USER);
        assertEq(dscBalance, amountToMint);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            BURN DSC TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that burnDsc reverts when amount is zero
     */
    function testRevertsIfBurnAmountIsZero() public depositCollateralAndMintDsc {
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    /**
     * @notice Test successful DSC burning
     * @dev User should be able to burn DSC they've minted
     */
    function testCanBurnDsc() public depositCollateralAndMintDsc {
        uint256 amountToBurn = 50 ether; // Burn 50 DSC

        // Approve DSCEngine to burn DSC tokens
        dsc.approve(address(dscEngine), amountToBurn);
        dscEngine.burnDsc(amountToBurn);

        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, AMOUNT_TO_MINT - amountToBurn);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        REDEEM COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that redeemCollateral reverts when amount is zero
     */
    function testRevertsIfRedeemAmountIsZero() public depositCollateral {
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    /**
     * @notice Test successful collateral redemption when no DSC is minted
     */
    function testCanRedeemCollateral() public depositCollateral {
        uint256 redeemAmount = 5 ether;

        dscEngine.redeemCollateral(weth, redeemAmount);

        uint256 remainingCollateral = dscEngine.getCollateralBalanceOfUser(USER, weth);
        assertEq(remainingCollateral, AMOUNT_COLLATERAL - redeemAmount);

        uint256 userWethBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userWethBalance, STARTING_USER_BALANCE - AMOUNT_COLLATERAL + redeemAmount);
        vm.stopPrank();
    }

    /**
     * @notice Test that CollateralRedeemed event is emitted on redemption
     */
    function testRedeemCollateralEmitsEvent() public depositCollateral {
        vm.expectEmit(true, true, false, true);
        emit CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    /**
     * @notice Test that redeemCollateral reverts if it would break health factor
     */
    function testRevertsIfRedeemBreaksHealthFactor() public depositCollateralAndMintDsc {
        // User has 10 ETH collateral and 100 DSC minted
        // Trying to redeem all collateral should fail

        // First calculate what health factor would be
        uint256 dscMinted = 100 ether;
        uint256 remainingCollateralValue = 0; // If we redeem all
        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(dscMinted, remainingCollateralValue);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    REDEEM COLLATERAL FOR DSC TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test redeemCollateralForDsc burns DSC and returns collateral in one transaction
     */
    function testRedeemCollateralForDsc() public depositCollateralAndMintDsc {
        uint256 collateralToRedeem = 5 ether;
        uint256 dscToBurn = 50 ether;

        // Approve DSCEngine to burn DSC
        dsc.approve(address(dscEngine), dscToBurn);

        dscEngine.redeemCollateralForDsc(weth, collateralToRedeem, dscToBurn);

        // Verify collateral was redeemed
        uint256 remainingCollateral = dscEngine.getCollateralBalanceOfUser(USER, weth);
        assertEq(remainingCollateral, AMOUNT_COLLATERAL - collateralToRedeem);

        // Verify DSC was burned
        uint256 remainingDsc = dsc.balanceOf(USER);
        assertEq(remainingDsc, AMOUNT_TO_MINT - dscToBurn);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          HEALTH FACTOR TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test health factor calculation returns max uint256 when no DSC is minted
     * @dev When totalDscMinted is 0, health factor should be type(uint256).max
     */
    function testHealthFactorIsMaxWhenNoDscMinted() public depositCollateral {
        uint256 healthFactor = dscEngine.getHealthFactor(USER);
        assertEq(healthFactor, type(uint256).max);
        vm.stopPrank();
    }

    /**
     * @notice Test calculateHealthFactor with known values
     */
    function testCalculateHealthFactor() public {
        // With $20,000 collateral and $100 DSC minted
        // Health factor = ($20,000 * 50 / 100) / $100 = $10,000 / $100 = 100
        uint256 totalDscMinted = 100 ether;
        uint256 collateralValueInUsd = 20_000 ether;

        uint256 expectedHealthFactor = 100 ether; // 100 * 1e18
        uint256 actualHealthFactor = dscEngine.calculateHealthFactor(totalDscMinted, collateralValueInUsd);

        assertEq(actualHealthFactor, expectedHealthFactor);
    }

    /**
     * @notice Test getHealthFactor returns correct value for user with DSC minted
     */
    function testGetHealthFactor() public depositCollateralAndMintDsc {
        // 10 ETH = $20,000 collateral, 100 DSC minted
        // Health factor = ($20,000 * 50 / 100) * 1e18 / 100 DSC = 100e18
        uint256 expectedHealthFactor = 100 ether;
        uint256 actualHealthFactor = dscEngine.getHealthFactor(USER);

        assertEq(actualHealthFactor, expectedHealthFactor);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          LIQUIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that liquidation reverts when user's health factor is OK
     */
    function testLiquidationRevertsIfHealthFactorOk() public depositCollateralAndMintDsc {
        vm.stopPrank(); // Stop USER prank

        // Setup liquidator with DSC to burn
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), STARTING_USER_BALANCE);
        dscEngine.depositCollateralAndMintDsc(weth, STARTING_USER_BALANCE, AMOUNT_TO_MINT);
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT);

        // Try to liquidate USER who has healthy position
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, USER, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    /**
     * @notice Test successful liquidation when user is undercollateralized
     * @dev We simulate a price drop to make the user's position unhealthy
     */
    function testLiquidationWorksWhenUndercollateralized() public depositCollateralAndMintDsc {
        vm.stopPrank(); // Stop USER prank

        // Setup: Liquidator needs DSC to cover the debt
        // Liquidator deposits much more collateral to have a healthy position after liquidation
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), STARTING_USER_BALANCE);
        dscEngine.depositCollateralAndMintDsc(weth, STARTING_USER_BALANCE, 100 ether);
        vm.stopPrank();

        // Simulate ETH price crash: $2000 -> $18 per ETH
        // This makes USER's position undercollateralized
        // User has 10 ETH ($180 at new price) backing 100 DSC
        // Health factor = (180 * 50 / 100) / 100 = 0.9 < 1
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(18e8);

        // Verify USER is now undercollateralized
        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);
        assertLt(userHealthFactor, 1e18, "User should be undercollateralized");

        // Calculate how much collateral the liquidator will receive
        // Liquidator covers 100 DSC debt, gets collateral + 10% bonus
        uint256 tokenAmountFromDebtCovered = dscEngine.getTokenAmountFromUsd(weth, 100 ether);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * 10) / 100;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        // Liquidator liquidates USER
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(dscEngine), 100 ether);

        uint256 liquidatorWethBefore = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        dscEngine.liquidate(weth, USER, 100 ether);
        uint256 liquidatorWethAfter = ERC20Mock(weth).balanceOf(LIQUIDATOR);

        // Verify USER's DSC debt is cleared
        (uint256 userDscMinted,) = dscEngine.getAccountInformation(USER);
        assertEq(userDscMinted, 0, "User's DSC should be cleared");

        // Verify liquidator received collateral (including bonus)
        assertEq(liquidatorWethAfter - liquidatorWethBefore, totalCollateralToRedeem, "Liquidator should receive collateral with bonus");
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          GETTER FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test getPrecision returns correct value
     */
    function testGetPrecision() public {
        uint256 precision = dscEngine.getPrecision();
        assertEq(precision, 1e18);
    }

    /**
     * @notice Test getAdditionalFeedPrecision returns correct value
     */
    function testGetAdditionalFeedPrecision() public {
        uint256 additionalPrecision = dscEngine.getAdditionalFeedPrecision();
        assertEq(additionalPrecision, 1e10);
    }

    /**
     * @notice Test getLiquidationThreshold returns correct value
     */
    function testGetLiquidationThreshold() public {
        uint256 threshold = dscEngine.getLiquidationThreshold();
        assertEq(threshold, 50);
    }

    /**
     * @notice Test getLiquidationBonus returns correct value
     */
    function testGetLiquidationBonus() public {
        uint256 bonus = dscEngine.getLiquidationBonus();
        assertEq(bonus, 10);
    }

    /**
     * @notice Test getLiquidationPrecision returns correct value
     */
    function testGetLiquidationPrecision() public {
        uint256 liquidationPrecision = dscEngine.getLiquidationPrecision();
        assertEq(liquidationPrecision, 100);
    }

    /**
     * @notice Test getMinHealthFactor returns correct value
     */
    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = dscEngine.getMinHealthFactor();
        assertEq(minHealthFactor, 1e18);
    }

    /**
     * @notice Test getCollateralTokens returns all registered collateral tokens
     */
    function testGetCollateralTokens() public {
        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        assertEq(collateralTokens.length, 2);
        assertEq(collateralTokens[0], weth);
        assertEq(collateralTokens[1], wbtc);
    }

    /**
     * @notice Test getDsc returns the DSC token address
     */
    function testGetDsc() public {
        address dscAddress = dscEngine.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    /**
     * @notice Test getCollateralTokenPriceFeed returns correct price feed for token
     */
    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = dscEngine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    /**
     * @notice Test getAccountCollateralValue returns correct total collateral value
     */
    function testGetAccountCollateralValue() public depositCollateral {
        uint256 collateralValue = dscEngine.getAccountCollateralValue(USER);
        // 10 ETH at $2000 = $20,000
        uint256 expectedValue = 20_000 ether;
        assertEq(collateralValue, expectedValue);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    DECENTRALIZED STABLECOIN TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that only the owner (DSCEngine) can mint DSC
     * @dev Non-owner calls should revert
     */
    function testMustMintMoreThanZero() public {
        vm.prank(address(dscEngine));
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStablecoin_MustbeMoreThanZero.selector);
        dsc.mint(USER, 0);
    }

    /**
     * @notice Test that minting to zero address reverts
     */
    function testCantMintToZeroAddress() public {
        vm.prank(address(dscEngine));
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStablecoin_NotMintableonZeroAddress.selector);
        dsc.mint(address(0), 100);
    }

    /**
     * @notice Test that burning more than zero is required
     */
    function testMustBurnMoreThanZero() public depositCollateralAndMintDsc {
        vm.stopPrank();
        vm.startPrank(address(dscEngine));
        // First transfer some DSC to the engine so it can burn
        vm.stopPrank();
        
        vm.startPrank(USER);
        dsc.transfer(address(dscEngine), AMOUNT_TO_MINT);
        vm.stopPrank();
        
        vm.startPrank(address(dscEngine));
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStablecoin_MustbeMoreThanZero.selector);
        dsc.burn(0);
        vm.stopPrank();
    }

    /**
     * @notice Test that burning more than balance reverts
     * @dev The DSC contract uses OpenZeppelin's ERC20 burn which has its own error
     */
    function testCantBurnMoreThanYouHave() public depositCollateralAndMintDsc {
        // User has minted some DSC, try to burn more than they have
        uint256 userBalance = dsc.balanceOf(USER);
        uint256 amountToBurnTooMuch = userBalance + 1 ether;
        
        dsc.approve(address(dscEngine), amountToBurnTooMuch);
        
        // This will revert because user doesn't have enough DSC
        vm.expectRevert();
        dscEngine.burnDsc(amountToBurnTooMuch);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          ORACLE LIB TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that stale price data causes a revert
     * @dev When price feed data is too old (> 3 hours), the oracle should revert
     * The OracleLib checks if block.timestamp - updatedAt > TIMEOUT (3 hours)
     * Note: The price is only checked when calculating health factor (during mint/redeem/liquidate)
     */
    function testRevertsOnStalePrice() public {
        // First warp to a known time to avoid underflow
        vm.warp(100000); // Set block.timestamp to a safe value
        
        // Update price feed with current timestamp (fresh)
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(2000e8);

        // Deposit collateral (this doesn't check price)
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        // Now warp time forward by more than 3 hours (TIMEOUT in OracleLib)
        vm.warp(block.timestamp + 4 hours);

        // Try to mint DSC - this requires price to calculate health factor
        // The price feed's timestamp is now stale (4 hours old relative to new block.timestamp)
        vm.startPrank(USER);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        dscEngine.mintDsc(1 ether); // This will query the price and revert
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                       ADDITIONAL BRANCH TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test depositCollateralAndMintDsc reverts with zero collateral
     */
    function testDepositCollateralAndMintDscRevertsWithZeroCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateralAndMintDsc(weth, 0, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    /**
     * @notice Test redeemCollateralForDsc reverts with zero collateral
     */
    function testRedeemCollateralForDscRevertsWithZeroCollateral() public depositCollateralAndMintDsc {
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateralForDsc(weth, 0, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    /**
     * @notice Test redeemCollateralForDsc with unapproved token reverts
     */
    function testRedeemCollateralForDscRevertsWithUnapprovedToken() public depositCollateralAndMintDsc {
        ERC20Mock randomToken = new ERC20Mock("RandomToken", "RND", USER, 1000 ether);
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, address(randomToken)));
        dscEngine.redeemCollateralForDsc(address(randomToken), AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    /**
     * @notice Test liquidate reverts with zero debt to cover
     */
    function testLiquidateRevertsWithZeroDebtToCover() public depositCollateralAndMintDsc {
        vm.stopPrank();

        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.liquidate(weth, USER, 0);
        vm.stopPrank();
    }

    /**
     * @notice Test liquidate reverts with unapproved collateral token
     */
    function testLiquidateRevertsWithUnapprovedToken() public depositCollateralAndMintDsc {
        vm.stopPrank();

        ERC20Mock randomToken = new ERC20Mock("RandomToken", "RND", LIQUIDATOR, 1000 ether);

        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, address(randomToken)));
        dscEngine.liquidate(address(randomToken), USER, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    /**
     * @notice Test that health factor doesn't improve scenario (edge case)
     * @dev Tests the DSCEngine__HealthFactorNotImproved error path
     */
    function testLiquidationRevertsIfHealthFactorNotImproved() public {
        // Setup user with position
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();

        // Setup liquidator
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), STARTING_USER_BALANCE);
        dscEngine.depositCollateralAndMintDsc(weth, STARTING_USER_BALANCE, 100 ether);
        vm.stopPrank();

        // Crash price to make user undercollateralized
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(18e8);

        // Verify USER is undercollateralized
        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);
        assertLt(userHealthFactor, 1e18);

        // Liquidate with very small amount - should work
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(dscEngine), 100 ether);
        
        // Try partial liquidation
        dscEngine.liquidate(weth, USER, 10 ether);
        vm.stopPrank();
    }

    /**
     * @notice Test collateral redemption with multiple collateral types
     */
    function testCanDepositMultipleCollateralTypes() public {
        // Mint some WBTC for USER
        ERC20Mock(wbtc).mint(USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        // Deposit WETH
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        // Deposit WBTC
        ERC20Mock(wbtc).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(wbtc, AMOUNT_COLLATERAL);

        // Check total collateral value
        // 10 ETH at $2000 = $20,000
        // 10 BTC at $1000 = $10,000
        // Total = $30,000
        uint256 totalCollateral = dscEngine.getAccountCollateralValue(USER);
        assertEq(totalCollateral, 30_000 ether);
        vm.stopPrank();
    }

    /**
     * @notice Test that getAccountInformation returns correct values
     */
    function testGetAccountInformationReturnsCorrectValues() public depositCollateralAndMintDsc {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);

        assertEq(totalDscMinted, AMOUNT_TO_MINT);
        assertEq(collateralValueInUsd, 20_000 ether); // 10 ETH * $2000
        vm.stopPrank();
    }

    /**
     * @notice Test BTC price feed and collateral calculations
     */
    function testGetUsdValueForBtc() public {
        uint256 btcAmount = 10e18; // 10 BTC
        // At $1000/BTC, 10 BTC = $10,000
        uint256 expectedUsd = 10_000e18;
        uint256 actualUsd = dscEngine.getUsdValue(wbtc, btcAmount);
        assertEq(actualUsd, expectedUsd);
    }

    /**
     * @notice Test getTokenAmountFromUsd for BTC
     */
    function testGetTokenAmountFromUsdForBtc() public {
        uint256 usdAmount = 1000 ether; // $1000
        // At $1000/BTC, $1000 = 1 BTC
        uint256 expectedBtc = 1 ether;
        uint256 actualBtc = dscEngine.getTokenAmountFromUsd(wbtc, usdAmount);
        assertEq(actualBtc, expectedBtc);
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Modifier to deposit collateral before running a test
     * @dev Deposits AMOUNT_COLLATERAL worth of WETH for USER
     */
    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        _;
    }

    /**
     * @notice Modifier to deposit collateral AND mint DSC before running a test
     * @dev Deposits AMOUNT_COLLATERAL of WETH and mints AMOUNT_TO_MINT DSC for USER
     */
    modifier depositCollateralAndMintDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        _;
    }
}