// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";


contract DSCEngineTest is Test{
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    uint256 amountToMint;

    event Transfer(address indexed from, address indexed to, uint256 amount);

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant LIQUIDATION_THRESHOLD = 50; // 50%
    uint256 public constant LIQUIDATION_PRECISION = 100;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant LIQUIDATOR_COLLATERAL_AMOUNT = 50 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, , ) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////////////
    //     CONSTRUCTOR TEST      //
    ///////////////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ///////////////////////////////
    //        PRICE TEST         //
    ///////////////////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 60000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.025 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ///////////////////////////////
    //  DEPOSIT COLLATERAL TEST  //
    ///////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__InsufficientCollateral.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(expectedTotalDscMinted, totalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    ///////////////////////////////
    //         MINT TEST         //
    ///////////////////////////////

    function testRevertsIfAmountBreaksHealthFactor() public depositedCollateral {
    // 1. Calculate the total value of our collateral in USD
    uint256 collateralValueInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL);

    // 2. Determine the maximum amount of DSC we can mint based on the liquidation threshold.
    // This is the amount that would bring our Health Factor to exactly 1.
    uint256 maxDscToMint = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

    // 3. We want to mint slightly more than the maximum to trigger the revert.
    amountToMint = maxDscToMint + 1;

    // 4. Calculate what the health factor will be with the new mint amount, as this value is
    // returned in the revert error message.
    uint256 expectedHealthFactor = engine.calculateHealthFactor(amountToMint, engine.getUsdValue(weth, AMOUNT_COLLATERAL));

    // 5. Set up the expected revert with the specific error and the calculated health factor.
    vm.startPrank(USER);
    vm.expectRevert(
        abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor)
    );

    // 6. Attempt to mint the amount that we know will fail.
    engine.mintDsc(amountToMint);
    vm.stopPrank();
    }

    function testCanMintDscSuccessfullyAndUpdatesBalance() public depositedCollateral {
    // 1. Calculate a safe amount of DSC to mint (well below the health factor limit)
    uint256 collateralValueInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
    uint256 maxDscToMint = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
    amountToMint = maxDscToMint / 2; // Minting 50% of the max is a safe bet

    // 2. Mint the DSC as the USER
    vm.startPrank(USER);
    engine.mintDsc(amountToMint);
    vm.stopPrank();

    // 3. Check that the engine's internal accounting and the user's token balance are correct
    (uint256 totalDscMinted, ) = engine.getAccountInformation(USER);
    assertEq(totalDscMinted, amountToMint);
    assertEq(dsc.balanceOf(USER), amountToMint);
}

function testMintEmitsTransferEvent() public depositedCollateral {
    // 1. Calculate a safe amount of DSC to mint
    uint256 collateralValueInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
    uint256 maxDscToMint = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
    amountToMint = maxDscToMint / 2;

    // 2. Expect a Transfer event from the DSC token contract
    vm.startPrank(USER);
    // The event is Transfer(address(0), USER, amountToMint)
    // We check the indexed topics (from, to) and the address, but not the data (amount)
    vm.expectEmit(true, true, false, true, address(dsc));
    emit Transfer(address(0), USER, amountToMint);
    engine.mintDsc(amountToMint);
    vm.stopPrank();
}

