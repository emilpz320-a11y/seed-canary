// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractCallback } from "./lib/reactive-lib/src/base/AbstractCallback.sol";
import { IPayable } from "./lib/reactive-lib/src/interfaces/IPayable.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
}

/// @title EscapeVault
/// @notice A personal vault that empties itself into a cold wallet the moment the Reactive Network reports
/// that the owner's canary address moved its bait. The cold wallet comes from a different seed, so a leaked
/// seed loses the bait and nothing else.
contract EscapeVault is AbstractCallback {
    uint256 public constant MAX_TOKENS = 8;

    event Deposited(address indexed from, uint256 amount);
    event WithdrawalRequested(address indexed to, uint256 amount, uint256 readyAt);
    event Withdrawn(address indexed to, uint256 amount);
    event TokenTracked(address indexed token);
    event Evacuated(address indexed coldWallet, uint256 amount, address indexed canary, uint256 originChainId);
    event Rearmed();

    error NotOwner();
    error AlreadyEvacuated();
    error TooManyTokens();
    error NothingPending();
    error NotReady();

    address public immutable owner;
    /// @notice Fixed at deployment: a stolen owner key must not be able to redirect the escape route.
    address public immutable coldWallet;
    /// @notice Spending waits this long, so a thief holding the owner key cannot outrun the canary.
    uint64 public immutable withdrawDelay;
    bool public evacuated;
    address[] public tokens;

    address public pendingTo;
    uint256 public pendingAmount;
    uint64 public pendingReadyAt;

    constructor(IPayable callbackProxy_, address canaryWatcher_, address coldWallet_, uint64 withdrawDelay_)
        payable
        AbstractCallback(callbackProxy_, canaryWatcher_)
    {
        owner = msg.sender;
        coldWallet = coldWallet_;
        withdrawDelay = withdrawDelay_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    receive() external payable override {
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Day-to-day spending, in two steps. Disabled once evacuated: by then the owner key is presumed stolen.
    function requestWithdraw(address to, uint256 amount) external onlyOwner {
        if (evacuated) revert AlreadyEvacuated();
        pendingTo = to;
        pendingAmount = amount;
        pendingReadyAt = uint64(block.timestamp) + withdrawDelay;
        emit WithdrawalRequested(to, amount, pendingReadyAt);
    }

    function executeWithdraw() external onlyOwner {
        if (pendingTo == address(0)) revert NothingPending();
        if (block.timestamp < pendingReadyAt) revert NotReady();
        (address to, uint256 amount) = (pendingTo, pendingAmount);
        _clearPending();
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(to, amount);
    }

    function cancelWithdraw() external onlyOwner {
        _clearPending();
    }

    /// @notice ERC-20s the vault should also carry to the cold wallet on evacuation.
    function trackToken(address token) external onlyOwner {
        if (tokens.length == MAX_TOKENS) revert TooManyTokens();
        tokens.push(token);
        emit TokenTracked(token);
    }

    function trackedTokens() external view returns (address[] memory) {
        return tokens;
    }

    /// @notice Reactive callback. The Reactive Network overwrites the first argument with the address of the
    /// reactive contract that requested it, which must be our canary watcher.
    function evacuate(address watcher_, address canary, uint256 originChainId)
        external
        onlyServiceProvider
        onlyCallbackSender(watcher_)
    {
        if (evacuated) return;
        evacuated = true;
        _clearPending();
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20 token = IERC20(tokens[i]);
            uint256 held = token.balanceOf(address(this));
            if (held > 0) token.transfer(coldWallet, held);
        }
        uint256 amount = address(this).balance;
        (bool ok,) = coldWallet.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit Evacuated(coldWallet, amount, canary, originChainId);
    }

    /// @notice After rotating keys and re-funding, the same vault can be used again.
    function rearm() external onlyOwner {
        evacuated = false;
        emit Rearmed();
    }

    /// @notice Settles callback fees owed to the Reactive callback proxy from the vault's balance.
    function coverDebt() external {
        _coverDebt();
    }

    function _clearPending() internal {
        pendingTo = address(0);
        pendingAmount = 0;
        pendingReadyAt = 0;
    }
}
