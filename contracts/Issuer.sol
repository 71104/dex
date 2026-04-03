// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Token} from "./Token.sol";

contract TokenIssuer is TimelockController {
  bytes32 public constant MINT_BURN_ROLE = keccak256("MINT_BURN_ROLE");

  event IssueToken(
    string indexed issuerName,
    string indexed tokenName,
    string indexed tokenSymbol,
    address token
  );

  error TokenNameAlreadyExists(string tokenName, address existingTokenAddress);
  error TokenSymbolAlreadyExists(string tokenSymbol, address existingTokenAddress);

  string private _name;
  Token[] private _tokens;

  mapping(string => Token) _tokensByName;
  mapping(string => Token) _tokensBySymbol;

  function _toArray(address element) private pure returns (address[] memory array) {
    array = new address[](1);
    array[0] = element;
  }

  constructor(
    string memory name_,
    address defaultAdmin
  )
    TimelockController(
      /*minDelay=*/ 0,
      /*proposers=*/ _toArray(defaultAdmin),
      /*executors=*/ _toArray(defaultAdmin),
      defaultAdmin
    )
  {
    _name = name_;
    _grantRole(MINT_BURN_ROLE, defaultAdmin);
  }

  function name() public view returns (string memory) {
    return _name;
  }

  function tokens() public view returns (Token[] memory) {
    return _tokens;
  }

  function tokens(uint256 index) public view returns (Token) {
    return _tokens[index];
  }

  function getTokenByName(string memory tokenName) public view returns (Token) {
    return _tokensByName[tokenName];
  }

  function getTokenBySymbol(string memory tokenSymbol) public view returns (Token) {
    return _tokensBySymbol[tokenSymbol];
  }

  function issue(
    string memory tokenName,
    string memory tokenSymbol
  ) public onlyRole(EXECUTOR_ROLE) returns (Token token) {
    if (address(_tokensByName[tokenName]) != address(0)) {
      revert TokenNameAlreadyExists(tokenName, address(_tokensByName[tokenName]));
    }
    if (address(_tokensBySymbol[tokenSymbol]) != address(0)) {
      revert TokenSymbolAlreadyExists(tokenSymbol, address(_tokensBySymbol[tokenSymbol]));
    }
    token = new Token(this, tokenName, tokenSymbol);
    _tokens.push(token);
    _tokensByName[tokenName] = token;
    _tokensBySymbol[tokenSymbol] = token;
    emit IssueToken(_name, tokenName, tokenSymbol, address(token));
  }

  function mint(Token token, address to, uint256 amount) public onlyRole(MINT_BURN_ROLE) {
    token.mint(to, amount);
  }

  function burn(
    Token token,
    address from,
    uint256 amount,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public onlyRole(MINT_BURN_ROLE) {
    try token.permit(from, address(this), amount, deadline, v, r, s) {} catch {}
    token.burnFrom(from, amount);
  }
}
