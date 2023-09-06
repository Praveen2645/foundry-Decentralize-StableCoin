//SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Test, console} from "../../lib/forge-std/src/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../../lib/openzeppelin-contracts/contracts/mocks/ERC20Mock.sol";
import {MockFailedTransferFrom} from "../mocks/MockFiledTransferFrom.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";

contract DSCEngineTEst is Test{
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 amountToMint = 100 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc,dsce,config) = deployer.run();
        (ethUsdPriceFeed, ,weth, ,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);//minting weth to user
    }

     //////////////////////////
      // constructor test //
    //////////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesNotMatchPriceFeeds() public {
      tokenAddresses.push(weth);
      priceFeedAddresses.push(ethUsdPriceFeed);
      priceFeedAddresses.push(btcUsdPriceFeed);

      vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceAddressesMustBeSameLength.selector);
      new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ////////////////////
      // Price test //
    ////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18; //if we have 15 eth
        // 15e18 * $2000/ETh = 30,000e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
      uint256 usdAmount = 100 ether;
      //$2000/eth, $100
      uint256 expectedWeth = 0.05 ether;
      uint256 actualWeth = dsce.getTokenAmountFromUsd(weth,usdAmount);
      assertEq(expectedWeth, actualWeth);
    }

    /////////////////////////////////
      // deposiCollateral test //
    ////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
      ERC20Mock ranToken = new ERC20Mock("RAN","RAN", USER,AMOUNT_COLLATERAL);
      vm.startPrank(USER);
      vm.expectRevert(DSCEngine.DSCEngine__NotAllowedTokens.selector);
      dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
      vm.stopPrank();
    }

  modifier depositedCollateral(){
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
    dsce.depositCollateral(weth,AMOUNT_COLLATERAL);
    vm.stopPrank();
    _;
  }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral(){
      (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
      uint256 expectedTotalDscMinted = 0;
      uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
      assertEq(totalDscMinted,expectedTotalDscMinted);
      assertEq(AMOUNT_COLLATERAL,expectedDepositAmount);
    }
    
    function testCanDepositCollateralWithoutMinting() public depositedCollateral{
      uint256 userBalance= dsc.balanceOf(USER);
      assertEq(userBalance,0) ;
    }

    function testRevertsIfTransferFromFails() public{
      address owner = msg.sender;
      vm.prank(owner);
      MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
      tokenAddresses = [address(mockDsc)];
      priceFeedAddresses = [ethUsdPriceFeed];

      vm.prank(owner);
      DSCEngine mockDsce = new DSCEngine(
        tokenAddresses,
        priceFeedAddresses,
        address(mockDsc)
      );
      mockDsc.mint(USER, AMOUNT_COLLATERAL);

      vm.prank(owner);
      mockDsc.transferOwnership(address(mockDsce));

      vm.startPrank(USER);
      ERC20Mock(address(mockDsc)).approve(address(mockDsc), AMOUNT_COLLATERAL);

      vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
      mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
      vm.stopPrank();

    }

      /////////////////////////////////////////
        // deposiCollateralAndMintDsc test //
    ///////////////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor_() public {
      (,int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();//fetching eth/usd price
      amountToMint = (AMOUNT_COLLATERAL * (uint256(price)* dsce.getAditionalFeedPrice())) / dsce.getPrecision();
      vm.startPrank(USER);
      ERC20Mock(weth).approve(address(dsce),AMOUNT_COLLATERAL);

      uint256 expectedHealthFactor = 
      dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth,AMOUNT_COLLATERAL));
      vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
      dsce.depositCollateralAndMintDsc(weth,AMOUNT_COLLATERAL,amountToMint);
      vm.stopPrank();
    }

    modifier depositedCollateralAndMintDsc() {
      vm.startPrank(USER);
      ERC20Mock(weth).approve(address(dsce),AMOUNT_COLLATERAL );
      dsce.depositCollateralAndMintDsc(weth,AMOUNT_COLLATERAL,amountToMint);
      vm.stopPrank();
      _;
    }

  function testCanMintWithDepositedCollateral() public depositedCollateralAndMintDsc{
    uint256 userBalance = dsc.balanceOf(USER);
    assertEq(userBalance, amountToMint);
  }

     //////////////////////////////////
          // mintDsc Tests //
    ///////////////////////////////////

    function testRevertsIfMintFails() public {
      MockFailedMintDSC mockDSC = new MockFailedMintDSC();
      tokenAddresses= [weth];
      priceFeedAddresses= [ethUsdPriceFeed];
      address owner = msg.sender;
      vm.prank(owner);
      DSCEngine mockDsce = new DSCEngine(
        tokenAddresses,
        priceFeedAddresses,
        address(mockDSC)
      );
      mockDSC.transferOwnership(address(mockDsce));
      vm.startPrank(USER);
      ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);

      vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
      mockDsce.depositCollateralAndMintDsc(weth,AMOUNT_COLLATERAL,amountToMint);
      vm.stopPrank();

    }
}