// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {StreamReceiver, IERC20} from "drips-contracts/Drips.sol";

library Common {
    /// @notice The current timestamp, casted to the contract's internal representation.
    /// @return timestamp The current timestamp
    function _currTimestamp() internal view returns (uint32 timestamp) {
        return uint32(block.timestamp);
    }

    /// @notice Checks if two receivers fulfil the sortedness requirement of the receivers list.
    /// @param prev The previous receiver
    /// @param next The next receiver
    function _isOrdered(StreamReceiver memory prev, StreamReceiver memory next) private pure returns (bool) {
        if (prev.accountId != next.accountId) {
            return prev.accountId < next.accountId;
        }
        return prev.config.lt(next.config);
    }
}
