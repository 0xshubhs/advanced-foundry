// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockFailedTransfer
 * @notice ERC20 mock that fails on transfer/transferFrom to test DSCEngine transfer failure branches
 */
contract MockFailedTransfer is ERC20 {
    constructor() ERC20("MockFailedTransfer", "MFT") {
        _mint(msg.sender, 1000000e18);
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

/**
 * @title MockFailedMintDSC
 * @notice DSC mock that fails on mint to test DSCEngine mint failure branch
 */
contract MockFailedMintDSC is ERC20 {
    address public owner;

    constructor() ERC20("MockFailedMintDSC", "MFDSC") {
        owner = msg.sender;
    }

    function mint(address, uint256) external pure returns (bool) {
        return false; // Always fail
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function transferOwnership(address newOwner) external {
        owner = newOwner;
    }
}

/**
 * @title MockFailedTransferFromDSC
 * @notice DSC mock that fails on transferFrom to test _burnDsc transfer failure
 */
contract MockFailedTransferFromDSC is ERC20 {
    address public owner;
    bool public shouldFailTransferFrom;

    constructor() ERC20("MockFailedTransferFromDSC", "MFTFDSC") {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external returns (bool) {
        _mint(to, amount);
        return true;
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function transferOwnership(address newOwner) external {
        owner = newOwner;
    }

    function setShouldFailTransferFrom(bool _shouldFail) external {
        shouldFailTransferFrom = _shouldFail;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (shouldFailTransferFrom) {
            return false;
        }
        return super.transferFrom(from, to, amount);
    }
}

/**
 * @title MockDecreasingPriceAggregator
 * @notice A malicious price feed that crashes price mid-transaction to trigger HealthFactorNotImproved
 * @dev Used to test the defensive check in liquidate() that should normally never trigger
 */
contract MockDecreasingPriceAggregator {
    uint8 public decimals = 8;
    int256 public latestAnswer;
    uint256 public latestTimestamp;
    uint256 public latestRound;
    uint256 public callCount;
    int256 public crashAmount;

    constructor(int256 _initialAnswer, int256 _crashAmount) {
        latestAnswer = _initialAnswer;
        latestTimestamp = block.timestamp;
        latestRound = 1;
        crashAmount = _crashAmount;
    }

    function resetCallCount() external {
        callCount = 0;
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (uint80(latestRound), latestAnswer, latestTimestamp, latestTimestamp, uint80(latestRound));
    }

    function latestRoundData()
        external
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        callCount++;
        // After first 2 calls, crash the price drastically
        // This makes ending health factor worse than starting
        if (callCount > 2) {
            latestAnswer = latestAnswer - crashAmount;
            if (latestAnswer < 1e8) latestAnswer = 1e8; // Keep minimum price
        }
        return (uint80(latestRound), latestAnswer, latestTimestamp, latestTimestamp, uint80(latestRound));
    }
}
