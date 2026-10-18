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
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title JigsawCollection
/// @notice ERC-721 logic for EIP-1167 clones, made by JigsawCollectionFactory. The same contract as the Loom collection
///         (fee split, provenance, placeholder, reveal seed, freeze, pause, royalties, 1% reserve mint) plus timed mint
///         phases (Jj, 17 Oct): up to three, e.g. VIP 10:00, WL 13:00, public 17:00. Each phase has its own start
///         time, price, per-wallet allowance, optional phase supply and optional wallet list (a Merkle root of OpenZeppelin double-hashed
///         address leaves, like JIG's allowlist). A phase stays open once it starts, so a VIP keeps their allowance
///         into later phases; a lifetime per-wallet cap applies across all phases. Provenance, the first URI and the
///         phases are set in the creating transaction, so no mint can come before the art's fingerprint.
contract JigsawCollection is
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
    uint96 public constant MAX_ROYALTY_BPS = 1000;
    uint256 public constant RESERVE_SUPPLY_DENOMINATOR = 100;
    uint256 public constant MAX_PHASES = 3;

    address public immutable PLATFORM;
    address public immutable RESERVE;

    struct Phase {
        uint64 start; // unix seconds; open from then on
        uint128 price; // wei per token (before the platform fee)
        uint32 maxPerWallet; // per wallet, within this phase
        uint32 supply; // most tokens this phase may mint in total; 0 = up to maxSupply
        bytes32 root; // wallet list; 0 = anyone
    }

    struct Config {
        string name;
        string symbol;
        uint256 maxSupply;
        uint256 maxPerWallet; // lifetime, across every phase
        address creator;
        uint96 royaltyBps;
    }

    address public creator;
    uint256 public maxSupply;
    uint256 public maxPerWallet;
    uint96 public royaltyBps;
    uint256 public totalSupply;
    uint256 public reserveMinted;
    mapping(address wallet => uint256 quantity) public mintedPerWallet;
    mapping(uint256 phase => mapping(address wallet => uint256)) public mintedInPhase;
    mapping(uint256 phase => uint256) public phaseMinted;
    Phase[] internal _phases;

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
    error PhaseCapExceeded();
    error PhaseSupplyExceeded();
    error ReserveCapExceeded();
    error IncorrectPayment(uint256 expected, uint256 actual);
    error ETHTransferFailed(address recipient);
    error MetadataIsFrozen();
    error MintingAlreadyStarted();
    error RevealSeedAlreadySet();
    error BadPhases();
    error PhaseNotOpen(uint256 phase);
    error NotOnList();
    error UsePhaseMint();
    error PhasesLocked();
    error BadProvenance();
    error NothingToFreeze();
    error CannotRenounce();

    event Minted(address indexed minter, uint256 indexed firstTokenId, uint256 quantity);
    event PhaseMinted(address indexed minter, uint256 indexed phase, uint256 quantity);
    event ReserveMinted(address indexed owner, uint256 indexed firstTokenId, uint256 quantity);
    /// @dev creatorAmount includes both the mint price and the creator's platform-fee share.
    event FeesDistributed(uint256 creatorAmount, uint256 platformAmount, uint256 reserveAmount);
    event ProvenanceSet(bytes32 provenanceHash);
    event Revealed(bytes32 revealSeed);
    event MetadataFrozen();
    event BaseURISet(string baseURI);
    event UnrevealedURISet(string unrevealedURI);
    event PhasesSet(uint256 count);
    event PhaseRootSet(uint256 indexed phase, bytes32 root);

    constructor(address platform, address reserve) {
        if (platform == address(0) || reserve == address(0)) revert ZeroAddress();
        PLATFORM = platform;
        RESERVE = reserve;
        _disableInitializers();
    }

    /// @notice Configure a fresh clone once, with its provenance, first URI and phases. Called by the factory in the
    ///         clone's creating transaction.
    /// @param revealLater true: `uri` is the unrevealed placeholder; false: `uri` is the base URI
    /// @param freeze freeze the metadata now (an immediate reveal with its final ipfs:// base URI)
    function initialize(
        Config calldata c,
        address owner_,
        Phase[] calldata phases_,
        bytes32 provenance,
        string calldata uri,
        bool revealLater,
        bool freeze
    ) external initializer {
        if (c.creator == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (bytes(c.name).length == 0 || bytes(c.symbol).length == 0) revert EmptyNameOrSymbol();
        if (c.maxSupply == 0 || c.maxPerWallet == 0 || c.maxPerWallet > c.maxSupply) revert InvalidSupplyOrWalletCap();
        if (c.royaltyBps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        if (provenance == bytes32(0)) revert BadProvenance();
        if (freeze && revealLater) revert NothingToFreeze(); // the reveal freezes a reveal-later collection

        __ERC721_init(c.name, c.symbol);
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        creator = c.creator;
        maxSupply = c.maxSupply;
        maxPerWallet = c.maxPerWallet;
        royaltyBps = c.royaltyBps;
        _setPhases(phases_);

        provenanceSet = true;
        provenanceHash = provenance;
        emit ProvenanceSet(provenance);
        if (revealLater) {
            unrevealedURI = uri;
            emit UnrevealedURISet(uri);
        } else {
            baseURI = uri;
            emit BaseURISet(uri);
        }
        if (freeze) {
            metadataFrozen = true;
            emit MetadataFrozen();
        }
    }

    // ------------------------------------------------------------------ phases

    function phaseCount() external view returns (uint256) {
        return _phases.length;
    }

    function phase(uint256 i) external view returns (Phase memory) {
        return _phases[i];
    }

    /// @notice The latest phase that has started, or type(uint256).max before the first one.
    function currentPhase() public view returns (uint256) {
        for (uint256 i = _phases.length; i > 0; i--) {
            if (block.timestamp >= _phases[i - 1].start) return i - 1;
        }
        return type(uint256).max;
    }

    /// @notice The current phase's price (the first phase's before minting opens), for pages that read one price.
    function mintPriceWei() external view returns (uint256) {
        uint256 i = currentPhase();
        return _phases[i == type(uint256).max ? 0 : i].price;
    }

    /// @notice The owner may change the phases until the first one starts and nothing is minted (to fix a time or a list).
    function setPhases(Phase[] calldata phases_) external onlyOwner {
        // the owner's 1% reserve does not lock them (internal round, 18 Oct); any phase mint does
        if (totalSupply != reserveMinted || block.timestamp >= _phases[0].start) revert PhasesLocked();
        _setPhases(phases_);
    }

    /// @notice Replace one phase's wallet list until that phase starts (wallets added late to a VIP or WL list).
    function setPhaseRoot(uint256 i, bytes32 root) external onlyOwner {
        if (i >= _phases.length) revert BadPhases();
        if (block.timestamp >= _phases[i].start) revert PhasesLocked();
        _phases[i].root = root;
        _checkListOrder();
        emit PhaseRootSet(i, root);
    }

    /// @dev A list-only phase may not follow a phase open to anyone (internal round, 18 Oct): phases stay open, so
    ///      mint(quantity) and mintPriceWei, which read the latest phase, would point at the list instead of the open one.
    function _checkListOrder() private view {
        bool open;
        for (uint256 i; i < _phases.length; i++) {
            if (_phases[i].root == bytes32(0)) open = true;
            else if (open) revert BadPhases();
        }
    }

    function _setPhases(Phase[] calldata phases_) internal {
        uint256 n = phases_.length;
        if (n == 0 || n > MAX_PHASES) revert BadPhases();
        delete _phases;
        for (uint256 i; i < n; i++) {
            Phase calldata p = phases_[i];
            if (p.maxPerWallet == 0 || p.maxPerWallet > maxPerWallet || p.supply > maxSupply) revert BadPhases();
            if (i > 0 && p.start < phases_[i - 1].start) revert BadPhases();
            if (p.price > type(uint128).max - PLATFORM_FEE) revert InvalidMintPrice();
            _phases.push(p);
        }
        _checkListOrder();
        emit PhasesSet(n);
    }

    // ------------------------------------------------------------------ minting

    /// @notice Mint in phase `phaseIndex`, proving list membership for a listed phase (empty proof for an open one).
    function mint(uint256 phaseIndex, uint256 quantity, bytes32[] calldata proof) external payable nonReentrant whenNotPaused {
        _phaseMint(phaseIndex, quantity, proof);
    }

    /// @notice The Loom-compatible mint for pages that only know mint(quantity): the current phase, which must be open
    ///         to anyone.
    function mint(uint256 quantity) external payable nonReentrant whenNotPaused {
        uint256 i = currentPhase();
        if (i == type(uint256).max) revert PhaseNotOpen(0);
        if (_phases[i].root != bytes32(0)) revert UsePhaseMint();
        _phaseMint(i, quantity, new bytes32[](0));
    }

    /// @notice How many more `wallet` can mint in `phaseIndex` right now (0 if the phase is shut or not yet open;
    ///         list membership is not checked here).
    function mintableNow(uint256 phaseIndex, address wallet) external view returns (uint256 n) {
        if (paused() || phaseIndex >= _phases.length) return 0;
        Phase memory p = _phases[phaseIndex];
        if (block.timestamp < p.start) return 0;
        n = p.maxPerWallet - mintedInPhase[phaseIndex][wallet];
        n = Math.min(n, maxPerWallet - mintedPerWallet[wallet]);
        n = Math.min(n, maxSupply - totalSupply);
        if (p.supply != 0) n = Math.min(n, p.supply - phaseMinted[phaseIndex]);
    }

    function _phaseMint(uint256 phaseIndex, uint256 quantity, bytes32[] memory proof) private {
        if (phaseIndex >= _phases.length) revert PhaseNotOpen(phaseIndex);
        Phase memory p = _phases[phaseIndex];
        if (block.timestamp < p.start) revert PhaseNotOpen(phaseIndex);
        if (p.root != bytes32(0)) {
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender))));
            if (!MerkleProof.verify(proof, p.root, leaf)) revert NotOnList();
        }
        _checkMint(quantity, p.price);
        if (quantity > p.maxPerWallet - mintedInPhase[phaseIndex][msg.sender]) revert PhaseCapExceeded();
        if (quantity > maxPerWallet - mintedPerWallet[msg.sender]) revert WalletCapExceeded();
        if (p.supply != 0 && quantity > p.supply - phaseMinted[phaseIndex]) revert PhaseSupplyExceeded();
        mintedInPhase[phaseIndex][msg.sender] += quantity;
        mintedPerWallet[msg.sender] += quantity;
        phaseMinted[phaseIndex] += quantity;
        emit PhaseMinted(msg.sender, phaseIndex, quantity);
        _mintAndDistribute(msg.sender, quantity, p.price, false);
    }

    /// @notice Owner allowance: at most floor(maxSupply / 100) tokens across all owners combined, at the first
    ///         phase's price. Does not use any wallet allowance.
    function reserveMint(uint256 quantity) external payable nonReentrant onlyOwner whenNotPaused {
        uint256 price = _phases[0].price;
        _checkMint(quantity, price);
        if (quantity > maxSupply / RESERVE_SUPPLY_DENOMINATOR - reserveMinted) revert ReserveCapExceeded();
        reserveMinted += quantity;
        _mintAndDistribute(msg.sender, quantity, price, true);
    }

    /// @dev Renouncing would strand a paused or unrevealed collection; ownership moves only by transfer (to the Safe).
    function renounceOwnership() public view override onlyOwner {
        revert CannotRenounce();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ------------------------------------------------------------------ metadata (identical to the Loom collection)

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

    function freezeMetadata() external onlyOwner {
        _requireMutableMetadata();
        if (bytes(baseURI).length == 0) revert NothingToFreeze(); // would leave every token on the placeholder for good
        metadataFrozen = true;
        emit MetadataFrozen();
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (bytes(baseURI).length == 0) return unrevealedURI;
        return string.concat(baseURI, Strings.toString(tokenId), ".json");
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount) {
        return (creator, Math.mulDiv(salePrice, royaltyBps, 10_000));
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, IERC165) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------ internals

    function _checkMint(uint256 quantity, uint256 price) private view {
        if (quantity == 0) revert ZeroQuantity();
        if (quantity > maxSupply - totalSupply) revert SupplyCapExceeded();
        uint256 expected = (price + PLATFORM_FEE) * quantity;
        if (msg.value != expected) revert IncorrectPayment(expected, msg.value);
    }

    function _mintAndDistribute(address recipient, uint256 quantity, uint256 price, bool isReserve) private {
        uint256 firstTokenId = totalSupply + 1;
        totalSupply += quantity; // the whole batch is reserved before the first receiver callback
        emit Minted(recipient, firstTokenId, quantity);
        if (isReserve) emit ReserveMinted(recipient, firstTokenId, quantity);
        for (uint256 i; i < quantity; ++i) {
            _safeMint(recipient, firstTokenId + i);
        }
        uint256 creatorAmount = (price + CREATOR_FEE_SHARE) * quantity;
        uint256 platformAmount = PLATFORM_FEE_SHARE * quantity;
        uint256 reserveAmount = RESERVE_FEE_SHARE * quantity;
        emit FeesDistributed(creatorAmount, platformAmount, reserveAmount);
        _sendETH(creator, creatorAmount);
        _sendETH(PLATFORM, platformAmount);
        _sendETH(RESERVE, reserveAmount);
    }

    function _sendETH(address recipient, uint256 amount) private {
        (bool success,) = payable(recipient).call{value: amount}("");
        if (!success) revert ETHTransferFailed(recipient);
    }

    function _requireMutableMetadata() private view {
        if (metadataFrozen) revert MetadataIsFrozen();
    }
}
