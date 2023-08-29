// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {Strings} from "openzeppelin-contracts/utils/Strings.sol";
import {Base64} from "openzeppelin-contracts/utils/Base64.sol";

library Metadata {
    function _boolToBytes(bool value) private pure returns (bytes memory) {
        return bytes(abi.encodePacked(value ? "true" : "false"));
    }

    function _formatMetadataJson(
        uint256 receiverId,
        address erc20,
        bool isActive,
        uint256 amtPerSec,
        uint32 expiresAt,
        bytes memory imageURI,
        bytes memory externalURI,
        bytes memory customData
    ) private pure returns (bytes memory output) {
        string memory json;
        // Splitting up into multiple blocks because of stack too deep error
        {
            json = string(
                abi.encodePacked(
                    '{"name":"Drips support #',
                    Strings.toHexString(receiverId),
                    '","description":"Drips are streams of funds. This NFT represents a stream of funds from an address to a receiver.","image":"',
                    string(imageURI),
                    '","external_url":"',
                    string(externalURI),
                    '",'
                )
            );
        }
        {
            json = string(
                abi.encodePacked(
                    json,
                    '"attributes":[{"trait_type":"Token","value":"',
                    Strings.toHexString(erc20),
                    '"},{"trait_type":"Active","value":',
                    string(_boolToBytes(isActive)),
                    '},{"trait_type":"Support rate","value":',
                    Strings.toString(amtPerSec),
                    '},{"trait_type":"Expire", "display_type": "date","value":',
                    Strings.toString(expiresAt),
                    '}],',
                    '"customData":"',
                    string(customData),
                    '"}'
                )
            );
        }

        return bytes(json);
    }

    function buildMetadtaURI(
        uint256 receiverId,
        address erc20,
        bool isActive,
        uint256 amtPerSec,
        uint32 expiresAt,
        bytes memory imageURI,
        bytes memory externalURI,
        bytes memory customData
    ) internal pure returns (string memory output) {
        bytes memory metadata =
            _formatMetadataJson(receiverId, erc20, isActive, amtPerSec, expiresAt, imageURI, externalURI, customData);
        bytes memory metadataURI = abi.encodePacked("data:application/json;base64,", Base64.encode(metadata));
        return string(metadataURI);
    }
}
