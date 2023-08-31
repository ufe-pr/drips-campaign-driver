// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC2771Context} from "openzeppelin-contracts/metatx/ERC2771Context.sol";
import {NFTStorage, TokenConfig, TokenState} from "./NFTUtils.sol";
import {Common} from "./CommonLib.sol";
import {MetadataJSONLib} from "./MetadataJSONLib.sol";
import {IAccessControlChecker} from "./interfaces/IAccessControlChecker.sol";

struct ReceiverNFTConfig {
    bytes imageURI;
    bytes externalURI;
    bytes customData;
}

struct MetadataStorage {
    mapping(uint256 => ReceiverNFTConfig) receiverNFTConfigs;
    mapping(uint32 => IAccessControlChecker) driverIdToAccessControlVerifier;
}

abstract contract MetadataUtils is ERC2771Context {
    modifier onlyAccountController(uint256 account) {
        _requireAddressCanControlAccount(account, _msgSender());
        _;
    }

    function _addressCanControlAccount(uint256 account, address addr) private view returns (bool hasControl) {
        uint32 driverId = uint32(account >> 224);
        hasControl = _metadataStorage().driverIdToAccessControlVerifier[driverId].canControlAccount(account, addr);
    }

    function _requireAddressCanControlAccount(uint256 account, address addr) internal view {
        require(_addressCanControlAccount(account, addr), "Unauthorized");
    }

    /// @notice Returns the Metadata storage.
    /// @return storageRef The storage.
    function _metadataStorage() internal view virtual returns (MetadataStorage storage storageRef);

    /// @notice Returns the NFTStorage storage.
    /// @return storageRef The storage.
    function _nftStorage() internal view virtual returns (NFTStorage storage storageRef);

    function getTokenState(uint256 tokenId) public view returns (bool isActive, uint160 amtPerSec) {
        TokenConfig storage tokenConfig = _nftStorage().tokenConfigs[tokenId];
        TokenState storage tokenState = tokenConfig.state;
        amtPerSec = tokenState.amtPerSec;
        isActive = tokenState.expiresAt > Common._currTimestamp() && tokenState.start <= Common._currTimestamp();
    }

    function getReceiverNFTConfig(uint256 receiverId)
        public
        view
        returns (string memory imageURI, string memory externalURI, string memory customData)
    {
        ReceiverNFTConfig storage receiverNFTConfig = _metadataStorage().receiverNFTConfigs[receiverId];
        imageURI = string(receiverNFTConfig.imageURI);
        externalURI = string(receiverNFTConfig.externalURI);
        customData = string(receiverNFTConfig.customData);
    }

    function setReceiverNFTConfig(uint256 receiverId, string calldata imageURITemplate, string calldata externalUrl)
        public
        onlyAccountController(receiverId)
    {
        ReceiverNFTConfig storage receiverNFTConfig = _metadataStorage().receiverNFTConfigs[receiverId];
        receiverNFTConfig.imageURI = bytes(imageURITemplate);
        receiverNFTConfig.externalURI = bytes(externalUrl);
    }

    function setReceiverNFTConfigCustomData(uint256 receiverId, string calldata customData)
        public
        onlyAccountController(receiverId)
    {
        ReceiverNFTConfig storage receiverNFTConfig = _metadataStorage().receiverNFTConfigs[receiverId];
        receiverNFTConfig.customData = bytes(customData);
    }

    function _buildMetadataJson(uint256 tokenId) internal view returns (string memory output) {
        TokenConfig memory tokenConfig = _nftStorage().tokenConfigs[tokenId];
        uint256 receiverId = tokenConfig.receiverId;
        IERC20 erc20 = tokenConfig.erc20;
        uint256 amtPerSec = tokenConfig.state.amtPerSec;
        bool isActive =
            tokenConfig.state.expiresAt > Common._currTimestamp() && tokenConfig.state.start <= Common._currTimestamp();

        ReceiverNFTConfig memory receiverNFTConfig = _metadataStorage().receiverNFTConfigs[receiverId];

        if (bytes(receiverNFTConfig.imageURI).length == 0) {
            // TODO: Use an actual default image
            receiverNFTConfig.imageURI = bytes(string("https://drips.network/path/to/image/{id}"));
        }
        if (bytes(receiverNFTConfig.externalURI).length != 0) {
            receiverNFTConfig.externalURI = bytes(string("https://drips.network/path/to/docs"));
        }

        output = MetadataJSONLib.buildMetadtaURI(
            receiverId,
            address(erc20),
            isActive,
            amtPerSec,
            receiverNFTConfig.imageURI,
            receiverNFTConfig.externalURI,
            receiverNFTConfig.customData
        );
    }
}
