//SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Script} from "../lib//forge-std/src/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
//import {Vm} from "../lib/forge-std/src/Vm.sol";

contract DeployDSC is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (DecentralizedStableCoin, DSCEngine, HelperConfig) {
        HelperConfig config = new HelperConfig();

        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc,
        uint256 deployerKey) = config.activeNetworkConfig();

            tokenAddresses = [weth, wbtc];
            priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

    vm.startBroadcast(deployerKey);
    DecentralizedStableCoin dsc = new DecentralizedStableCoin(); //no constructor args
//have args(tokenAddresses,priceFeedAddress,dscAddress),we have dsc address but no other , for that helper.config
    DSCEngine engine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));

    dsc.transferOwnership(address(engine));
    vm.stopBroadcast();
    return (dsc, engine, config);
}
}