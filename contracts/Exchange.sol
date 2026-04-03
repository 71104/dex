// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Order, OrderBook, OrderBookMethods} from "./OrderBook.sol";
import {TokenIssuer} from "./Issuer.sol";

interface IERC20WithPermit is IERC20, IERC20Permit {}

struct Market {
  OrderBook buyers;
  OrderBook sellers;
}

struct Fulfillment {
  address token0;
  address token1;
  Order[] matches;
  uint256 units;
  uint256 cost;
}

contract Exchange is
  Initializable,
  OwnableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardTransient,
  UUPSUpgradeable
{
  using Address for address payable;
  using OrderBookMethods for OrderBook;
  using SafeERC20 for IERC20;
  using SafeERC20 for IERC20WithPermit;

  mapping(string => TokenIssuer) private _tokenIssuersByName;

  mapping(bytes32 => Market) private _markets;

  error InvalidArgument();
  error TokenIssuerAlreadyExists(string name);

  event CreateTokenIssuer(
    string indexed name,
    address indexed issuer,
    address defaultAdmin,
    bool decentralized
  );

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(address owner) public initializer {
    __Ownable_init(owner);
    __Pausable_init();
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

  function pause() public onlyOwner {
    _pause();
  }

  function unpause() public onlyOwner {
    _unpause();
  }

  function createTokenIssuer(string memory name) public returns (TokenIssuer issuer) {
    if (address(_tokenIssuersByName[name]) != address(0)) {
      revert TokenIssuerAlreadyExists(name);
    }
    issuer = new TokenIssuer(name, /*defaultAdmin=*/ msg.sender);
    _tokenIssuersByName[name] = issuer;
    emit CreateTokenIssuer(
      name,
      address(issuer),
      /*defaultAdmin=*/ msg.sender,
      /*decentralized=*/ false
    );
  }

  function _orderByAddress(
    IERC20 token0,
    IERC20 token1
  ) private pure returns (IERC20, IERC20, bool zeroForOne) {
    assert(address(token0) != address(token1));
    if (address(token1) < address(token0)) {
      return (token1, token0, true);
    } else {
      return (token0, token1, false);
    }
  }

  function _getMarket(
    IERC20 token0,
    IERC20 token1
  ) private view returns (Market storage market, bool zeroForOne) {
    if (address(token0) == address(token1)) {
      revert InvalidArgument();
    }
    (token0, token1, zeroForOne) = _orderByAddress(token0, token1);
    bytes32 hash = keccak256(abi.encode(token0, token1));
    return (_markets[hash], zeroForOne);
  }

  function getBuyOrders(
    IERC20 token0,
    IERC20 token1,
    uint256 offset,
    uint256 count
  ) public view returns (Order[] memory orders, bool zeroForOne) {
    Market storage market;
    (market, zeroForOne) = _getMarket(token0, token1);
    return (market.buyers.getOrders(offset, count), zeroForOne);
  }

  function getBuyOrdersFrom(
    IERC20 token0,
    IERC20 token1,
    address issuer,
    uint256 offset,
    uint256 count
  ) public view returns (Order[] memory orders, bool zeroForOne) {
    Market storage market;
    (market, zeroForOne) = _getMarket(token0, token1);
    return (market.buyers.getOrdersFrom(issuer, offset, count), zeroForOne);
  }

  function getSellOrders(
    IERC20 token0,
    IERC20 token1,
    uint256 offset,
    uint256 count
  ) public view returns (Order[] memory orders, bool zeroForOne) {
    Market storage market;
    (market, zeroForOne) = _getMarket(token0, token1);
    return (market.sellers.getOrders(offset, count), zeroForOne);
  }

  function getSellOrdersFrom(
    IERC20 token0,
    IERC20 token1,
    address issuer,
    uint256 offset,
    uint256 count
  ) public view returns (Order[] memory orders, bool zeroForOne) {
    Market storage market;
    (market, zeroForOne) = _getMarket(token0, token1);
    return (market.sellers.getOrdersFrom(issuer, offset, count), zeroForOne);
  }

  function buyAt(
    IERC20 token0,
    IERC20WithPermit token1,
    uint256 units,
    uint256 price,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public nonReentrant returns (Fulfillment memory fulfillment) {
    (Market storage market, bool zeroForOne) = _getMarket(token0, token1);
    if (zeroForOne) {
      fulfillment.token0 = address(token1);
      fulfillment.token1 = address(token0);
      fulfillment.matches = market.buyers.fulfill(units);
    } else {
      fulfillment.token0 = address(token0);
      fulfillment.token1 = address(token1);
      fulfillment.matches = market.sellers.fulfill(units);
    }
    Order[] memory matches = fulfillment.matches;
    for (uint256 i = 0; i < matches.length; ++i) {
      fulfillment.units += matches[i].units;
      fulfillment.cost += matches[i].price * matches[i].units;
    }

    uint256 totalCost = price * units;
    try token1.permit(msg.sender, address(this), totalCost, deadline, v, r, s) {} catch {}
    token1.safeTransferFrom(msg.sender, address(this), totalCost);

    token0.safeTransfer(msg.sender, units);
    for (uint256 i = 0; i < matches.length; ++i) {
      token1.safeTransfer(matches[i].issuer, matches[i].price * matches[i].units);
    }

    uint256 unfulfilledAmount = units - fulfillment.units;
    if (zeroForOne) {
      market.sellers.queueOrder(msg.sender, unfulfilledAmount, price);
    } else {
      market.buyers.queueOrder(msg.sender, unfulfilledAmount, price);
    }
  }
}
