//SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "../lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author pr@win
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * our DSC system should always be "overcollateralized". At no point, should the value of all colateral <= the $backed value of all the DSC system
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */
contract DSCEngine is ReentrancyGuard {

    //////////////////
    // errors //
    /////////////////

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceAddressesMustBeSameLength();
    error DSCEngine__NotAllowedTokens();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    //////////////////
    //State Variable //
    /////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // This means you need to be 200% over-collateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS  =10; //means 10% bonus

    mapping(address token => address price) private s_priceFeeds; //token to priceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_ColateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////
      //Events //
    /////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralReedemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount );
    ////////////////////
    // modifiers //
    ///////////////////

    modifier morethanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowed(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedTokens();
        }
        _;
    }

    ////////////////////
      // Functions //
    ////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        //USD priceFeeds
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressesAndPriceAddressesMustBeSameLength();
        }
        //eg:ETH/USD,BTC/USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i]; //key=value
            s_ColateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////
      // External Functions //
    ////////////////////////////
  /* 
  *@param tokenCollateralAddress- The address of the token to deposit as collateral
  *@param amountCollateral- the amount of collateral to deposit
  *@param amountDscToMint- the amount of decentralized stablecoin to mint 
  *@notice this function will deposit and mint Dsc in one transaction
  */
    
    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral,uint256 amountDscToMint) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);//calling  function
        mintDsc(amountDscToMint);//calling function
    }

    /*
    @notice follows C(checks)E(Effects)I(interactions)
    @param tokenCollateralAddress- the address of the the token to deposite as colateral
    @param amountCollateral- The amount of collateral to deposit
    */
    //1.
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        //checks
        morethanZero(amountCollateral)
        isAllowed(tokenCollateralAddress)
        nonReentrant
    {
        //Effects
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral; //updating storage means create an event
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        //interactions
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }
    /* 
    *@param tokenCollateralAddress- the collateral address to mint
    *@param amountCollateral- the amount of collateral to redeem
    *@param amountDscToBurn- the amount of DSC to burn
    *this function burns DSC and reedems underlying collateral in one transaction
    */

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) 
    external 
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }


