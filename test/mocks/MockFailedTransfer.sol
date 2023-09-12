// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ERC20Burnable, ERC20}from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract MockFailedTransfer is ERC20Burnable,Ownable {
    error DecentralizedStableCoin__AmountMustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();

    constructor() ERC20 ("DecentralizeStableCoin", "DSC"){}

    function burn(uint256 _amount) public override onlyOwner{
        uint256 balance = balanceOf(msg.sender);
        if(_amount <= 0){
            revert DecentralizedStableCoin__AmountMustBeMoreThanZero();
        }
        if (balance <= _amount){
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }
    function mint(address account, uint256 amount) public{
        _mint(account, amount);
    }
    function transfer(address, uint256) public pure override returns(bool){
        return false;
    }
}