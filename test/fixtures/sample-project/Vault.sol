// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// Deliberately vulnerable fixture used by the self-test workflow. It is
/// tiny so a real V12 audit of it costs almost nothing. Do not copy it.
contract Vault {
    mapping(address => uint256) public balances;
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    // Reentrancy: the external call happens before the balance update.
    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "insufficient");
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
        balances[msg.sender] -= amount;
    }

    // Missing access control on an owner-only operation.
    function setOwner(address newOwner) external {
        owner = newOwner;
    }
}