//health factor must be over 1 after collateral pulled
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
     public
     morethanZero(amountCollateral) 
     nonReentrant(){

        _redeemCollateral(msg.sender, msg.sender,tokenCollateralAddress,amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
     }

    //2
    /*@notice follows CEI
    *@param amountDscToMint- the amount of stable coin to mint
    *@notice they must have more collateral value than the minnimum treshold
    */

    function mintDsc(uint256 amountDscToMint) public morethanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        //if they minted too much(eg: 150$ Dsc, $100 eth)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted){
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public morethanZero(amount) {
        _burnDsc(amount,msg.sender,msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

//if someone is almost undercollateralized, we will pay you to liquidate them
/* 
* @param collateral - the erc20 collateral address to lliquidate from the user
*@param user- the user who has broken the health factor. their _healthFactor should be below MIN_HEALTH_FACTOR
*@param debtToCover- the amount of dsc you want to burn to improve the users health factor
*@notice you can partially liquidate the user
*@notice you will get a liquidation bonus for taking the users funds
*@notice this function working assumes the protocol will be roughly 200% overcollateralized in order for this to work
*@notice A known bug would be if the protocol were 100% or less collateralized, then we wouldnt be able to incentive the liquidators
*
 */
    function liquidate(address collateral, address user, uint256 debtToCover) external 
    morethanZero(debtToCover) 
    nonReentrant()
    {
        //need to check the healthfactor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor>= MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorOk();
        }
        //we want to burn their DSC "debt"
        //And take their collateral
        //bad user: $140 eth, $100 DSC
        //debtToCover = $100
        //$100 of DSC ==? eth?
        //0.05 eth
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
    //And give them a 10% bonus
    //so we are giving the liquidator $110 of WETH for 100 DSC
    //we should implementa feature to liquidate in the event the protocol is insolvent
    //and sweep extra amounts into a treasury
    //0.05 * 0.1 = 0.005 getting 0.055
    uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS)/ LIQUIDATION_PRECISION;
    uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
    _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
    //we need to burn the DSC
    _burnDsc(debtToCover,user,msg.sender);

    uint256 endingUserHealthFactor = _healthFactor(user);
    if (endingUserHealthFactor <= startingUserHealthFactor){
        revert DSCEngine__HealthFactorNotImproved();
    }
    _revertIfHealthFactorIsBroken(msg.sender);

    }

    function healthFactor() external {}

    //////////////////////////////////////
    // Private & Internal View Functions //
    ///////////////////////////////////////
/*  
*@dev Low-level internal function, do not call unless the function calling it is checking for health factors being broken
*/
    function _burnDsc(uint256 amountDscToBurn,address onBehalfOf,address dscFrom) private {
        s_DSCMinted[onBehalfOf]-= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if(!success){
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }


//redeem collateral for anybody
    function _redeemCollateral(address from, address to, address tokenCollateralAddress,uint256 amountCollateral) private {
         s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;//pull out collateral
        emit CollateralReedemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to,amountCollateral);//returning the money  
        if (!success){
            revert DSCEngine__TransferFailed();
        }
        
    }

//total dsc minted and total value of all the colateral
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
     * If a user goes below 1, they can get liquidate
     */

    function _healthFactor(address user) private view returns (uint256) {
        //total Dsc minted
        //total collateral value 
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        //uint256 collateralAdjustedForThreshhold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);


        //eg: $150 ETH/100 DSC =1.5
        //150*50=7500 / 100 = (75 / 100)< 1

        //$1000 eth /100 DSC
        //1000*50=50000 / 100= (500 / 100)> 1
    }

    //1.check health factor(do they have enough collateral)
    //2. Revert if they dont
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ////////////////////////////////////////
    // Public & Exteranl View Functions //
    ///////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256) {
        // eg: price of eth(token)
        //$/eth eth?
        //$2000/ ETH $1000 = 0.5 eth
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        //($10e18 * 1e18) / ($2000e8 * 1e10)
        return (usdAmountInWei * PRECISION)/ (uint256(price)* ADDITIONAL_FEED_PRECISION);

    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        //loop through each collateral token, get the amount they have deposited, and map it to
        //the price,to get the USD value
        for (uint256 i = 0; i < s_ColateralTokens.length; i++) {
            address token = s_ColateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount); 
        }
        getAccountCollateralValue;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = $1000
        // the returned value from ChainLink will be 1000 * 1e18
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; //(1000*1e18 * (1e10))*1000*1e18
    }
    
    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
    internal
    pure
    returns(uint256){
        if(totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshhold = (collateralValueInUsd*
        LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshhold * 1e18) / totalDscMinted;
    }

    function getAccountInformation (address user) external view returns(uint256 totalDscMinted, uint256 collateralValueInUsd){
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
    external 
    pure
    returns(uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getHealthFactor(address user) external view returns (uint256){
        return _healthFactor(user);
    }

    function getLiquidationBonus()external pure returns(uint256){
        return LIQUIDATION_BONUS;
    }

    function getCollateralTokenPriceFeed(address token) external view returns(address){
        return s_priceFeeds[token];
    }

    function getCollateralTokens() external view returns(address[] memory){
        return s_ColateralTokens;
    }

    function getMinHealthFactor() external pure returns(uint256){
        return MIN_HEALTH_FACTOR;
    }

    function getLiquidationThreshold() external pure returns(uint256){
        return LIQUIDATION_THRESHOLD;
    }

    function getAditionalFeedPrice() external pure returns (uint256){
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns(uint256){
        return PRECISION;
    }

    function getCollateralBalanceOfUser (address user, address token) external view returns(uint256){
        return s_collateralDeposited[user][token];
    }

    function getDsc() external view returns (address){
        return address(i_dsc);
    }
    
}
