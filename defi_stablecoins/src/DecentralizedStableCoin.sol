// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
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

/*
    * @title Decentralized Stablecoin
    *@author 0xShubham
    *Collateral : Crypto(ETH and BTC)
    *Stability Mechanism (Minting) : Algorithmic (Decentralised)
    *(Relative Stability ) Anchored or Pegged --> $1.00
*/

import { ERC20Burnable, ERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStablecoin_MustbeMoreThanZero();
    error DecentralizedStablecoin_BurnAmountExceedsbalance();
    error DecentralizedStablecoin_NotMintableonZeroAddress();

    constructor() ERC20("Brij Coin", "$BRJC") { }

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStablecoin_MustbeMoreThanZero();
        }
        if (_amount < balance) {
            revert DecentralizedStablecoin_BurnAmountExceedsbalance();
        }
        super.burn(_amount); // super keyword is used to call the parent function{ERC20Burnable}
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStablecoin_NotMintableonZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStablecoin_MustbeMoreThanZero();
        }
        _mint(_to, _amount); // _mint function is also then inherited from ERC20
        return true;
    }
}
