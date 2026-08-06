// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SmokinFrogHotbox} from "../src/SmokinFrogHotbox.sol";
import {IERC721Receiver} from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC2981} from "openzeppelin-contracts/contracts/interfaces/IERC2981.sol";

contract Reenterer is IERC721Receiver {
    SmokinFrogHotbox public nft;
    bool public attack;

    constructor(SmokinFrogHotbox nft_) {
        nft = nft_;
    }

    function doMint(uint256 artId) external payable {
        nft.mint{value: msg.value}(artId);
    }

    function setAttack(bool v) external {
        attack = v;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (attack) {
            attack = false;
            nft.mint{value: 0.02 ether}(1); // re-entry attempt
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// Overpays but refuses the refund (no receive function).
contract RefundRejector is IERC721Receiver {
    function doMint(SmokinFrogHotbox nft, uint256 artId) external payable {
        nft.mint{value: msg.value}(artId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract PayoutRejector {
    // rejects all ETH
}

/// Buyer that re-enters buy() from the ERC721 receive hook.
contract BuyReenterer is IERC721Receiver {
    SmokinFrogHotbox public nft;
    bool public attack;

    constructor(SmokinFrogHotbox nft_) {
        nft = nft_;
    }

    function doBuy(uint256 tokenId) external payable {
        attack = true;
        nft.buy{value: msg.value}(tokenId);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (attack) {
            attack = false;
            nft.buy{value: 1 ether}(tokenId); // re-entry attempt mid-buy
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// Seller that refuses the sale proceeds (no receive function).
contract SellerRejector is IERC721Receiver {
    function doMint(SmokinFrogHotbox nft, uint256 artId) external payable {
        nft.mint{value: msg.value}(artId);
    }

    function doList(SmokinFrogHotbox nft, uint256 tokenId, uint96 price) external {
        nft.list(tokenId, price);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract Selfdestructor {
    constructor() payable {}

    function boom(address target) external {
        selfdestruct(payable(target));
    }
}

contract SmokinFrogHotboxTest is Test {
    SmokinFrogHotbox nft;
    address owner = makeAddr("owner");
    address payout = makeAddr("payout");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant N = 99;
    string constant BASE = "https://smokinfrog-production.up.railway.app/nft/meta/";

    event Minted(
        address indexed minter,
        uint256 indexed artId,
        uint256 indexed tokenId,
        uint256 price,
        uint256 nextPrice
    );

    function setUp() public {
        vm.prank(owner);
        nft = new SmokinFrogHotbox(N, BASE, payout);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ------------------------------------------------------------ construction

    function test_constructorState() public view {
        assertEq(nft.artCount(), N);
        assertEq(nft.baseURI(), BASE);
        assertEq(nft.payout(), payout);
        assertEq(nft.owner(), owner);
        assertEq(nft.totalMinted(), 0);
        assertEq(nft.name(), "Smokin Frog Hotbox");
        assertEq(nft.symbol(), "SFROGNFT");
    }

    function test_constructorRejectsZeroArts() public {
        vm.expectRevert(bytes("no arts"));
        new SmokinFrogHotbox(0, BASE, payout);
    }

    function test_constructorRejectsZeroPayout() public {
        vm.expectRevert(bytes("zero payout"));
        new SmokinFrogHotbox(N, BASE, address(0));
    }

    // ---------------------------------------------------------------- pricing

    function test_initialPriceIsBase() public view {
        for (uint256 i = 1; i <= N; i++) {
            assertEq(nft.priceOf(i), 0.01 ether);
        }
    }

    function test_priceRises5PercentPerMint() public {
        uint256 expected = 0.01 ether;
        for (uint256 i = 0; i < 10; i++) {
            assertEq(nft.priceOf(7), expected);
            vm.prank(alice);
            nft.mint{value: expected}(7);
            expected = (expected * 105) / 100;
        }
        // known values: 0.01 -> 0.0105 -> 0.011025
        SmokinFrogHotbox fresh;
        vm.prank(owner);
        fresh = new SmokinFrogHotbox(N, BASE, payout);
        vm.startPrank(alice);
        fresh.mint{value: 0.01 ether}(1);
        assertEq(fresh.priceOf(1), 0.0105 ether);
        fresh.mint{value: 0.0105 ether}(1);
        assertEq(fresh.priceOf(1), 0.011025 ether);
        vm.stopPrank();
    }

    function test_pricesIndependentPerArt() public {
        vm.startPrank(alice);
        nft.mint{value: 0.01 ether}(1);
        nft.mint{value: 0.0105 ether}(1);
        nft.mint{value: 0.01 ether}(2);
        vm.stopPrank();
        assertEq(nft.priceOf(1), 0.011025 ether);
        assertEq(nft.priceOf(2), 0.0105 ether);
        assertEq(nft.priceOf(3), 0.01 ether);
        assertEq(nft.mintedOf(1), 2);
        assertEq(nft.mintedOf(2), 1);
        assertEq(nft.mintedOf(3), 0);
    }

    // ---------------------------------------------------------------- minting

    function test_mintHappyPath() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Minted(alice, 42, 1, 0.01 ether, 0.0105 ether);
        uint256 tokenId = nft.mint{value: 0.01 ether}(42);
        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.artOf(1), 42);
        assertEq(nft.totalMinted(), 1);
        assertEq(nft.balanceOf(alice), 1);
        assertEq(payout.balance, 0.01 ether);
    }

    function test_mintRejectsUnderpay() public {
        vm.prank(alice);
        vm.expectRevert(bytes("underpaid"));
        nft.mint{value: 0.01 ether - 1}(1);
    }

    function test_mintRejectsUnknownArt() public {
        vm.startPrank(alice);
        vm.expectRevert(bytes("unknown art"));
        nft.mint{value: 0.01 ether}(0);
        vm.expectRevert(bytes("unknown art"));
        nft.mint{value: 0.01 ether}(N + 1);
        vm.stopPrank();
    }

    function test_mintRefundsExcess() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        nft.mint{value: 1 ether}(5);
        assertEq(alice.balance, before - 0.01 ether);
        assertEq(payout.balance, 0.01 ether);
        assertEq(address(nft).balance, 0);
    }

    function test_payoutReceivesExactPriceEachMint() public {
        vm.prank(alice);
        nft.mint{value: 0.01 ether}(1);
        vm.prank(bob);
        nft.mint{value: 0.0105 ether}(1);
        assertEq(payout.balance, 0.0205 ether);
        assertEq(address(nft).balance, 0);
    }

    function test_sequentialTokenIdsAcrossArts() public {
        vm.startPrank(alice);
        nft.mint{value: 0.01 ether}(10);
        nft.mint{value: 0.01 ether}(20);
        nft.mint{value: 0.0105 ether}(10);
        vm.stopPrank();
        assertEq(nft.artOf(1), 10);
        assertEq(nft.artOf(2), 20);
        assertEq(nft.artOf(3), 10);
        assertEq(nft.totalMinted(), 3);
    }

    function test_reentrancyBlocked() public {
        Reenterer r = new Reenterer(nft);
        vm.deal(address(r), 1 ether);
        r.setAttack(true);
        vm.expectRevert(); // inner nonReentrant revert bubbles up through _safeMint
        r.doMint{value: 0.05 ether}(1);
        assertEq(nft.totalMinted(), 0);
    }

    function test_mintToContractReceiverWorks() public {
        Reenterer r = new Reenterer(nft);
        vm.deal(address(r), 1 ether);
        r.doMint{value: 0.01 ether}(3);
        assertEq(nft.ownerOf(1), address(r));
    }

    function test_refundFailureReverts() public {
        RefundRejector rr = new RefundRejector();
        vm.deal(address(rr), 1 ether);
        vm.expectRevert(bytes("refund failed"));
        rr.doMint{value: 0.02 ether}(nft, 1);
        // exact payment needs no refund, so it works
        rr.doMint{value: 0.01 ether}(nft, 1);
        assertEq(nft.ownerOf(1), address(rr));
    }

    function test_payoutFailureReverts() public {
        PayoutRejector pr = new PayoutRejector();
        vm.prank(owner);
        nft.setPayout(address(pr));
        vm.prank(alice);
        vm.expectRevert(bytes("payout failed"));
        nft.mint{value: 0.01 ether}(1);
    }

    function test_overpaidMintDoesNotInflateNextPrice() public {
        vm.prank(alice);
        nft.mint{value: 1 ether}(5);
        assertEq(nft.priceOf(5), 0.0105 ether);
    }

    function testFuzz_overpaidSeriesKeepsExactPricing(uint96 pad, uint8 mints) public {
        uint256 n = bound(mints, 1, 30);
        uint256 padWei = bound(uint256(pad), 0, 10 ether);
        uint256 expected = 0.01 ether;
        uint256 paidTotal;
        vm.startPrank(alice);
        for (uint256 i = 0; i < n; i++) {
            vm.deal(alice, expected + padWei);
            nft.mint{value: expected + padWei}(11);
            paidTotal += expected;
            expected = (expected * 105) / 100;
        }
        vm.stopPrank();
        assertEq(nft.priceOf(11), expected);
        assertEq(payout.balance, paidTotal);
        assertEq(alice.balance, padWei); // last mint's pad fully refunded
    }

    function test_supportsInterface() public view {
        assertTrue(nft.supportsInterface(0x01ffc9a7)); // ERC165
        assertTrue(nft.supportsInterface(0x80ac58cd)); // ERC721
        assertTrue(nft.supportsInterface(0x5b5e139f)); // ERC721Metadata
        assertTrue(nft.supportsInterface(0x2a55205a)); // ERC2981
    }

    function testFuzz_priceSeries(uint8 mints) public {
        uint256 n = bound(mints, 1, 60);
        uint256 expected = 0.01 ether;
        vm.startPrank(alice);
        for (uint256 i = 0; i < n; i++) {
            vm.deal(alice, expected);
            nft.mint{value: expected}(9);
            expected = (expected * 105) / 100;
        }
        vm.stopPrank();
        assertEq(nft.priceOf(9), expected);
        assertEq(nft.mintedOf(9), n);
    }

    // ------------------------------------------------------------------ views

    function test_getState() public {
        vm.startPrank(alice);
        nft.mint{value: 0.01 ether}(1);
        nft.mint{value: 0.0105 ether}(1);
        nft.mint{value: 0.01 ether}(99);
        vm.stopPrank();
        (uint256[] memory prices, uint256[] memory minted) = nft.getState();
        assertEq(prices.length, N);
        assertEq(minted.length, N);
        assertEq(prices[0], 0.011025 ether);
        assertEq(minted[0], 2);
        assertEq(prices[1], 0.01 ether);
        assertEq(minted[1], 0);
        assertEq(prices[98], 0.0105 ether);
        assertEq(minted[98], 1);
    }

    function test_tokenURI() public {
        vm.prank(alice);
        nft.mint{value: 0.01 ether}(42);
        assertEq(nft.tokenURI(1), string.concat(BASE, "42.json"));
        vm.expectRevert();
        nft.tokenURI(2);
    }

    function test_contractURI() public view {
        assertEq(nft.contractURI(), string.concat(BASE, "collection.json"));
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
        nft.addArts(1);
        vm.expectRevert();
        nft.setPrice(1, 1);
        vm.stopPrank();
    }

    function test_setBaseURI() public {
        vm.prank(owner);
        nft.setBaseURI("https://other.example/m/");
        vm.prank(alice);
        nft.mint{value: 0.01 ether}(7);
        assertEq(nft.tokenURI(1), "https://other.example/m/7.json");
    }

    function test_setPayoutRedirectsProceedsAndRoyalty() public {
        address newPayout = makeAddr("newPayout");
        vm.prank(owner);
        nft.setPayout(newPayout);
        vm.prank(alice);
        nft.mint{value: 0.01 ether}(1);
        assertEq(newPayout.balance, 0.01 ether);
        assertEq(payout.balance, 0);
        (address receiver, uint256 amt) = IERC2981(address(nft)).royaltyInfo(1, 1 ether);
        assertEq(receiver, newPayout);
        assertEq(amt, 0.05 ether);
        vm.prank(owner);
        vm.expectRevert(bytes("zero payout"));
        nft.setPayout(address(0));
    }

    function test_addArts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("unknown art"));
        nft.mint{value: 0.01 ether}(100);
        vm.prank(owner);
        nft.addArts(1);
        assertEq(nft.artCount(), 100);
        vm.prank(alice);
        nft.mint{value: 0.01 ether}(100);
        assertEq(nft.artOf(1), 100);
        (uint256[] memory prices,) = nft.getState();
        assertEq(prices.length, 100);
    }

    function test_setPrice() public {
        vm.prank(owner);
        nft.setPrice(1, 0.5 ether);
        assertEq(nft.priceOf(1), 0.5 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("underpaid"));
        nft.mint{value: 0.01 ether}(1);
        vm.prank(alice);
        nft.mint{value: 0.5 ether}(1);
        assertEq(nft.priceOf(1), 0.525 ether);
        vm.startPrank(owner);
        vm.expectRevert(bytes("unknown art"));
        nft.setPrice(0, 1);
        vm.expectRevert(bytes("zero price"));
        nft.setPrice(1, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------- secondary market

    function _mintTo(address who, uint256 artId) internal returns (uint256 tokenId) {
        uint256 price = nft.priceOf(artId); // read before prank — the inner call would consume it
        vm.prank(who);
        tokenId = nft.mint{value: price}(artId);
    }

    function test_listAndBuyHappyPath() public {
        uint256 t = _mintTo(alice, 1);
        vm.prank(alice);
        nft.list(t, 2 ether);
        (address seller, uint96 lp) = nft.listingOf(t);
        assertEq(seller, alice);
        assertEq(lp, 2 ether);

        uint256 aliceBefore = alice.balance;
        uint256 payoutBefore = payout.balance;
        vm.prank(bob);
        nft.buy{value: 2 ether}(t);

        assertEq(nft.ownerOf(t), bob);
        assertEq(alice.balance - aliceBefore, 1.9 ether);   // 95%
        assertEq(payout.balance - payoutBefore, 0.1 ether); // 5% royalty
        (seller, lp) = nft.listingOf(t);
        assertEq(seller, address(0)); // listing consumed
        assertEq(lp, 0);
        assertEq(address(nft).balance, 0);
    }

    function test_listRequiresOwnerAndNonZeroPrice() public {
        uint256 t = _mintTo(alice, 1);
        vm.prank(bob);
        vm.expectRevert(); // ERC721 revert via ownerOf mismatch path
        nft.list(t, 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("zero price"));
        nft.list(t, 0);
        vm.prank(alice);
        vm.expectRevert(); // nonexistent token
        nft.list(999, 1 ether);
    }

    function test_relistOverwritesPrice() public {
        uint256 t = _mintTo(alice, 1);
        vm.startPrank(alice);
        nft.list(t, 1 ether);
        nft.list(t, 3 ether);
        vm.stopPrank();
        (, uint96 lp) = nft.listingOf(t);
        assertEq(lp, 3 ether);
    }

    function test_delist() public {
        uint256 t = _mintTo(alice, 1);
        vm.prank(alice);
        vm.expectRevert(bytes("not listed"));
        nft.delist(t);
        vm.prank(alice);
        nft.list(t, 1 ether);
        vm.prank(bob);
        vm.expectRevert(bytes("not yours"));
        nft.delist(t);
        vm.prank(alice);
        nft.delist(t);
        (address seller, uint96 lp) = nft.listingOf(t);
        assertEq(seller, address(0));
        assertEq(lp, 0);
        vm.prank(bob);
        vm.expectRevert(bytes("not listed"));
        nft.buy{value: 1 ether}(t);
    }

    function test_buyGuards() public {
        uint256 t = _mintTo(alice, 1);
        vm.prank(bob);
        vm.expectRevert(bytes("not listed"));
        nft.buy{value: 1 ether}(t);
        vm.prank(alice);
        nft.list(t, 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("own token"));
        nft.buy{value: 1 ether}(t);
        vm.prank(bob);
        vm.expectRevert(bytes("underpaid"));
        nft.buy{value: 1 ether - 1}(t);
    }

    function test_buyRefundsExcess() public {
        uint256 t = _mintTo(alice, 1);
        vm.prank(alice);
        nft.list(t, 1 ether);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        nft.buy{value: 5 ether}(t);
        assertEq(bobBefore - bob.balance, 1 ether);
        assertEq(address(nft).balance, 0);
    }

    function test_transferCancelsListing() public {
        uint256 t = _mintTo(alice, 1);
        vm.prank(alice);
        nft.list(t, 1 ether);
        vm.prank(alice);
        nft.transferFrom(alice, bob, t);
        (address seller, uint96 lp) = nft.listingOf(t);
        assertEq(seller, address(0));
        assertEq(lp, 0);
        (,, uint256[] memory lps) = nft.getTokens(t, 1);
        assertEq(lps[0], 0); // board agrees the listing is gone
        address carol = makeAddr("carol");
        vm.deal(carol, 2 ether);
        vm.prank(carol);
        vm.expectRevert(bytes("not listed"));
        nft.buy{value: 1 ether}(t);
    }

    function test_buyReentrancyBlocked() public {
        uint256 t = _mintTo(alice, 1);
        vm.prank(alice);
        nft.list(t, 1 ether);
        BuyReenterer br = new BuyReenterer(nft);
        vm.deal(address(br), 5 ether);
        vm.expectRevert(); // inner nonReentrant revert bubbles through _safeTransfer
        br.doBuy{value: 1 ether}(t);
        assertEq(nft.ownerOf(t), alice); // nothing moved
    }

    function test_buySellerRejectingEthReverts() public {
        SellerRejector sr = new SellerRejector();
        sr.doMint{value: 0.01 ether}(nft, 1);
        uint256 t = nft.totalMinted();
        sr.doList(nft, t, 1 ether);
        vm.prank(bob);
        vm.expectRevert(bytes("seller pay failed"));
        nft.buy{value: 1 ether}(t);
        assertEq(nft.ownerOf(t), address(sr)); // sale fully reverted
    }

    function testFuzz_buySplitsExactly(uint96 price) public {
        uint256 p = bound(uint256(price), 1, 1000 ether);
        uint256 t = _mintTo(alice, 8);
        vm.prank(alice);
        nft.list(t, uint96(p));
        vm.deal(bob, p);
        uint256 aliceBefore = alice.balance;
        uint256 payoutBefore = payout.balance;
        vm.prank(bob);
        nft.buy{value: p}(t);
        uint256 royalty = (p * 500) / 10000;
        assertEq(payout.balance - payoutBefore, royalty);
        assertEq(alice.balance - aliceBefore, p - royalty);
        assertEq(bob.balance, 0);
        assertEq(address(nft).balance, 0);
    }

    function test_getTokensPagination() public {
        uint256 t1 = _mintTo(alice, 10);
        uint256 t2 = _mintTo(bob, 20);
        uint256 t3 = _mintTo(alice, 10);
        vm.prank(bob);
        nft.list(t2, 7 ether);

        (uint256[] memory arts, address[] memory owners, uint256[] memory lps) = nft.getTokens(1, 500);
        assertEq(arts.length, 3);
        assertEq(arts[0], 10);
        assertEq(arts[1], 20);
        assertEq(arts[2], 10);
        assertEq(owners[0], alice);
        assertEq(owners[1], bob);
        assertEq(lps[0], 0);
        assertEq(lps[1], 7 ether);

        (arts,,) = nft.getTokens(2, 1);
        assertEq(arts.length, 1);
        assertEq(arts[0], 20);

        (arts,,) = nft.getTokens(4, 10); // past the end
        assertEq(arts.length, 0);

        (arts,,) = nft.getTokens(0, 400); // start=0 clamps to 1, no phantom row
        assertEq(arts.length, 3);
        assertEq(arts[0], 10);

        (arts,,) = nft.getTokens(0, 0); // no underflow panic
        assertEq(arts.length, 0);
        (arts,,) = nft.getTokens(1, 0);
        assertEq(arts.length, 0);
        assertEq(t1, 1);
        assertEq(t3, 3);
    }

    function test_sweepForceSentEth() public {
        Selfdestructor sd = new Selfdestructor{value: 0.3 ether}();
        sd.boom(address(nft));
        assertEq(address(nft).balance, 0.3 ether);
        nft.sweep(); // callable by anyone
        assertEq(address(nft).balance, 0);
        assertEq(payout.balance, 0.3 ether);
    }
}
