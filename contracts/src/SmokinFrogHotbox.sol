// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "openzeppelin-contracts/contracts/token/common/ERC2981.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

/// @title Smokin Frog Hotbox
/// @notice Open-edition NFT collection on Robinhood Chain. Each of the `artCount`
///         artworks starts at 0.01 ETH and its price rises 5% after every mint of
///         that same artwork. Sale proceeds are forwarded to `payout` on each mint.
///         Includes a built-in secondary market: any token owner can list at their
///         own price; buys pay the seller minus the 5% royalty, in the same tx.
contract SmokinFrogHotbox is ERC721, ERC2981, Ownable, ReentrancyGuard {
    using Strings for uint256;

    uint256 public constant BASE_PRICE = 0.01 ether;
    uint96 public constant ROYALTY_BPS = 500; // 5%, mirrored in ERC2981

    uint256 public artCount;
    uint256 public totalMinted;
    string public baseURI;
    address public payout;

    /// artId => number of editions minted
    mapping(uint256 => uint256) public mintedOf;
    /// artId => next mint price (0 means BASE_PRICE, i.e. never minted)
    mapping(uint256 => uint256) private _priceOf;
    /// tokenId => artId
    mapping(uint256 => uint256) public artOf;

    struct Listing {
        address seller;
        uint96 price;
    }
    /// tokenId => active listing (seller == 0 means not listed)
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
    event ArtsAdded(uint256 newArtCount);
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

    constructor(uint256 artCount_, string memory baseURI_, address payout_)
        ERC721("Smokin Frog Hotbox", "SFROGNFT")
        Ownable(msg.sender)
    {
        require(artCount_ > 0, "no arts");
        require(payout_ != address(0), "zero payout");
        artCount = artCount_;
        baseURI = baseURI_;
        payout = payout_;
        _setDefaultRoyalty(payout_, ROYALTY_BPS);
    }

    // ---------------------------------------------------------------- minting

    /// @notice Mint one edition of artwork `artId` (1-based). Send at least the
    ///         current price; any excess is refunded in the same transaction.
    function mint(uint256 artId) external payable nonReentrant returns (uint256 tokenId) {
        require(artId >= 1 && artId <= artCount, "unknown art");
        uint256 price = priceOf(artId);
        require(msg.value >= price, "underpaid");

        uint256 nextPrice = (price * 105) / 100;
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

    /// @notice List a token you own for sale at your own price. Listing again
    ///         overwrites the previous price. Any transfer cancels the listing.
    function list(uint256 tokenId, uint96 price) external {
        require(ownerOf(tokenId) == msg.sender, "not yours");
        require(price > 0, "zero price");
        listingOf[tokenId] = Listing(msg.sender, price);
        emit Listed(tokenId, msg.sender, price);
    }

    /// @notice Cancel your listing.
    function delist(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "not yours");
        require(listingOf[tokenId].seller != address(0), "not listed");
        delete listingOf[tokenId];
        emit Delisted(tokenId, msg.sender);
    }

    /// @notice Buy a listed token. Pays the seller price minus the 5% royalty
    ///         (which goes to `payout`); any excess msg.value is refunded.
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
        return p == 0 ? BASE_PRICE : p;
    }

    /// @notice Full board state in one call: current price and minted count per art.
    function getState() external view returns (uint256[] memory prices, uint256[] memory minted) {
        uint256 n = artCount;
        prices = new uint256[](n);
        minted = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            prices[i] = priceOf(i + 1);
            minted[i] = mintedOf[i + 1];
        }
    }

    /// @notice Paginated token board for the site: art, owner and listing price
    ///         (0 = not listed) for tokenIds [start, start+count). TokenIds are
    ///         1-based and dense up to totalMinted.
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
            uint256 t = start + i;
            artIds[i] = artOf[t];
            owners[i] = _ownerOf(t);
            listPrices[i] = listingOf[t].price;
        }
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return string.concat(baseURI, artOf[tokenId].toString(), ".json");
    }

    /// @notice Collection-level metadata (OpenSea-style contractURI).
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
        _setDefaultRoyalty(newPayout, 500);
        emit PayoutChanged(newPayout);
    }

    /// @notice Append `n` new artworks (each starting at BASE_PRICE).
    function addArts(uint256 n) external onlyOwner {
        require(n > 0, "zero");
        artCount += n;
        emit ArtsAdded(artCount);
    }

    /// @notice Emergency lever: override the current price of one artwork.
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
