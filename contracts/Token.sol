// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20FlashMint} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20FlashMint.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {ERC20Restricted} from "./ERC20Restricted.sol";
import {TokenIssuer} from "./Issuer.sol";

contract Token is ERC20, ERC20Burnable, Ownable, ERC20Permit, ERC20FlashMint, ERC20Restricted {
  TokenIssuer public issuer;

  constructor(
    TokenIssuer issuer_,
    string memory name,
    string memory symbol
  ) ERC20(name, symbol) Ownable(address(issuer_)) ERC20Permit(name) {
    issuer = issuer_;
  }

  function mint(address to, uint256 amount) public onlyOwner {
    _mint(to, amount);
  }

  function blockUser(address user) public onlyOwner {
    _blockUser(user);
  }

  function unblockUser(address user) public onlyOwner {
    _resetUser(user);
  }

  // The following functions are overrides required by Solidity.

  function _update(
    address from,
    address to,
    uint256 value
  ) internal override(ERC20, ERC20Restricted) {
    super._update(from, to, value);
  }
}
