// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockUSDC is ERC20, Ownable {
    uint256 public constant FAUCET_AMOUNT = 10_000 * 10 ** 6;

    error FaucetAlreadyClaimed(address account);

    mapping(address account => bool claimed) public hasClaimedFaucet;

    event FaucetClaimed(address indexed account, uint256 amount);

    constructor() ERC20("Mock USD Coin", "mUSDC") Ownable(msg.sender) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address account, uint256 amount) external onlyOwner {
        _mint(account, amount);
    }

    function faucet() external {
        if (hasClaimedFaucet[msg.sender]) {
            revert FaucetAlreadyClaimed(msg.sender);
        }

        hasClaimedFaucet[msg.sender] = true;
        _mint(msg.sender, FAUCET_AMOUNT);
        emit FaucetClaimed(msg.sender, FAUCET_AMOUNT);
    }
}

contract ReentrantMockUSDC is MockUSDC {
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bool private callbackArmed;

    function armCallback(address target, bytes calldata data) external onlyOwner {
        callbackTarget = target;
        callbackData = data;
        callbackAttempted = false;
        callbackSucceeded = false;
        callbackArmed = true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool transferred = super.transferFrom(from, to, value);
        if (callbackArmed) {
            callbackArmed = false;
            callbackAttempted = true;
            (callbackSucceeded, ) = callbackTarget.call(callbackData);
        }
        return transferred;
    }
}