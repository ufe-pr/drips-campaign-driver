// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {StreamReceiver, IERC20} from "drips-contracts/Drips.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";

struct TokenState {
    uint160 amtPerSec;
    uint32 expiresAt;
}

struct TokenConfig {
    uint256 receiverId;
    IERC20 erc20;
    TokenState state;
}

struct ReceiverNFTConfig {
    bytes imageURI;
    bytes externalURI;
    bytes customData;
}

struct NFTCampaignDriverStorage {
    mapping(uint256 => TokenConfig) tokenConfigs;
    mapping(uint256 => ReceiverNFTConfig) receiverNFTConfigs;
}

abstract contract DriverLogic is ERC721 {
    event SupportStatusChanged(
        address indexed addr, uint256 indexed accountId, IERC20 indexed erc20, uint160 amtPerSec, uint32 end
    );

    /// @notice Returns the CampaignNFTDriver storage.
    /// @return storageRef The storage.
    function _driverStorage() internal view virtual returns (NFTCampaignDriverStorage storage storageRef);

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

    /// @notice Calculates the time range in the future in which a receiver will be streamed to.
    /// @param receiver The stream receiver.
    /// @param maxEnd The maximum end time of streaming.
    function _streamRangeInFuture(StreamReceiver memory receiver, uint32 updateTime, uint32 maxEnd)
        private
        view
        returns (uint32 start, uint32 end)
    {
        return _streamRange(receiver, updateTime, maxEnd, _currTimestamp(), type(uint32).max);
    }

    /// @notice Calculates the time range in which a receiver is to be streamed to.
    /// This range is capped to provide a view on the stream through a specific time window.
    /// @param receiver The stream receiver.
    /// @param updateTime The time when the stream is configured.
    /// @param maxEnd The maximum end time of streaming.
    /// @param startCap The timestamp the streaming range start should be capped to.
    /// @param endCap The timestamp the streaming range end should be capped to.
    function _streamRange(
        StreamReceiver memory receiver,
        uint32 updateTime,
        uint32 maxEnd,
        uint32 startCap,
        uint32 endCap
    ) private pure returns (uint32 start, uint32 end_) {
        start = receiver.config.start();
        // slither-disable-start timestamp
        if (start == 0) {
            start = updateTime;
        }
        uint40 end;
        unchecked {
            end = uint40(start) + receiver.config.duration();
        }
        // slither-disable-next-line incorrect-equality
        if (end == start || end > maxEnd) {
            end = maxEnd;
        }
        if (start < startCap) {
            start = startCap;
        }
        if (end > endCap) {
            end = endCap;
        }
        if (end < start) {
            end = start;
        }
        // slither-disable-end timestamp
        return (start, uint32(end));
    }

    function _updateNFTOwnership(
        address addr,
        IERC20 erc20,
        StreamReceiver[] calldata currReceivers,
        StreamReceiver[] calldata newReceivers,
        uint32 maxEnd
    ) internal {
        uint256 currIdx = 0;
        uint256 newIdx = 0;
        while (true) {
            bool pickCurr = currIdx < currReceivers.length;
            StreamReceiver memory currRecv;
            if (pickCurr) {
                currRecv = currReceivers[currIdx];
            }

            bool pickNew = newIdx < newReceivers.length;
            StreamReceiver memory newRecv;
            if (pickNew) {
                newRecv = newReceivers[newIdx];
            }

            // pick both curr and new when it's the same account ID
            if (pickCurr && pickNew) {
                if (currRecv.accountId != newRecv.accountId) {
                    pickCurr = _isOrdered(currRecv, newRecv);
                    pickNew = !pickCurr;
                }
            }

            if (pickCurr && pickNew) {
                // Update the NFT expiry time
                (, uint32 end) = _streamRangeInFuture(newRecv, _currTimestamp(), maxEnd);
                _updateSupportStatus(addr, newRecv.accountId, erc20, ((newRecv.config.amtPerSec())), end);
            } else if (pickCurr) {
                // Invalidate existing NFT
                _updateSupportStatus(addr, currRecv.accountId, erc20, ((currRecv.config.amtPerSec())), _currTimestamp());
            } else if (pickNew) {
                // Mint new NFT
                (, uint32 end) = _streamRangeInFuture(newRecv, _currTimestamp(), maxEnd);
                _updateSupportStatus(addr, newRecv.accountId, erc20, ((newRecv.config.amtPerSec())), end);
            } else {
                break;
            }

            unchecked {
                if (pickCurr) {
                    currIdx++;
                }
                if (pickNew) {
                    newIdx++;
                }
            }
        }
    }

    function _updateSupportStatus(address addr, uint256 accountId, IERC20 erc20, uint160 amtPerSec, uint32 end)
        internal
        virtual;
}
