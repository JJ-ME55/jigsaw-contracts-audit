// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title LoomCollection
/// @notice Fixed ERC-721 logic for EIP-1167 clones. Each clone has its own owner and configuration.
/// @dev The implementation is locked. Factory creation initializes each clone atomically.
contract LoomCollection is
    ERC721Upgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IERC2981
{
    uint256 public constant PLATFORM_FEE = 0.0005 ether;
    uint256 public constant CREATOR_FEE_SHARE = PLATFORM_FEE * 40 / 100;
    uint256 public constant PLATFORM_FEE_SHARE = PLATFORM_FEE * 40 / 100;
    uint256 public constant RESERVE_FEE_SHARE = PLATFORM_FEE - CREATOR_FEE_SHARE - PLATFORM_FEE_SHARE;
    /// @notice v2: of the platform's 40%, 10 points go to the site a mint came through when one is named.
    uint256 public constant REFERRAL_FEE_SHARE = PLATFORM_FEE * 10 / 100;
    uint96 public constant MAX_ROYALTY_BPS = 1000;
    uint256 public constant RESERVE_SUPPLY_DENOMINATOR = 100;

    address public immutable PLATFORM;
    address public immutable RESERVE;

    address public creator;
    uint256 public maxSupply;
    uint256 public mintPriceWei;
    uint256 public maxPerWallet;
    uint96 public royaltyBps;
    uint256 public totalSupply;
    uint256 public reserveMinted;
    mapping(address wallet => uint256 quantity) public mintedPerWallet;

    string public baseURI;
    string public unrevealedURI;
    bytes32 public provenanceHash;
    bytes32 public revealSeed;
    bool public provenanceSet;
    bool public revealSeedSet;
    bool public metadataFrozen;

    error ZeroAddress();
    error EmptyNameOrSymbol();
    error InvalidSupplyOrWalletCap();
    error InvalidMintPrice();
    error RoyaltyTooHigh();
    error ZeroQuantity();
    error SupplyCapExceeded();
    error WalletCapExceeded();
    error ReserveCapExceeded();
    error IncorrectPayment(uint256 expected, uint256 actual);
    error ETHTransferFailed(address recipient);
    error MetadataIsFrozen();
    error ProvenanceAlreadySet();
    error MintingAlreadyStarted();
    error RevealSeedAlreadySet();

    event Minted(address indexed minter, uint256 indexed firstTokenId, uint256 quantity);
    event ReserveMinted(address indexed owner, uint256 indexed firstTokenId, uint256 quantity);
    /// @dev creatorAmount includes both the mint price and the creator's platform-fee share.
    event ReferralPaid(address indexed referral, uint256 amount);
    event FeesDistributed(uint256 creatorAmount, uint256 platformAmount, uint256 reserveAmount);
    event ProvenanceSet(bytes32 provenanceHash);
    event Revealed(bytes32 revealSeed);
    event MetadataFrozen();
    event BaseURISet(string baseURI);
    event UnrevealedURISet(string unrevealedURI);

    constructor(address platform, address reserve) {
        if (platform == address(0) || reserve == address(0)) revert ZeroAddress();
        PLATFORM = platform;
        RESERVE = reserve;
        _disableInitializers();
    }

    /// @notice Configure a fresh clone once. Mint price, caps, creator and royalties then stay fixed.
    /// @dev Do not deploy a clone and initialize it in separate transactions: initialization is public.
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
        if (creator_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert EmptyNameOrSymbol();
        if (maxSupply_ == 0 || maxPerWallet_ == 0 || maxPerWallet_ > maxSupply_) {
            revert InvalidSupplyOrWalletCap();
        }
        if (mintPriceWei_ > type(uint256).max - PLATFORM_FEE) revert InvalidMintPrice();
        if (royaltyBps_ > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();

        __ERC721_init(name_, symbol_);
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        creator = creator_;
        maxSupply = maxSupply_;
        mintPriceWei = mintPriceWei_;
        maxPerWallet = maxPerWallet_;
        royaltyBps = royaltyBps_;
    }

    /// @notice Mint to the caller, charging the exact price and enforcing a lifetime wallet allowance.
    function mint(uint256 quantity) external payable nonReentrant whenNotPaused {
        _publicMint(quantity, address(0));
    }

    /// @notice v2: mint naming the site the mint came through; it receives REFERRAL_FEE_SHARE per token out of the platform's share.
    function mint(uint256 quantity, address referral) external payable nonReentrant whenNotPaused {
        _publicMint(quantity, referral);
    }

    function _publicMint(uint256 quantity, address referral) private {
        _checkMint(quantity);
        if (quantity > maxPerWallet - mintedPerWallet[msg.sender]) revert WalletCapExceeded();
        mintedPerWallet[msg.sender] += quantity;
        _mintAndDistribute(msg.sender, quantity, false, referral);
    }

    /// @notice Owner allowance: at most floor(maxSupply / 100) tokens across all owners combined.
    /// @dev Uses the same payment formula as mint(); does not consume the public wallet allowance.
    ///      It shares the hard supply cap and does not set supply aside from public minting.
    function reserveMint(uint256 quantity) external payable nonReentrant onlyOwner whenNotPaused {
        _checkMint(quantity);
        if (quantity > maxSupply / RESERVE_SUPPLY_DENOMINATOR - reserveMinted) revert ReserveCapExceeded();
        reserveMinted += quantity;
        _mintAndDistribute(msg.sender, quantity, true, address(0));
    }

    /// @notice Pause new public and reserve mints. ERC-721 approvals and transfers remain available.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Commit the off-chain metadata provenance before the first public or reserve mint.
    function setProvenanceHash(bytes32 hash) external onlyOwner {
        _requireMutableMetadata();
        if (provenanceSet) revert ProvenanceAlreadySet();
        if (totalSupply != 0) revert MintingAlreadyStarted();
        provenanceSet = true;
        provenanceHash = hash;
        emit ProvenanceSet(hash);
    }

    /// @notice Record the owner's off-chain reveal seed once, including if that seed is zero.
    /// @dev This is an auditable record, not a source of random numbers or an on-chain shuffle.
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

    /// @notice Irreversibly lock URIs, provenance and reveal seed in their current state.
    /// @dev An owner may intentionally freeze an empty URI or unset provenance/seed.
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

    /// @notice ERC-2981 quote; marketplaces choose whether to pay it. Receiver and rate are fixed.
    function royaltyInfo(uint256, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount) {
        return (creator, Math.mulDiv(salePrice, royaltyBps, 10_000));
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, IERC165) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || super.supportsInterface(interfaceId);
    }

    function _checkMint(uint256 quantity) private view {
        if (quantity == 0) revert ZeroQuantity();
        if (quantity > maxSupply - totalSupply) revert SupplyCapExceeded();
        uint256 expected = (mintPriceWei + PLATFORM_FEE) * quantity;
        if (msg.value != expected) revert IncorrectPayment(expected, msg.value);
    }

    function _mintAndDistribute(address recipient, uint256 quantity, bool isReserve, address referral) private {
        uint256 firstTokenId = totalSupply + 1;
        // Reserve the entire batch before the first ERC-721 receiver callback.
        totalSupply += quantity;
        emit Minted(recipient, firstTokenId, quantity);
        if (isReserve) emit ReserveMinted(recipient, firstTokenId, quantity);
        for (uint256 i; i < quantity; ++i) {
            _safeMint(recipient, firstTokenId + i);
        }

        // Constant per-token shares divide exactly, so batching cannot change rounding or fees.
        uint256 creatorAmount = (mintPriceWei + CREATOR_FEE_SHARE) * quantity;
        uint256 platformAmount = PLATFORM_FEE_SHARE * quantity;
        uint256 reserveAmount = RESERVE_FEE_SHARE * quantity;
        uint256 referralAmount;
        if (referral != address(0) && referral != PLATFORM) {
            referralAmount = REFERRAL_FEE_SHARE * quantity;
            platformAmount -= referralAmount;
        }
        emit FeesDistributed(creatorAmount, platformAmount, reserveAmount);
        _sendETH(creator, creatorAmount);
        _sendETH(PLATFORM, platformAmount);
        _sendETH(RESERVE, reserveAmount);
        if (referralAmount > 0) {
            emit ReferralPaid(referral, referralAmount);
            _sendETH(referral, referralAmount);
        }
    }

    function _sendETH(address recipient, uint256 amount) private {
        (bool success,) = payable(recipient).call{value: amount}("");
        if (!success) revert ETHTransferFailed(recipient);
    }

    function _requireMutableMetadata() private view {
        if (metadataFrozen) revert MetadataIsFrozen();
    }
}
