// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Caller} from "drips-contracts/Caller.sol";
import {NFTCampaignDriver} from "src/NFTCampaignDriver.sol";
import {
    AccountMetadata,
    StreamConfigImpl,
    Drips,
    StreamsHistory,
    StreamReceiver,
    SplitsReceiver
} from "drips-contracts/Drips.sol";
import {ManagedProxy} from "drips-contracts/Managed.sol";
import {Test, console} from "forge-std/Test.sol";
import {IERC20, ERC20PresetFixedSupply} from "openzeppelin-contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import {ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";
import {IAccessControlChecker, AddressDriverAccessChecker} from "src/AccessCheckers.sol";

contract NFTCampaignDriverTest is Test, ERC721TokenReceiver {
    Drips internal drips;
    Caller internal caller;
    NFTCampaignDriver internal driver;
    IERC20 internal erc20;

    address internal admin = address(1);
    address internal user = address(2);
    uint256 internal thisId;
    uint256 internal accountId;

    bytes internal constant ERROR_ALREADY_MINTED = "ERC721: token already minted";

    function setUp() public {
        Drips dripsLogic = new Drips(10);
        drips = Drips(address(new ManagedProxy(dripsLogic, address(this))));

        caller = new Caller();

        // Make NFTCampaignDriver's driver ID non-0 to test if it's respected by NFTCampaignDriver
        drips.registerDriver(address(1));
        drips.registerDriver(address(1));
        uint32 driverId = drips.registerDriver(address(this));
        NFTCampaignDriver driverLogic = new NFTCampaignDriver(drips, address(caller), driverId);
        driver = NFTCampaignDriver(address(new ManagedProxy(driverLogic, admin)));
        drips.updateDriverAddress(driverId, address(driver));

        // Register access checker
        IAccessControlChecker accessChecker = new AddressDriverAccessChecker();
        vm.prank(admin);
        driver.registerAccessChecker(driverId, accessChecker);

        thisId = driver.calcAccountId(address(this));
        accountId = driver.calcAccountId(user);

        erc20 = new ERC20PresetFixedSupply("test", "test", type(uint136).max, address(this));
        erc20.approve(address(driver), type(uint256).max);
        erc20.transfer(user, erc20.totalSupply() / 100);
        vm.prank(user);
        erc20.approve(address(driver), type(uint256).max);
    }

    function testSetStreams() public {
        uint128 amt = 5;

        // Top-up

        StreamReceiver[] memory receivers = new StreamReceiver[](1);
        receivers[0] = StreamReceiver(accountId, StreamConfigImpl.create(0, drips.minAmtPerSec(), 0, 0));
        uint256 balance = erc20.balanceOf(address(this));

        int128 realBalanceDelta =
            driver.setStreams(erc20, new StreamReceiver[](0), int128(amt), receivers, 0, 0, address(this));

        assertEq(erc20.balanceOf(address(this)), balance - amt, "Invalid balance after top-up");
        assertEq(erc20.balanceOf(address(drips)), amt, "Invalid Drips balance after top-up");
        (,,, uint128 streamsBalance,) = drips.streamsState(thisId, erc20);
        assertEq(streamsBalance, amt, "Invalid streams balance after top-up");
        assertEq(realBalanceDelta, int128(amt), "Invalid streams balance delta after top-up");
        (bytes32 streamsHash,,,,) = drips.streamsState(thisId, erc20);
        assertEq(streamsHash, drips.hashStreams(receivers), "Invalid streams hash after top-up");

        // Withdraw
        balance = erc20.balanceOf(address(user));

        realBalanceDelta = driver.setStreams(erc20, receivers, -int128(amt), receivers, 0, 0, address(user));

        assertEq(erc20.balanceOf(address(user)), balance + amt, "Invalid balance after withdrawal");
        assertEq(erc20.balanceOf(address(drips)), 0, "Invalid Drips balance after withdrawal");
        (,,, streamsBalance,) = drips.streamsState(thisId, erc20);
        assertEq(streamsBalance, 0, "Invalid streams balance after withdrawal");
        assertEq(realBalanceDelta, -int128(amt), "Invalid streams balance delta after withdrawal");
    }

    function testSetStreamsDecreasingBalanceTransfersFundsToTheProvidedAddress() public {
        uint128 amt = 5;
        StreamReceiver[] memory receivers = new StreamReceiver[](0);
        driver.setStreams(erc20, receivers, int128(amt), receivers, 0, 0, address(this));
        address transferTo = address(1234);

        int128 realBalanceDelta = driver.setStreams(erc20, receivers, -int128(amt), receivers, 0, 0, transferTo);

        assertEq(erc20.balanceOf(transferTo), amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), 0, "Invalid Drips balance");
        (,,, uint128 streamsBalance,) = drips.streamsState(thisId, erc20);
        assertEq(streamsBalance, 0, "Invalid streams balance");
        assertEq(realBalanceDelta, -int128(amt), "Invalid streams balance delta");
    }

    function testEmitAccountMetadata() public {
        AccountMetadata[] memory accountMetadata = new AccountMetadata[](1);
        accountMetadata[0] = AccountMetadata("key", "value");
        driver.emitAccountMetadata(accountMetadata);
    }

    function _setupStreams() internal {
        uint128 amt = 5;

        // Top-up

        StreamReceiver[] memory receivers = new StreamReceiver[](1);
        receivers[0] = StreamReceiver(accountId, StreamConfigImpl.create(0, drips.minAmtPerSec(), 0, 0));

        driver.setStreams(erc20, new StreamReceiver[](0), int128(amt), receivers, 0, 0, address(this));
    }

    function testSetStreamsMintsNFT() public {
        _setupStreams();

        uint256 nftBalance = driver.balanceOf(address(this));
        assertEq(nftBalance, 1, "NFT not minted");
    }

    function testBlocksNFTTransfers() public {
        _setupStreams();
        uint256 tokenId = driver.calcTokenId(address(this), accountId, erc20);

        // Should revert transfer
        vm.expectRevert();
        driver.transferFrom(address(this), user, tokenId);
    }

    function testShowMetadata() public {
        _setupStreams();
        uint256 tokenId = driver.calcTokenId(address(this), accountId, erc20);

        string memory metadata = driver.tokenURI(tokenId);
        console.log(metadata);
        vm.warp(60);
        metadata = driver.tokenURI(tokenId);
        console.log(metadata);
    }

    function testNFTIsInactiveOutsideSuppportRange() public {
        uint256 tokenId = driver.calcTokenId(address(this), accountId, erc20);
        // Top-up
        StreamReceiver[] memory receivers = new StreamReceiver[](1);
        receivers[0] = StreamReceiver(accountId, StreamConfigImpl.create(0, drips.minAmtPerSec(), 0, 0));

        driver.setStreams(erc20, new StreamReceiver[](0), 5, receivers, 0, 0, address(this));
        (bool isActive,) = driver.getTokenState(tokenId);
        assertTrue(isActive, "NFT should be active");
        skip(60);
        (isActive,) = driver.getTokenState(tokenId);
        assertFalse(isActive, "NFT should be inactive");

        // Change receiver configuration to start in the future
        StreamReceiver[] memory newReceivers = new StreamReceiver[](1);
        newReceivers[0] =
            StreamReceiver(accountId, StreamConfigImpl.create(0, drips.minAmtPerSec(), uint32(block.timestamp + 60), 0));
        driver.setStreams(erc20, receivers, 5, newReceivers, 0, 0, address(this));
        (isActive,) = driver.getTokenState(tokenId);
        assertFalse(isActive, "NFT should be inactive");
        skip(60);
        (isActive,) = driver.getTokenState(tokenId);
        assertTrue(isActive, "NFT should be active");
        skip(60);
        (isActive,) = driver.getTokenState(tokenId);
        assertFalse(isActive, "NFT should be inactive");
    }

    function testNFTIsInactiveWhenStreamIsRemoved() public {
        uint256 tokenId = driver.calcTokenId(address(this), accountId, erc20);
        // Top-up
        StreamReceiver[] memory receivers = new StreamReceiver[](1);
        receivers[0] = StreamReceiver(accountId, StreamConfigImpl.create(0, drips.minAmtPerSec(), 0, 0));

        driver.setStreams(erc20, new StreamReceiver[](0), 5, receivers, 0, 0, address(this));
        (bool isActive,) = driver.getTokenState(tokenId);
        assertTrue(isActive, "NFT should be active");

        // Remove stream
        driver.setStreams(erc20, receivers, -5, new StreamReceiver[](0), 0, 0, address(this));
        (isActive,) = driver.getTokenState(tokenId);
        assertFalse(isActive, "NFT should be inactive");
    }

    function testOnlyAddressWithAccountAccessCanUpdateMetadata() public {
        string memory imageURITemplate = "https://drips.network/path/to/image/{id}";
        string memory externalUrl = "https://drips.network/path/to/docs";
        string memory customData = "{}";

        vm.expectRevert();
        driver.setReceiverNFTConfig(accountId, imageURITemplate, externalUrl);
        vm.expectRevert();
        driver.setReceiverNFTConfigCustomData(accountId, customData);

        driver.setReceiverNFTConfig(thisId, imageURITemplate, externalUrl);
        driver.setReceiverNFTConfigCustomData(thisId, customData);

        (string memory imageURI, string memory externalURI, string memory customData_) =
            driver.getReceiverNFTConfig(thisId);
        assertEq(imageURI, imageURITemplate, "Invalid image URI");
        assertEq(externalURI, externalUrl, "Invalid external URI");
        assertEq(customData_, customData, "Invalid custom data");
    }
}
