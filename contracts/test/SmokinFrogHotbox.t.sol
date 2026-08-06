// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SmokinFrogHotbox} from "../src/SmokinFrogHotbox.sol";
import {IERC721Receiver} from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC2981} from "openzeppelin-contracts/contracts/interfaces/IERC2981.sol";

contract Reenterer is IERC721Receiver {
    SmokinFrogHotbox public nft;
    bool public attack;
    constructor(SmokinFrogHotbox nft_) { nft = nft_; }
    function doMint(uint256 artId) external payable { nft.mint{value: msg.value}(artId); }
    function setAttack(bool v) external { attack = v; }
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (attack) { attack = false; nft.mint{value: 0.05 ether}(1); }
        return IERC721Receiver.onERC721Received.selector;
    }
    receive() external payable {}
}

contract PayoutRejector {}

contract Selfdestructor {
    constructor() payable {}
    function boom(address target) external { selfdestruct(payable(target)); }
}

contract SmokinFrogHotboxTest is Test {
    SmokinFrogHotbox nft;
    address owner = makeAddr("owner");
    address payout = makeAddr("payout");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // test collection: 10 arts covering every tier, then commons
    // art1 Common(0), art2 Uncommon(1), art3 Rare(2), art4 Epic(3), art5 Legendary(4), art6-10 Common(0)
    bytes constant TIERS = hex"00010203040000000000";
    string constant BASE = "https://smokinfrog-production.up.railway.app/nft/meta/";

    // caps / base prices by tier index
    function _cap(uint8 t) internal pure returns (uint256) {
        if (t == 0) return 25; if (t == 1) return 12; if (t == 2) return 6; if (t == 3) return 3; return 1;
    }
    function _base(uint8 t) internal pure returns (uint256) {
        if (t == 0) return 0.01 ether; if (t == 1) return 0.02 ether; if (t == 2) return 0.04 ether;
        if (t == 3) return 0.08 ether; return 0.25 ether;
    }

    function setUp() public {
        vm.prank(owner);
        nft = new SmokinFrogHotbox(TIERS, BASE, payout);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    // ------------------------------------------------------------ construction

    function test_constructorState() public view {
        assertEq(nft.artCount(), 10);
        // maxSupply = 25+12+6+3+1 + 5*25 = 47 + 125 = 172
        assertEq(nft.maxSupply(), 172);
        assertEq(nft.payout(), payout);
        assertEq(nft.owner(), owner);
        assertEq(nft.totalMinted(), 0);
    }

    function test_constructorRejectsEmpty() public {
        vm.expectRevert(bytes("no arts"));
        new SmokinFrogHotbox(hex"", BASE, payout);
    }

    function test_constructorRejectsZeroPayout() public {
        vm.expectRevert(bytes("zero payout"));
        new SmokinFrogHotbox(TIERS, BASE, address(0));
    }

    function test_constructorRejectsBadTier() public {
        vm.expectRevert(bytes("bad tier"));
        new SmokinFrogHotbox(hex"05", BASE, payout); // tier 5 invalid
    }

    // ---------------------------------------------------------------- tiers

    function test_tierAndCapAndBasePrice() public view {
        for (uint256 a = 1; a <= 10; a++) {
            uint8 t = uint8(TIERS[a - 1]);
            assertEq(nft.tierOf(a), t);
            assertEq(nft.capOf(a), _cap(t));
            assertEq(nft.priceOf(a), _base(t));
            assertEq(nft.remainingOf(a), _cap(t));
        }
    }

    function test_tierOfBounds() public {
        vm.expectRevert(bytes("unknown art"));
        nft.tierOf(0);
        vm.expectRevert(bytes("unknown art"));
        nft.tierOf(11);
    }

    // ---------------------------------------------------------------- pricing

    function test_priceRises5PercentPerMint() public {
        uint256 expected = 0.01 ether; // art1 common
        for (uint256 i = 0; i < 8; i++) {
            assertEq(nft.priceOf(1), expected);
            vm.prank(alice);
            nft.mint{value: expected}(1);
            expected = (expected * 105) / 100;
        }
    }

    function test_pricesIndependentPerArt() public {
        vm.startPrank(alice);
        nft.mint{value: 0.01 ether}(1);   // common
        nft.mint{value: 0.02 ether}(2);   // uncommon
        vm.stopPrank();
        assertEq(nft.priceOf(1), 0.0105 ether);
        assertEq(nft.priceOf(2), 0.021 ether);
        assertEq(nft.priceOf(3), 0.04 ether);
    }

    // ---------------------------------------------------------------- minting

    function test_mintHappyPathPaysPayout() public {
        vm.prank(alice);
        uint256 tokenId = nft.mint{value: 0.04 ether}(3); // rare
        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.artOf(1), 3);
        assertEq(nft.totalMinted(), 1);
        assertEq(payout.balance, 0.04 ether);
        assertEq(nft.mintedOf(3), 1);
        assertEq(nft.remainingOf(3), 5);
    }

    function test_mintRefundsExcess() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        nft.mint{value: 1 ether}(4); // epic, price 0.08
        assertEq(alice.balance, before - 0.08 ether);
        assertEq(payout.balance, 0.08 ether);
        assertEq(address(nft).balance, 0);
    }

    function test_mintRejectsUnderpay() public {
        vm.prank(alice);
        vm.expectRevert(bytes("underpaid"));
        nft.mint{value: 0.04 ether - 1}(3);
    }

    function test_mintRejectsUnknownArt() public {
        vm.startPrank(alice);
        vm.expectRevert(bytes("unknown art"));
        nft.mint{value: 1 ether}(0);
        vm.expectRevert(bytes("unknown art"));
        nft.mint{value: 1 ether}(11);
        vm.stopPrank();
    }

    function test_legendaryIsOneOfOne() public {
        vm.prank(alice);
        nft.mint{value: 0.25 ether}(5); // legendary, cap 1
        assertEq(nft.remainingOf(5), 0);
        vm.prank(bob);
        vm.expectRevert(bytes("sold out"));
        nft.mint{value: 1 ether}(5);
    }

    function test_soldOutAtCapAndSupplyBounded() public {
        // rare art3 has cap 6
        vm.startPrank(alice);
        uint256 price = 0.04 ether;
        for (uint256 i = 0; i < 6; i++) {
            nft.mint{value: price}(3);
            price = (price * 105) / 100;
        }
        vm.stopPrank();
        assertEq(nft.mintedOf(3), 6);
        assertEq(nft.remainingOf(3), 0);
        vm.prank(bob);
        vm.expectRevert(bytes("sold out"));
        nft.mint{value: 10 ether}(3);
    }

    function test_cannotExceedMaxSupply() public {
        // mint the entire collection (172) and confirm every art is sold out
        uint256 total;
        for (uint256 a = 1; a <= 10; a++) {
            uint256 cap = nft.capOf(a);
            uint256 price = nft.priceOf(a);
            for (uint256 i = 0; i < cap; i++) {
                vm.prank(alice);
                nft.mint{value: price}(a);
                price = (price * 105) / 100;
                total++;
            }
            vm.prank(alice);
            vm.expectRevert(bytes("sold out"));
            nft.mint{value: 100 ether}(a);
        }
        assertEq(total, 172);
        assertEq(nft.totalMinted(), 172);
        assertEq(nft.totalMinted(), nft.maxSupply());
    }

    function test_reentrancyBlocked() public {
        Reenterer r = new Reenterer(nft);
        vm.deal(address(r), 1 ether);
        r.setAttack(true);
        vm.expectRevert();
        r.doMint{value: 0.05 ether}(1);
        assertEq(nft.totalMinted(), 0);
    }

    function test_payoutFailureReverts() public {
        PayoutRejector pr = new PayoutRejector();
        vm.prank(owner);
        nft.setPayout(address(pr));
        vm.prank(alice);
        vm.expectRevert(bytes("payout failed"));
        nft.mint{value: 0.01 ether}(1);
    }

    function testFuzz_priceSeriesWithinCap(uint8 mints) public {
        uint256 n = bound(mints, 1, 25); // common cap
        uint256 expected = 0.01 ether;
        for (uint256 i = 0; i < n; i++) {
            vm.deal(alice, expected);
            vm.prank(alice);
            nft.mint{value: expected}(6);
            expected = (expected * 105) / 100;
        }
        assertEq(nft.priceOf(6), expected);
        assertEq(nft.mintedOf(6), n);
    }

    // ------------------------------------------------------------------ views

    function test_getState() public {
        vm.startPrank(alice);
        nft.mint{value: 0.01 ether}(1);
        nft.mint{value: 0.0105 ether}(1);
        nft.mint{value: 0.25 ether}(5);
        vm.stopPrank();
        (uint256[] memory prices, uint256[] memory minted, uint256[] memory caps, uint256[] memory tiers) = nft.getState();
        assertEq(prices.length, 10);
        assertEq(caps.length, 10);
        assertEq(tiers.length, 10);
        assertEq(prices[0], 0.011025 ether); // art1 minted twice
        assertEq(minted[0], 2);
        assertEq(caps[0], 25);
        assertEq(tiers[0], 0);
        assertEq(caps[4], 1); // art5 legendary
        assertEq(tiers[4], 4);
        assertEq(minted[4], 1);
    }

    function test_tokenURI() public {
        vm.prank(alice);
        nft.mint{value: 0.02 ether}(2);
        assertEq(nft.tokenURI(1), string.concat(BASE, "2.json"));
    }

    function test_contractURI() public view {
        assertEq(nft.contractURI(), string.concat(BASE, "collection.json"));
    }

    function test_supportsInterface() public view {
        assertTrue(nft.supportsInterface(0x01ffc9a7)); // ERC165
        assertTrue(nft.supportsInterface(0x80ac58cd)); // ERC721
        assertTrue(nft.supportsInterface(0x5b5e139f)); // ERC721Metadata
        assertTrue(nft.supportsInterface(0x2a55205a)); // ERC2981
    }

    function test_royaltyInfo() public view {
        (address receiver, uint256 amount) = IERC2981(address(nft)).royaltyInfo(1, 1 ether);
        assertEq(receiver, payout);
        assertEq(amount, 0.05 ether);
    }

    // ------------------------------------------------------------------ admin

    function test_adminOnlyOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        nft.setBaseURI("x");
        vm.expectRevert();
        nft.setPayout(alice);
        vm.expectRevert();
        nft.setPrice(1, 1);
        vm.stopPrank();
    }

    function test_setPayoutRedirectsProceedsAndRoyalty() public {
        address np = makeAddr("np");
        vm.prank(owner);
        nft.setPayout(np);
        vm.prank(alice);
        nft.mint{value: 0.01 ether}(1);
        assertEq(np.balance, 0.01 ether);
        assertEq(payout.balance, 0);
        (address receiver, uint256 amt) = IERC2981(address(nft)).royaltyInfo(1, 1 ether);
        assertEq(receiver, np);
        assertEq(amt, 0.05 ether);
    }

    function test_setPrice() public {
        vm.prank(owner);
        nft.setPrice(1, 0.5 ether);
        assertEq(nft.priceOf(1), 0.5 ether);
        vm.prank(alice);
        nft.mint{value: 0.5 ether}(1);
        assertEq(nft.priceOf(1), 0.525 ether);
        // setPrice cannot change caps: art1 still capped at 25
        assertEq(nft.capOf(1), 25);
    }

    function test_sweepForceSentEth() public {
        Selfdestructor sd = new Selfdestructor{value: 0.3 ether}();
        sd.boom(address(nft));
        assertEq(address(nft).balance, 0.3 ether);
        nft.sweep();
        assertEq(address(nft).balance, 0);
        assertEq(payout.balance, 0.3 ether);
    }

    // --------------------------------------------------- real 99-art assignment

    function test_realAssignmentSupplyAndTiers() public {
        // the exact tier bytes shipped to mainnet (from gen_tiers.js, seed 20080806)
        bytes memory real = hex"010101000100010000000004010100030002010100030103000202020003020201040100010000010200010201030101020001000101000000020100000001000100010000020000020402000001020100020003000001030002000001010300020002";
        assertEq(real.length, 99);
        vm.prank(owner);
        SmokinFrogHotbox big = new SmokinFrogHotbox(real, BASE, payout);
        assertEq(big.artCount(), 99);
        assertEq(big.maxSupply(), 1495);
        // legendary arts (tier 4): 12, 34, 74 -> cap 1, price 0.25
        assertEq(big.tierOf(12), 4);
        assertEq(big.capOf(12), 1);
        assertEq(big.priceOf(12), 0.25 ether);
        assertEq(big.tierOf(34), 4);
        assertEq(big.tierOf(74), 4);
        // spot-check an epic (16) cap 3 price 0.08
        assertEq(big.tierOf(16), 3);
        assertEq(big.capOf(16), 3);
        assertEq(big.priceOf(16), 0.08 ether);
        // count tiers across all 99 arts
        uint256[5] memory byTier;
        for (uint256 a = 1; a <= 99; a++) byTier[big.tierOf(a)]++;
        assertEq(byTier[0], 40); // common
        assertEq(byTier[1], 30); // uncommon
        assertEq(byTier[2], 18); // rare
        assertEq(byTier[3], 8);  // epic
        assertEq(byTier[4], 3);  // legendary
    }

    // -------------------------------------------------------- secondary market

    function _mintTo(address who, uint256 artId) internal returns (uint256 tokenId) {
        uint256 price = nft.priceOf(artId);
        vm.prank(who);
        tokenId = nft.mint{value: price}(artId);
    }

    function test_listBuyDelistSplit() public {
        uint256 t = _mintTo(alice, 1);
        vm.prank(alice);
        nft.list(t, 2 ether);
        uint256 aliceBefore = alice.balance;
        uint256 payoutBefore = payout.balance;
        vm.prank(bob);
        nft.buy{value: 2 ether}(t);
        assertEq(nft.ownerOf(t), bob);
        assertEq(alice.balance - aliceBefore, 1.9 ether);   // 95%
        assertEq(payout.balance - payoutBefore, 0.1 ether); // 5% royalty
        (address seller, uint96 lp) = nft.listingOf(t);
        assertEq(seller, address(0));
        assertEq(lp, 0);
        assertEq(address(nft).balance, 0);
    }

    function test_buyGuardsAndTransferCancelsListing() public {
        uint256 t = _mintTo(alice, 1);
        vm.prank(bob);
        vm.expectRevert(bytes("not listed"));
        nft.buy{value: 1 ether}(t);
        vm.prank(alice);
        nft.list(t, 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("own token"));
        nft.buy{value: 1 ether}(t);
        // transfer cancels the listing
        vm.prank(alice);
        nft.transferFrom(alice, bob, t);
        (address seller,) = nft.listingOf(t);
        assertEq(seller, address(0));
    }

    function test_getTokensPagination() public {
        uint256 t1 = _mintTo(alice, 1);
        uint256 t2 = _mintTo(bob, 5);
        vm.prank(bob);
        nft.list(t2, 7 ether);
        (uint256[] memory arts, address[] memory owners, uint256[] memory lps) = nft.getTokens(1, 400);
        assertEq(arts.length, 2);
        assertEq(arts[0], 1);
        assertEq(arts[1], 5);
        assertEq(owners[0], alice);
        assertEq(lps[1], 7 ether);
        (arts,,) = nft.getTokens(0, 0);
        assertEq(arts.length, 0);
        assertEq(t1, 1);
    }
}
