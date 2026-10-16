// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Immutable ERC-721 logic for EIP-1167 clones with collection-local ownership and accounting.
/// @dev This contract has no upgrade entry point. Only clone storage may be initialized.
contract LoomCollection is
    ERC721Upgradeable,
    ERC2981Upgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    uint256 public constant PLATFORM_FEE = 0.0005 ether;
    address public immutable PLATFORM;
    address public immutable RESERVE;

    uint256 public maxSupply;
    uint256 public mintPrice;
    uint256 public maxPerWallet;
    address public creator;
    uint96 public royaltyBps;

    /// @notice Public and reserve mints share the same supply and sequential IDs starting at 1.
    uint256 public totalSupply;
    uint256 public reserveMinted;
    /// @notice Lifetime public mints; transfers and reserve mints do not change this count.
    mapping(address wallet => uint256 quantity) public mintedPerWallet;

    string public baseURI;
    string public unrevealedURI;
    bytes32 public provenanceHash;
    bytes32 public revealSeed;
    bool public provenanceSet;
    bool public revealSeedSet;
    bool public metadataFrozen;

    error InvalidAddress();
    error InvalidSupply();
    error InvalidWalletCap();
    error InvalidMintPrice();
    error InvalidRoyalty();
    error ZeroQuantity();
    error IncorrectPayment(uint256 expected, uint256 received);
    error MaxSupplyExceeded();
    error WalletCapExceeded();
    error ReserveCapExceeded();
    error PaymentFailed(address recipient, uint256 amount);
    error MetadataIsFrozen();
    error ProvenanceAlreadySet();
    error MintingAlreadyStarted();
    error RevealSeedAlreadySet();

    event Minted(address indexed minter, uint256 indexed firstTokenId, uint256 quantity, bool reserved);
    event FeesDistributed(address indexed payer, uint256 creatorAmount, uint256 platformAmount, uint256 reserveAmount);
    event ProvenanceSet(bytes32 indexed provenanceHash);
    event Revealed(bytes32 indexed revealSeed);
    event MetadataFrozen();
    event BaseURISet(string baseURI);
    event UnrevealedURISet(string unrevealedURI);

    /// @param platform Recipient of 40% of each per-token platform fee, shared by all clones.
    /// @param reserve Recipient of 20% of each per-token platform fee, shared by all clones.
    constructor(address platform, address reserve) {
        if (platform == address(0) || reserve == address(0)) revert InvalidAddress();
        PLATFORM = platform;
        RESERVE = reserve;
        _disableInitializers();
    }

    /// @notice Called atomically by LoomFactory immediately after cloning.
    /// @dev An independently deployed clone must also be initialized in its deployment transaction.
    function initialize(
        string calldata name_,
        string calldata symbol_,
        uint256 maxSupply_,
        uint256 mintPriceWei_,
        uint256 maxPerWallet_,
        address creator_,
        uint96 royaltyBps_,
        address owner_
    ) external initializer {
        if (creator_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        if (maxSupply_ == 0) revert InvalidSupply();
        if (maxPerWallet_ == 0 || maxPerWallet_ > maxSupply_) revert InvalidWalletCap();
        // Every permitted batch must have a representable exact price, including its platform fee.
        if (mintPriceWei_ > type(uint256).max - PLATFORM_FEE) revert InvalidMintPrice();
        if (maxSupply_ > type(uint256).max / (mintPriceWei_ + PLATFORM_FEE)) revert InvalidMintPrice();
        if (royaltyBps_ > 10_000) revert InvalidRoyalty();

        __ERC721_init(name_, symbol_);
        __ERC2981_init();
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        maxSupply = maxSupply_;
        mintPrice = mintPriceWei_;
        maxPerWallet = maxPerWallet_;
        creator = creator_;
        royaltyBps = royaltyBps_;
        _setDefaultRoyalty(creator_, royaltyBps_);
    }

    /// @notice Safely mint to the caller and immediately distribute the exact ETH payment.
    function mint(uint256 quantity) external payable nonReentrant whenNotPaused {
        _checkQuantity(quantity);
        if (quantity > maxPerWallet - mintedPerWallet[msg.sender]) revert WalletCapExceeded();
        uint256 expected = (mintPrice + PLATFORM_FEE) * quantity;
        if (msg.value != expected) revert IncorrectPayment(expected, msg.value);

        mintedPerWallet[msg.sender] += quantity;
        _mintBatch(msg.sender, quantity, false);

        // The fixed fee is divisible by five: these per-token shares never produce rounding dust.
        uint256 platformAmount = (PLATFORM_FEE / 5 * 2) * quantity;
        uint256 reserveAmount = (PLATFORM_FEE / 5) * quantity;
        uint256 creatorAmount = expected - platformAmount - reserveAmount;
        _pay(creator, creatorAmount);
        _pay(PLATFORM, platformAmount);
        _pay(RESERVE, reserveAmount);
        emit FeesDistributed(msg.sender, creatorAmount, platformAmount, reserveAmount);
    }

    /// @notice The owner may safely mint up to floor(maxSupply / 100) tokens to itself, without a fee.
    /// @dev The allowance is collection-wide across ownership transfers; public mints can sell it out.
    function reserveMint(uint256 quantity) external nonReentrant onlyOwner whenNotPaused {
        _checkQuantity(quantity);
        if (quantity > maxSupply / 100 - reserveMinted) revert ReserveCapExceeded();
        reserveMinted += quantity;
        _mintBatch(msg.sender, quantity, true);
    }

    /// @notice Pause minting only. Existing tokens remain transferable.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Record an off-chain art commitment once, before any public or reserve mint.
    function setProvenanceHash(bytes32 hash) external onlyOwner {
        _requireMutableMetadata();
        if (provenanceSet) revert ProvenanceAlreadySet();
        if (totalSupply != 0) revert MintingAlreadyStarted();
        provenanceSet = true;
        provenanceHash = hash;
        emit ProvenanceSet(hash);
    }

    /// @notice Record one owner-supplied seed. It does not generate randomness or reorder token IDs.
    function setRevealSeed(bytes32 seed) external onlyOwner {
        _requireMutableMetadata();
        if (revealSeedSet) revert RevealSeedAlreadySet();
        revealSeedSet = true;
        revealSeed = seed;
        emit Revealed(seed);
    }

    function setBaseURI(string calldata uri) external onlyOwner {
        _requireMutableMetadata();
        baseURI = uri;
        emit BaseURISet(uri);
    }

    function setUnrevealedURI(string calldata uri) external onlyOwner {
        _requireMutableMetadata();
        unrevealedURI = uri;
        emit UnrevealedURISet(uri);
    }

    /// @notice Irreversibly lock both URIs, provenance and seed, including any still-unset values.
    function freezeMetadata() external onlyOwner {
        _requireMutableMetadata();
        metadataFrozen = true;
        emit MetadataFrozen();
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (bytes(baseURI).length == 0) return unrevealedURI;
        return string.concat(baseURI, Strings.toString(tokenId), ".json");
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC2981Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _checkQuantity(uint256 quantity) private view {
        if (quantity == 0) revert ZeroQuantity();
        if (quantity > maxSupply - totalSupply) revert MaxSupplyExceeded();
    }

    function _mintBatch(address recipient, uint256 quantity, bool reserved) private {
        uint256 firstTokenId = totalSupply + 1;
        // Reserve the entire batch before any ERC-721 receiver callback.
        totalSupply += quantity;
        for (uint256 i; i < quantity; ++i) {
            _safeMint(recipient, firstTokenId + i);
        }
        emit Minted(recipient, firstTokenId, quantity, reserved);
    }

    function _pay(address recipient, uint256 amount) private {
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert PaymentFailed(recipient, amount);
    }

    function _requireMutableMetadata() private view {
        if (metadataFrozen) revert MetadataIsFrozen();
    }
}
