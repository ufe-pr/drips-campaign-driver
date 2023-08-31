// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {StreamReceiver, IERC20} from "drips-contracts/Drips.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {IERC5192} from "./IERC5192.sol";

struct TokenState {
    uint160 amtPerSec;
    uint32 start;
    uint32 expiresAt;
}

struct TokenConfig {
    uint256 receiverId;
    IERC20 erc20;
    TokenState state;
}

struct NFTStorage {
    mapping(uint256 => TokenConfig) tokenConfigs;
}

abstract contract NFTUtils is ERC721, IERC5192 {
    event SupportStatusChanged(
        address indexed addr, uint256 indexed accountId, IERC20 indexed erc20, uint160 amtPerSec, uint32 end
    );

    /// @notice IERC5192, Returns the locking status of an Soulbound Token
    /// Always returns true.
    function locked(uint256) external pure returns (bool) {
        return true;
    }

    /// @notice Calculates the token ID for an address.
    /// Every token ID is a 256-bit integer constructed by concatenating:
    /// `driverId (32 bits) | accountHash (224 bits)`.
    /// `accountHash` is the `keccak256` hash of (addr, receiverId, erc20).
    /// @param addr The address
    /// @param receiverId The receiver's account ID
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @return tokenId The token ID
    function calcTokenId(address addr, uint256 receiverId, IERC20 erc20) public view returns (uint256 tokenId) {
        // By assignment we get `tokenId` value:
        // `zeros (224 bits) | driverId (32 bits)`
        tokenId = _driverId();
        // By bit shifting we get `tokenId` value:
        // `driverId (32 bits) | zeros (224 bits)`
        // By bit masking we get `tokenId` value:
        // `driverId (32 bits) | accountHash (224 bits)`
        uint224 accountHash = uint224(uint256(keccak256(abi.encodePacked(addr, receiverId, erc20))));
        tokenId = (tokenId << 224) | accountHash;
    }

    /// @notice Returns the NFTStorage storage.
    /// @return storageRef The storage.
    function _nftStorage() internal view virtual returns (NFTStorage storage storageRef);

    function _driverId() internal view virtual returns (uint32 driverId);

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
        _verifyNoDuplicateAccount(newReceivers);
        uint256 currIdx = 0;
        uint256 newIdx = 0;
        while (true) {
            bool pickCurr = currIdx < currReceivers.length;
            StreamReceiver memory currRecv;
            if (pickCurr) {
                currRecv = currReceivers[currIdx];
            }

            bool pickNew = newIdx < newReceivers.length;

            // pick both curr and new when it's the same account ID
            if (pickCurr && pickNew) {
                if (currReceivers[currIdx].accountId != newReceivers[newIdx].accountId) {
                    pickCurr = _isOrdered(currReceivers[currIdx], newReceivers[newIdx]);
                    pickNew = !pickCurr;
                }
            }

            if (pickCurr && pickNew) {
                // Update the NFT expiry time
                (uint32 start, uint32 end) = _streamRangeInFuture(newReceivers[newIdx], _currTimestamp(), maxEnd);
                _updateSupportStatus(
                    addr, newReceivers[newIdx].accountId, erc20, newReceivers[newIdx].config.amtPerSec(), start, end
                );
            } else if (pickCurr) {
                // Invalidate existing NFT
                _updateSupportStatus(
                    addr,
                    currReceivers[currIdx].accountId,
                    erc20,
                    currReceivers[currIdx].config.amtPerSec(),
                    0,
                    _currTimestamp()
                );
            } else if (pickNew) {
                // Mint new NFT
                (uint32 start, uint32 end) = _streamRangeInFuture(newReceivers[newIdx], _currTimestamp(), maxEnd);
                _updateSupportStatus(
                    addr, newReceivers[newIdx].accountId, erc20, newReceivers[newIdx].config.amtPerSec(), start, end
                );
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

    function _updateSupportStatus(
        address addr,
        uint256 accountId,
        IERC20 erc20,
        uint160 amtPerSec,
        uint32 start,
        uint32 end
    ) private {
        uint256 tokenId = calcTokenId(addr, accountId, erc20);
        TokenConfig storage tokenConfig = _nftStorage().tokenConfigs[tokenId];
        if (tokenConfig.receiverId == 0) {
            tokenConfig.receiverId = accountId;
            tokenConfig.erc20 = erc20;
            _safeMint(addr, tokenId);

            // EIP-5192 (https://eips.ethereum.org/EIPS/eip-5192)
            emit Locked(tokenId);
        }

        tokenConfig.state = TokenState(amtPerSec, start, end);

        emit SupportStatusChanged(addr, accountId, erc20, amtPerSec, end);
    }

    function _verifyNoDuplicateAccount(StreamReceiver[] memory receivers) private pure {
        for (uint256 i = 1; i < receivers.length; i++) {
            require(receivers[i - 1].accountId != receivers[i].accountId, "Duplicate account ID");
        }
    }

    // Prevent token transfers
    function transferFrom(address, address, uint256) public pure override {
        revert("NFT transfers are not allowed");
    }

    function approve(address, uint256) public pure override {
        revert("NFT transfers are not allowed");
    }

    function setApprovalForAll(address, bool) public pure override {
        revert("NFT transfers are not allowed");
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0xb45a3c0e // ERC165 Interface ID for ERC5192
            || super.supportsInterface(interfaceId);
    }
}
