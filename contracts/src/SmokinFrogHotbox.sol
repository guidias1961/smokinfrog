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
contract SmokinFrogHotbox is ERC721, ERC2981, Ownable, ReentrancyGuard {
    using Strings for uint256;

    uint256 public constant BASE_PRICE = 0.01 ether;

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

    constructor(uint256 artCount_, string memory baseURI_, address payout_)
        ERC721("Smokin Frog Hotbox", "SFROGNFT")
        Ownable(msg.sender)
    {
        require(artCount_ > 0, "no arts");
        require(payout_ != address(0), "zero payout");
        artCount = artCount_;
        baseURI = baseURI_;
        payout = payout_;
        _setDefaultRoyalty(payout_, 500); // 5% secondary royalty where honored
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
