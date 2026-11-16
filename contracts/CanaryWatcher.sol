// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractReactive } from "./lib/reactive-lib/src/base/AbstractReactive.sol";
import { ISystemContract } from "./lib/reactive-lib/src/interfaces/ISystemContract.sol";

/// @title CanaryWatcher
/// @notice Lives on Reactive Network. Watches one or more canary addresses: wallets from the same seed as the
/// owner key that hold a little ERC-20 bait and must never move. The first `Transfer` or `Approval` signed by
/// a canary means the seed is in someone else's hands, so the watcher tells every vault registered for that
/// canary, on any chain, to evacuate to its cold wallet.
contract CanaryWatcher is AbstractReactive {
    uint256 public constant TRANSFER_TOPIC = uint256(keccak256("Transfer(address,address,uint256)"));
    uint256 public constant APPROVAL_TOPIC = uint256(keccak256("Approval(address,address,uint256)"));
    uint64 public constant CALLBACK_GAS_LIMIT = 400_000;
    uint256 public constant MAX_VAULTS = 8;

    struct Vault {
        uint256 chainId;
        address vault;
    }

    event Armed(uint256 indexed originChainId, address indexed token, address indexed canary);
    event Protecting(bytes32 indexed canaryKey, uint256 indexed vaultChainId, address indexed vault);
    event Tripped(
        uint256 indexed originChainId,
        address indexed token,
        address indexed canary,
        uint256 topic0,
        address counterparty,
        uint256 amount,
        uint256 vaultsNotified
    );
    event Reset(bytes32 indexed canaryKey);

    error NotOwner();
    error UnknownCanary();
    error TooManyVaults();

    address public immutable owner;
    mapping(bytes32 => Vault[]) internal vaults;
    mapping(bytes32 => bool) public armed;
    mapping(bytes32 => bool) public tripped;

    constructor() payable {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function canaryKey(uint256 originChainId, address token, address canary) public pure returns (bytes32) {
        return keccak256(abi.encode(originChainId, token, canary));
    }

    /// @notice Start watching `canary` on `token`: any Transfer from it or Approval by it trips the alarm.
    function arm(uint256 originChainId, address token, address canary) external onlyOwner returns (bytes32 key) {
        key = canaryKey(originChainId, token, canary);
        if (!armed[key]) {
            uint256 from = uint256(uint160(canary));
            SYSTEM.subscribe(originChainId, token, TRANSFER_TOPIC, from, REACTIVE_IGNORE, REACTIVE_IGNORE);
            SYSTEM.subscribe(originChainId, token, APPROVAL_TOPIC, from, REACTIVE_IGNORE, REACTIVE_IGNORE);
            armed[key] = true;
            emit Armed(originChainId, token, canary);
        }
    }

    /// @notice Register a vault, on any supported chain, that must evacuate when the canary trips.
    function protect(bytes32 key, uint256 vaultChainId, address vault) external onlyOwner {
        if (!armed[key]) revert UnknownCanary();
        if (vaults[key].length == MAX_VAULTS) revert TooManyVaults();
        vaults[key].push(Vault(vaultChainId, vault));
        emit Protecting(key, vaultChainId, vault);
    }

    function protectedVaults(bytes32 key) external view returns (Vault[] memory) {
        return vaults[key];
    }

    /// @notice After rotating to a new seed, the owner can make an old canary live again.
    function reset(bytes32 key) external onlyOwner {
        tripped[key] = false;
        emit Reset(key);
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (log_.topic0 != TRANSFER_TOPIC && log_.topic0 != APPROVAL_TOPIC) return;
        address canary = address(uint160(log_.topic1));
        bytes32 key = canaryKey(log_.chainId, log_.contractAddress, canary);
        if (!armed[key] || tripped[key]) return;
        tripped[key] = true;

        Vault[] storage targets = vaults[key];
        bytes memory payload =
            abi.encodeWithSignature("evacuate(address,address,uint256)", address(0), canary, log_.chainId);
        for (uint256 i = 0; i < targets.length; i++) {
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: targets[i].chainId,
                    recipient: targets[i].vault,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: payload
                })
            );
        }

        uint256 amount = log_.data.length >= 32 ? abi.decode(log_.data, (uint256)) : 0;
        emit Tripped(
            log_.chainId, log_.contractAddress, canary, log_.topic0, address(uint160(log_.topic2)), amount, targets.length
        );
    }
}
