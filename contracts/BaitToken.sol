// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title BaitToken
/// @notice Minimal ERC-20 used as the bait in the demo. In real use the bait is any ERC-20 dust
/// (1 USDC is plenty) parked on the canary address: the canary only needs to emit `Transfer` when it moves.
contract BaitToken {
    string public constant name = "Canary Bait";
    string public constant symbol = "BAIT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address canary, uint256 amount) {
        totalSupply = amount;
        balanceOf[canary] = amount;
        emit Transfer(address(0), canary, amount);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        allowance[from][msg.sender] -= value;
        _move(from, to, value);
        return true;
    }

    function _move(address from, address to, uint256 value) internal {
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}
