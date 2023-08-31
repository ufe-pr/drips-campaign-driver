// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {AccountMetadata, Drips, StreamReceiver, IERC20, SplitsReceiver} from "drips-contracts/Drips.sol";
import {Streams} from "drips-contracts/Streams.sol";
import {DriverTransferUtils} from "drips-contracts/DriverTransferUtils.sol";
import {Managed} from "drips-contracts/Managed.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";
import {NFTUtils, NFTStorage} from "./NFTUtils.sol";
import {Common} from "./CommonLib.sol";
import {MetadataUtils, MetadataStorage} from "./MetadataUtils.sol";

contract NFTCampaignDriver is DriverTransferUtils, Managed, NFTUtils, MetadataUtils {
    /// @notice The Drips address used by this driver.
    Drips public immutable drips;
    /// @notice The driver ID which this driver uses when calling Drips.
    uint32 public immutable driverId;

    bytes32 private immutable _nftStorageSlot = _erc1967Slot("eip1967.campaignNftDriver.nft.storage");
    bytes32 private immutable _metadataStorageSlot = _erc1967Slot("eip1967.campaignNftDriver.metadata.storage");

    /// @param drips_ The Drips contract to use.
    /// @param forwarder The ERC-2771 forwarder to trust. May be the zero address.
    /// @param driverId_ The driver ID to use when calling Drips.
    constructor(Drips drips_, address forwarder, uint32 driverId_) DriverTransferUtils(forwarder) ERC721("", "") {
        drips = drips_;
        driverId = driverId_;
    }

    function tokenURI(uint256 id) public view override returns (string memory uri) {
        {
            uri = _buildMetadataJson(id);
        }
    }

    /// @notice Returns the address of the Drips contract to use for ERC-20 transfers.
    function _drips() internal view override returns (Drips) {
        return drips;
    }

    /// @notice Returns the driver ID to use when calling Drips.
    function _driverId() internal view override returns (uint32) {
        return driverId;
    }

    /// @notice Returns the CampaignNFTDriver storage.
    /// @return storageRef The storage.
    function _nftStorage() internal view override(NFTUtils, MetadataUtils) returns (NFTStorage storage storageRef) {
        bytes32 slot = _nftStorageSlot;
        // slither-disable-next-line assembly
        assembly {
            storageRef.slot := slot
        }
    }

    /// @notice Returns the Metadata storage.
    /// @return storageRef The storage.
    function _metadataStorage() internal view override returns (MetadataStorage storage storageRef) {
        bytes32 slot = _metadataStorageSlot;
        // slither-disable-next-line assembly
        assembly {
            storageRef.slot := slot
        }
    }

    /// @notice Calculates the account ID for an address.
    /// Every account ID is a 256-bit integer constructed by concatenating:
    /// `driverId (32 bits) | zeros (64 bits) | addr (160 bits)`.
    /// @param addr The address
    /// @return accountId The account ID
    function calcAccountId(address addr) public view returns (uint256 accountId) {
        // By assignment we get `accountId` value:
        // `zeros (224 bits) | driverId (32 bits)`
        accountId = driverId;
        // By bit shifting we get `accountId` value:
        // `driverId (32 bits) | zeros (224 bits)`
        // By bit masking we get `accountId` value:
        // `driverId (32 bits) | zeros (64 bits) | addr (160 bits)`
        accountId = (accountId << 224) | uint160(addr);
    }

    /// @notice Calculates the account ID for the message sender
    /// @return accountId The account ID
    function _callerAccountId() internal view returns (uint256 accountId) {
        return calcAccountId(_msgSender());
    }

    /// @notice Collects the account's received already split funds
    /// and transfers them out of the Drips contract.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param transferTo The address to send collected funds to
    /// @return amt The collected amount
    function collect(IERC20 erc20, address transferTo) public whenNotPaused returns (uint128 amt) {
        return _collectAndTransfer(_callerAccountId(), erc20, transferTo);
    }

    /// @notice Sets the message sender's streams configuration.
    /// Transfers funds between the message sender's wallet and the Drips contract
    /// to fulfil the change of the streams balance.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param currReceivers The current streams receivers list.
    /// It must be exactly the same as the last list set for the sender with `setStreams`.
    /// If this is the first update, pass an empty array.
    /// @param balanceDelta The streams balance change to be applied.
    /// Positive to add funds to the streams balance, negative to remove them.
    /// @param newReceivers The list of the streams receivers of the sender to be set.
    /// Must be sorted by the receivers' addresses, deduplicated and without 0 amtPerSecs.
    /// @param maxEndHint1 An optional parameter allowing gas optimization, pass `0` to ignore it.
    /// The first hint for finding the maximum end time when all streams stop due to funds
    /// running out after the balance is updated and the new receivers list is applied.
    /// Hints have no effect on the results of calling this function, except potentially saving gas.
    /// Hints are Unix timestamps used as the starting points for binary search for the time
    /// when funds run out in the range of timestamps from the current block's to `2^32`.
    /// Hints lower than the current timestamp are ignored.
    /// You can provide zero, one or two hints. The order of hints doesn't matter.
    /// Hints are the most effective when one of them is lower than or equal to
    /// the last timestamp when funds are still streamed, and the other one is strictly larger
    /// than that timestamp,the smaller the difference between such hints, the higher gas savings.
    /// The savings are the highest possible when one of the hints is equal to
    /// the last timestamp when funds are still streamed, and the other one is larger by 1.
    /// It's worth noting that the exact timestamp of the block in which this function is executed
    /// may affect correctness of the hints, especially if they're precise.
    /// Hints don't provide any benefits when balance is not enough to cover
    /// a single second of streaming or is enough to cover all streams until timestamp `2^32`.
    /// Even inaccurate hints can be useful, and providing a single hint
    /// or two hints that don't enclose the time when funds run out can still save some gas.
    /// Providing poor hints that don't reduce the number of binary search steps
    /// may cause slightly higher gas usage than not providing any hints.
    /// @param maxEndHint2 An optional parameter allowing gas optimization, pass `0` to ignore it.
    /// The second hint for finding the maximum end time, see `maxEndHint1` docs for more details.
    /// @param transferTo The address to send funds to in case of decreasing balance
    /// @return realBalanceDelta The actually applied streams balance change.
    function setStreams(
        IERC20 erc20,
        StreamReceiver[] calldata currReceivers,
        int128 balanceDelta,
        StreamReceiver[] calldata newReceivers,
        // slither-disable-next-line similar-names
        uint32 maxEndHint1,
        uint32 maxEndHint2,
        address transferTo
    ) public whenNotPaused returns (int128 realBalanceDelta) {
        uint256 supporterAccountId = _callerAccountId();
        realBalanceDelta = _setStreamsAndTransfer(
            supporterAccountId, erc20, currReceivers, balanceDelta, newReceivers, maxEndHint1, maxEndHint2, transferTo
        );
        (,,,, uint32 maxEnd) = _drips().streamsState(supporterAccountId, erc20);
        _updateNFTOwnership(_msgSender(), erc20, currReceivers, newReceivers, maxEnd);
    }

    /// @notice Emits the account metadata for the message sender.
    /// The keys and the values are not standardized by the protocol, it's up to the users
    /// to establish and follow conventions to ensure compatibility with the consumers.
    /// @param accountMetadata The list of account metadata.
    function emitAccountMetadata(AccountMetadata[] calldata accountMetadata) public whenNotPaused {
        drips.emitAccountMetadata(_callerAccountId(), accountMetadata);
    }


}
