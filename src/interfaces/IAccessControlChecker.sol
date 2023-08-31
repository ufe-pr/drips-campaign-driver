// SPDX-License-Identifier: MIT 
pragma solidity 0.8.21;

interface IAccessControlChecker {
    function canControlAccount(uint256 account, address addr) external view returns (bool hasControl);
}
