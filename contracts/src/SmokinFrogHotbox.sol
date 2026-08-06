// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "openzeppelin-contracts/contracts/token/common/ERC2981.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

/// @title Smokin Frog Hotbox
/// @notice A FINITE 99-artwork collection on Robinhood Chain with five rarity
///         tiers. Each artwork belongs to a tier that fixes (a) how many
///         editions of it can ever exist and (b) its starting price. Rarer
///         tiers have fewer editions and a higher floor. Every mint of an
///         artwork raises that artwork's price by 5%; once its edition cap is
///         reached it is sold out forever. Total supply is fixed at deploy.
///         Includes a built-in secondary market with a 5% royalty to `payout`.
///
///         Tiers (index => name, editions/art, base price):
///           0 Common     — 25 editions — 0.01 ETH
///           1 Uncommon   — 12 editions — 0.02 ETH
///           2 Rare       —  6 editions — 0.04 ETH
///           3 Epic       —  3 editions — 0.08 ETH
///           4 Legendary  —  1 edition  — 0.25 ETH  (1/1)
contract SmokinFrogHotbox is ERC721, ERC2981, Ownable, ReentrancyGuard {
    using Strings for uint256;

    uint96 public constant ROYALTY_BPS = 500;  // 5% secondary royalty
    uint256 public constant RAMP_NUM = 105;     // +5% per mint of the same art
    uint256 public constant RAMP_DEN = 100;
    uint8 public constant NUM_TIERS = 5;

    uint256 public immutable artCount;
    uint256 public immutable maxSupply;  // sum of every artwork's edition cap — hard ceiling
    uint256 public totalMinted;
    string public baseURI;
    address public payout;

    /// tier code (0..4) per art, packed one byte per art, artId-1 indexed
    bytes private _artTiers;

    /// artId => editions minted so far
    mapping(uint256 => uint256) public mintedOf;
    /// artId => next mint price (0 = never minted, use tier base price)
    mapping(uint256 => uint256) private _priceOf;
    /// tokenId => artId
    mapping(uint256 => uint256) public artOf;

    struct Listing {
        address seller;
        uint96 price;
    }
    mapping(uint256 => Listing) public listingOf;

    event Minted(
        address indexed minter,
        uint256 indexed artId,
        uint256 indexed tokenId,
        uint256 price,
        uint256 nextPrice
    );
    event BaseURIChanged(string newBaseURI);
    event PayoutChanged(address newPayout);
    event PriceSet(uint256 indexed artId, uint256 newPrice);
    event Listed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event Delisted(uint256 indexed tokenId, address indexed seller);
    event Bought(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed seller,
        uint256 price,
        uint256 royalty
    );

    /// @param artTiers_ one byte per artwork, each a tier code in [0,4]; its
    ///        length sets artCount. Fixed forever at deploy.
    constructor(bytes memory artTiers_, string memory baseURI_, address payout_)
        ERC721("Smokin Frog Hotbox", "SFROGNFT")
        Ownable(msg.sender)
    {
        uint256 n = artTiers_.length;
        require(n > 0, "no arts");
        require(payout_ != address(0), "zero payout");

        uint256 supply;
        for (uint256 i = 0; i < n; ++i) {
            uint8 t = uint8(artTiers_[i]);
            require(t < NUM_TIERS, "bad tier");
            supply += _tierCap(t);
        }

        artCount = n;
        maxSupply = supply;
        _artTiers = artTiers_;
        baseURI = baseURI_;
        payout = payout_;
        _setDefaultRoyalty(payout_, ROYALTY_BPS);
    }

    // ---------------------------------------------------------------- tier data

    function _tierCap(uint8 t) internal pure returns (uint256) {
        if (t == 0) return 25;
        if (t == 1) return 12;
        if (t == 2) return 6;
        if (t == 3) return 3;
        return 1; // Legendary
    }

    function _tierBasePrice(uint8 t) internal pure returns (uint256) {
        if (t == 0) return 0.01 ether;
        if (t == 1) return 0.02 ether;
        if (t == 2) return 0.04 ether;
        if (t == 3) return 0.08 ether;
        return 0.25 ether; // Legendary
    }

    /// @notice Tier code (0 Common .. 4 Legendary) of artwork `artId` (1-based).
    function tierOf(uint256 artId) public view returns (uint8) {
        require(artId >= 1 && artId <= artCount, "unknown art");
        return uint8(_artTiers[artId - 1]);
    }

    /// @notice Max editions that can ever exist for artwork `artId`.
    function capOf(uint256 artId) public view returns (uint256) {
        return _tierCap(tierOf(artId));
    }

    /// @notice Editions of artwork `artId` still mintable.
    function remainingOf(uint256 artId) public view returns (uint256) {
        return _tierCap(tierOf(artId)) - mintedOf[artId];
    }

    // ---------------------------------------------------------------- minting

    /// @notice Mint one edition of artwork `artId` (1-based). Send at least the
    ///         current price; any excess is refunded in the same transaction.
    ///         Reverts once the artwork's edition cap is reached.
    function mint(uint256 artId) external payable nonReentrant returns (uint256 tokenId) {
        require(artId >= 1 && artId <= artCount, "unknown art");
        uint256 cap = _tierCap(uint8(_artTiers[artId - 1]));
        require(mintedOf[artId] < cap, "sold out");

        uint256 price = priceOf(artId);
        require(msg.value >= price, "underpaid");

        uint256 nextPrice = (price * RAMP_NUM) / RAMP_DEN;
        _priceOf[artId] = nextPrice;
        unchecked {
            mintedOf[artId] += 1;
            totalMinted += 1;
        }
        tokenId = totalMinted;
        artOf[tokenId] = artId;

        _safeMint(msg.sender, tokenId);

        (bool paid,) = payout.call{value: price}("");
        require(paid, "payout failed");
        uint256 excess = msg.value - price;
        if (excess > 0) {
            (bool refunded,) = msg.sender.call{value: excess}("");
            require(refunded, "refund failed");
        }

        emit Minted(msg.sender, artId, tokenId, price, nextPrice);
    }

    // --------------------------------------------------------- secondary market

    function list(uint256 tokenId, uint96 price) external {
        require(ownerOf(tokenId) == msg.sender, "not yours");
        require(price > 0, "zero price");
        listingOf[tokenId] = Listing(msg.sender, price);
        emit Listed(tokenId, msg.sender, price);
    }

    function delist(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "not yours");
        require(listingOf[tokenId].seller != address(0), "not listed");
        delete listingOf[tokenId];
        emit Delisted(tokenId, msg.sender);
    }

    function buy(uint256 tokenId) external payable nonReentrant {
        Listing memory l = listingOf[tokenId];
        require(l.seller != address(0), "not listed");
        require(ownerOf(tokenId) == l.seller, "stale listing");
        require(msg.sender != l.seller, "own token");
        require(msg.value >= l.price, "underpaid");

        delete listingOf[tokenId];
        uint256 royalty = (uint256(l.price) * ROYALTY_BPS) / 10000;
        uint256 sellerCut = l.price - royalty;

        _safeTransfer(l.seller, msg.sender, tokenId, "");

        (bool paidRoyalty,) = payout.call{value: royalty}("");
        require(paidRoyalty, "royalty failed");
        (bool paidSeller,) = l.seller.call{value: sellerCut}("");
        require(paidSeller, "seller pay failed");
        uint256 excess = msg.value - l.price;
        if (excess > 0) {
            (bool refunded,) = msg.sender.call{value: excess}("");
            require(refunded, "refund failed");
        }

        emit Bought(tokenId, msg.sender, l.seller, l.price, royalty);
    }

    /// @dev Any ownership change (sale, transfer) invalidates the listing.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        delete listingOf[tokenId];
        return super._update(to, tokenId, auth);
    }

    // ------------------------------------------------------------------ views

    /// @notice Current mint price of artwork `artId`.
    function priceOf(uint256 artId) public view returns (uint256) {
        uint256 p = _priceOf[artId];
        return p == 0 ? _tierBasePrice(uint8(_artTiers[artId - 1])) : p;
    }

    /// @notice Whole board in one call: current price, minted count, edition cap
    ///         and tier code for every artwork (index 0 == artId 1).
    function getState()
        external
        view
        returns (uint256[] memory prices, uint256[] memory minted, uint256[] memory caps, uint256[] memory tiers)
    {
        uint256 n = artCount;
        prices = new uint256[](n);
        minted = new uint256[](n);
        caps = new uint256[](n);
        tiers = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint8 t = uint8(_artTiers[i]);
            prices[i] = priceOf(i + 1);
            minted[i] = mintedOf[i + 1];
            caps[i] = _tierCap(t);
            tiers[i] = t;
        }
    }

    /// @notice Paginated token board: art, owner and listing price (0 = not
    ///         listed) for tokenIds [start, start+count). 1-based, dense.
    function getTokens(uint256 start, uint256 count)
        external
        view
        returns (uint256[] memory artIds, address[] memory owners, uint256[] memory listPrices)
    {
        if (start == 0) start = 1;
        uint256 end = count == 0 ? 0 : start + count - 1;
        if (end > totalMinted) end = totalMinted;
        uint256 n = end >= start ? end - start + 1 : 0;
        artIds = new uint256[](n);
        owners = new address[](n);
        listPrices = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 tkn = start + i;
            artIds[i] = artOf[tkn];
            owners[i] = _ownerOf(tkn);
            listPrices[i] = listingOf[tkn].price;
        }
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return string.concat(baseURI, artOf[tokenId].toString(), ".json");
    }

    function contractURI() external view returns (string memory) {
        return string.concat(baseURI, "collection.json");
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------ admin

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        baseURI = newBaseURI;
        emit BaseURIChanged(newBaseURI);
    }

    function setPayout(address newPayout) external onlyOwner {
        require(newPayout != address(0), "zero payout");
        payout = newPayout;
        _setDefaultRoyalty(newPayout, ROYALTY_BPS);
        emit PayoutChanged(newPayout);
    }

    /// @notice Emergency lever: override the current price of one artwork. Cannot
    ///         change its edition cap or the fixed max supply.
    function setPrice(uint256 artId, uint256 newPrice) external onlyOwner {
        require(artId >= 1 && artId <= artCount, "unknown art");
        require(newPrice > 0, "zero price");
        _priceOf[artId] = newPrice;
        emit PriceSet(artId, newPrice);
    }

    /// @notice Forward any ETH stranded in the contract (e.g. force-sent) to payout.
    function sweep() external {
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok,) = payout.call{value: bal}("");
            require(ok, "sweep failed");
        }
    }
}