function testRevertsIfMintAmountIsZero() public depositedCollateral {
    vm.startPrank(USER);
    // The `moreThanZero` modifier should revert with this specific error
    vm.expectRevert(DSCEngine.DSCEngine__InsufficientCollateral.selector);
    engine.mintDsc(0);
    vm.stopPrank();
}

    ////////////////////////
    //     BURN TESTS     //
    ////////////////////////

    modifier mintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        uint256 collateralValueInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 maxDscToMint = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        amountToMint = maxDscToMint / 2;
        engine.mintDsc(amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanBurnDsc() public mintedDsc {
        uint256 amountToBurn = amountToMint / 2;
        uint256 expectedDscBalance = amountToMint - amountToBurn;

        vm.startPrank(USER);
        dsc.approve(address(engine), amountToBurn);
        engine.burnDsc(amountToBurn);
        vm.stopPrank();

        (uint256 totalDscMinted, ) = engine.getAccountInformation(USER);
        assertEq(totalDscMinted, expectedDscBalance);
        assertEq(dsc.balanceOf(USER), expectedDscBalance);
    }

    function testRevertsIfBurnAmountIsZero() public mintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(engine), 1); // Approve something just in case
        vm.expectRevert(DSCEngine.DSCEngine__InsufficientCollateral.selector);
        engine.burnDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfTryingToBurnMoreDscThanMinted() public mintedDsc {
        uint256 amountToBurn = amountToMint + 1;

        vm.startPrank(USER);
        dsc.approve(address(engine), amountToBurn);
        // This will fail because the user's DSC balance is insufficient
        // The ERC20 `transferFrom` will revert.
        vm.expectRevert();
        engine.burnDsc(amountToBurn);
        vm.stopPrank();
    }

    function testBurnEmitsTransferEvent() public mintedDsc {
        uint256 amountToBurn = amountToMint / 2;

        vm.startPrank(USER);
        dsc.approve(address(engine), amountToBurn);
        vm.expectEmit(true, true, false, true, address(dsc));
        // The burn function should emit a transfer to the zero address
        emit Transfer(USER, address(engine), amountToBurn); // From user to engine
        engine.burnDsc(amountToBurn);
        vm.stopPrank();
    }

    ////////////////////////////////
    //  REDEEM COLLATERAL TESTS   //
    ////////////////////////////////

    function testCanRedeemCollateral() public mintedDsc {
        uint256 collateralToRedeem = AMOUNT_COLLATERAL / 2;
        
        vm.startPrank(USER);
        engine.redeemCollateral(weth, collateralToRedeem);
        vm.stopPrank();

        uint256 expectedCollateralAmount = AMOUNT_COLLATERAL - collateralToRedeem;
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        
        uint256 expectedCollateralValue = engine.getUsdValue(weth, expectedCollateralAmount);

        assertEq(dsc.balanceOf(USER), amountToMint); // DSC balance shouldn't change
        assertEq(totalDscMinted, amountToMint);
        assertEq(collateralValueInUsd, expectedCollateralValue);
    }

    function testRevertsIfRedeemingCollateralBreaksHealthFactor() public mintedDsc {
    // 1. Obtener los valores actuales
    (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

    // 2. Definir la cantidad de colateral a redimir que romperá el HF
    uint256 collateralToRedeem = (AMOUNT_COLLATERAL / 2) + 1; // Un wei más de la mitad

    // 3. Calcular cuál sería el valor del colateral DESPUÉS de redimir
    uint256 valueOfCollateralToRedeem = engine.getUsdValue(weth, collateralToRedeem);
    uint256 remainingCollateralValueInUsd = collateralValueInUsd - valueOfCollateralToRedeem;

    // 4. Calcular el healthFactor esperado que causará el revert
    // Esta es la fórmula exacta de la función _healthFactor en tu contrato
    uint256 collateralAdjustedForThreshold = (remainingCollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
    uint256 expectedHealthFactor = (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;

    vm.startPrank(USER);
    // 5. Esperar el revert con el selector del error Y el valor calculado
    vm.expectRevert(
        abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor)
    );
    engine.redeemCollateral(weth, collateralToRedeem);
    vm.stopPrank();
}

    ////////////////////////////////
    //     LIQUIDATION TESTS      //
    ////////////////////////////////

    address liquidator = makeAddr("liquidator");
    // We get the mock price feed address from the HelperConfig
    AggregatorV3Interface private ethUsdPriceFeedMock;


    modifier setupLiquidationScenario() {
        // 1. User deposits collateral and mints DSC
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        // User deposits 10 WETH ($40,000) and mints $10,000 DSC. Health factor is 2.
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 10000e18);
        vm.stopPrank();

        // 2. Give the liquidator some DSC to perform the liquidation
        
        vm.startPrank(liquidator);
        ERC20Mock(weth).mint(liquidator, LIQUIDATOR_COLLATERAL_AMOUNT);
        ERC20Mock(weth).approve(address(engine), LIQUIDATOR_COLLATERAL_AMOUNT);
        engine.depositCollateralAndMintDsc(weth, LIQUIDATOR_COLLATERAL_AMOUNT, 10000e18);
        vm.stopPrank();

        // 3. Simulate a price drop of ETH
        // Initial price is $4000. New price is $1900.
        // User's collateral value is now 10 * 1900 = $19,000.
        // Debt is $10,000.
        // Health factor is ($19,000 * 50%) / $10,000 = $9,500 / $10,000 = 0.95. User is liquidatable.
        ethUsdPriceFeedMock = AggregatorV3Interface(ethUsdPriceFeed);
        int256 newPrice = 1900e8; 
        address depl = address(deployer);// $1900 with 8 decimals
        vm.prank(depl);
        // Assumes your mock has an `updateAnswer` function like Chainlink's mocks
        MockV3Aggregator(address(ethUsdPriceFeedMock)).updateAnswer(newPrice);
        _;
    }

    function testRevertsIfHealthFactorIsOk() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 100e18); // Mint a very small amount
        vm.stopPrank();

        vm.startPrank(liquidator);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        engine.liquidate(weth, USER, 100e18);
        vm.stopPrank();
    }

    function testCanLiquidateUser() public setupLiquidationScenario {
        uint256 debtToCover = 1000e18; // Liquidator covers $1000 of the user's debt
        uint256 initialLiquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        
        // Liquidator must approve DSC transfer to the engine for burning
        vm.startPrank(liquidator);
        dsc.approve(address(engine), debtToCover);
        engine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
        
        // Assertions
        // 1. Liquidator's WETH balance increased by the amount corresponding to $1000 + 10% bonus
        uint256 tokenAmountForDebt = engine.getTokenAmountFromUsd(weth, debtToCover);
        uint256 bonusCollateral = (tokenAmountForDebt * 10) / 100; // 10% bonus
        uint256 expectedWethForLiquidator = tokenAmountForDebt + bonusCollateral;
        
        assertEq(
            ERC20Mock(weth).balanceOf(liquidator),
            initialLiquidatorWethBalance + expectedWethForLiquidator
        );

        // 2. Liquidator's DSC balance decreased
        assertEq(dsc.balanceOf(liquidator), 9000e18); // 10000 - 1000

        // 3. User's minted DSC amount decreased
        (uint256 userDscMinted, ) = engine.getAccountInformation(USER);
        assertEq(userDscMinted, 9000e18); // 10000 - 1000
    }

}