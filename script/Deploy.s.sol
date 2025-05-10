// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {Black} from "../src/Black.sol";
import {Presale} from "../src/Presale.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployScript is Script {

    uint256 constant INITIAL_TOKEN_PRICE = 1e14; // 0.0001 ETH per token

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        console.log("Deployer: ", deployer);

        vm.startBroadcast(deployerKey);

        Black black = new Black(deployer);
        console.log("Black token: ", address(black));


        Presale presale = new Presale();
        console.log("Presale Implementation: ", address(presale));

        bytes memory initData = abi.encodeCall(Presale.initialize, (address(black), INITIAL_TOKEN_PRICE));  
        ERC1967Proxy proxy = new ERC1967Proxy(address(presale), initData);

        console.log("Presale Proxy:", address(proxy));

        vm.stopBroadcast();
    }
}
