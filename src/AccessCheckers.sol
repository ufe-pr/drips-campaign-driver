// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {AccountMetadata, Drips, StreamReceiver, IERC20, SplitsReceiver} from "drips-contracts/Drips.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {IAccessControlChecker} from "./interfaces/IAccessControlChecker.sol";

contract AddressDriverAccessChecker is IAccessControlChecker {
    function canControlAccount(uint256 account, address addr) external pure returns (bool) {
        return uint160(addr) == uint160(account);
    }
}

contract NFTDriverAccessChecker is IAccessControlChecker {
    /// @notice The Drips address used by this checker.
    Drips public immutable drips;

    /// @param drips_ The Drips contract to use.
    constructor(Drips drips_) {
        drips = drips_;
    }

    function canControlAccount(uint256 account, address addr) external view returns (bool) {
        uint32 driverId = uint32(account >> 224);
        IERC721 driver = IERC721(drips.driverAddress(driverId));
        return driver.ownerOf(account) == addr;
    }
}
