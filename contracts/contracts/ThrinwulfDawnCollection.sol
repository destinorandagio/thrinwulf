// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@limitbreak/creator-token-standards/src/access/OwnableBasic.sol";
import "@limitbreak/creator-token-standards/src/access/OwnablePermissions.sol";
import "@limitbreak/creator-token-standards/src/erc721c/ERC721C.sol";
import "@limitbreak/creator-token-standards/src/programmable-royalties/BasicRoyalties.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "./interfaces/IThrinwulfSystem.sol";

/// @title THRINWULF — Dawn of the Delta Collection
/// @notice Collection 01: 1,652 fixed supply, 1,487 paid slots + 165 Reader Bonus slots.
/// @dev Starts PAUSED. Mystery -> Pre-Reveal -> Reveal is irreversible. Rarity is hidden by a committed seed.
contract ThrinwulfDawnCollection is
    OwnableBasic,
    ERC721C,
    BasicRoyalties,
    ReentrancyGuard,
    Pausable,
    EIP712,
    IThrinwulfCollection
{
    using SafeERC20 for IERC20;
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 1_652;
    uint256 public constant INITIAL_PAID_MINT_CAP = 1_487;
    uint256 public constant READER_BONUS_CAP = 165;
    uint256 public constant MAX_PER_TX = 10;
    uint96 public constant ROYALTY_BPS = 1000; // 10%

    uint8 public constant RARITY_COMMON = 0;
    uint8 public constant RARITY_UNCOMMON = 1;
    uint8 public constant RARITY_RARE = 2;
    uint8 public constant RARITY_EPIC = 3;
    uint8 public constant RARITY_LEGENDARY = 4;
    uint8 public constant RARITY_MYTHIC = 5;
    uint8 public constant RARITY_UNICORN = 6;

    IERC20 public immutable USDT;
    address public immutable TREASURY;

    bytes32 public constant READER_BONUS_TYPEHASH =
        keccak256("ReaderBonus(address recipient,bytes32 claimUid,uint256 deadline)");

    enum MetadataStage {
        MYSTERY,
        PRE_REVEAL,
        REVEALED
    }

    IThrinwulfSagaRegistry public immutable sagaRegistry;
    bytes32 public immutable rarityCommitment;

    uint256 public nextTokenId = 1;
    uint256 public paidMintPriceUSDT;
    uint256 public paidMinted;
    uint256 public paidMintCap = INITIAL_PAID_MINT_CAP;
    uint256 public readerBonusMinted;
    bool public readerBonusClaimsClosed;

    bool public mintPriceFrozen;
    bool public transferValidatorFrozen;
    bool public metadataFrozen;
    bool public override rarityRevealed;

    uint256 public rarityOffset;
    uint256 public unicornTokenId;

    address public readerBonusSigner;
    MetadataStage public metadataStage;

    string private _baseTokenURI;
    string public mysteryURI;
    string public preRevealURI;
    string public contractMetadataURI;

    mapping(address => uint256) public paidMintCountByWallet;
    mapping(address => bool) public readerBonusClaimedByWallet;
    mapping(bytes32 => bool) public usedReaderClaims;

    event PaidMint(address indexed buyer, uint256 indexed firstTokenId, uint256 quantity, uint256 totalUSDT);
    event ReaderBonusMinted(address indexed reader, uint256 indexed tokenId, bytes32 indexed claimUid);
    event ReaderBonusSignerSet(address indexed previousSigner, address indexed newSigner);
    event ReaderBonusClaimsClosed(uint256 readerBonusMinted, uint256 finalPaidMintCap);
    event PaidMintPriceSet(uint256 priceUSDT);
    event PaidMintPriceFrozen(uint256 priceUSDT);
    event TransferValidatorFrozen(address indexed validator);
    event PreRevealActivated(string preRevealURI);
    event Revealed(string baseURI, uint256 rarityOffset, uint256 indexed unicornTokenId);
    event MetadataFrozen(string baseURI, string contractURI);
    event ContractURISet(string contractURI);

    error SoldOut();
    error InvalidQuantity();
    error InvalidPrice();
    error InvalidSigner();
    error InvalidVoucher();
    error VoucherExpired();
    error ReaderBonusExhausted();
    error ReaderBonusAlreadyClaimed();
    error PaidMintRequired();
    error MetadataIsFrozen();
    error MetadataNotRevealed();
    error PriceIsFrozen();
    error InvalidURI();
    error InvalidStage();
    error InvalidRaritySeed();
    error RegistryNotReady();
    error PriceNotFrozen();
    error RarityNotRevealed();
    error TransferValidatorIsFrozen();
    error ReaderBonusClaimsAreClosed();
    error SupplyNotFinalized();

    constructor(
        address owner_,
        address registry_,
        address readerBonusSigner_,
        address usdt_,
        address treasury_,
        uint256 initialMintPriceUSDT_,
        string memory mysteryURI_,
        string memory preRevealURI_,
        string memory contractURI_,
        bytes32 rarityCommitment_
    )
        ERC721OpenZeppelin("Thrinwulf - Dawn of the Delta Collection", "THRN1")
        BasicRoyalties(treasury_, ROYALTY_BPS)
        EIP712("Thrinwulf Dawn Reader Bonus", "1")
    {
        if (
            owner_ == address(0) ||
            registry_ == address(0) ||
            readerBonusSigner_ == address(0) ||
            treasury_ == address(0)
        ) revert InvalidSigner();
        if (registry_.code.length == 0) revert RegistryNotReady();
        if (usdt_ == address(0) || usdt_.code.length == 0) revert InvalidPrice();
        if (IERC20Metadata(usdt_).decimals() != 6) revert InvalidPrice();
        if (initialMintPriceUSDT_ == 0) revert InvalidPrice();
        if (!_isIPFSURI(mysteryURI_) || !_isIPFSURI(preRevealURI_) || !_isIPFSURI(contractURI_)) {
            revert InvalidURI();
        }
        if (rarityCommitment_ == bytes32(0)) revert InvalidRaritySeed();

        sagaRegistry = IThrinwulfSagaRegistry(registry_);
        USDT = IERC20(usdt_);
        TREASURY = treasury_;
        readerBonusSigner = readerBonusSigner_;
        paidMintPriceUSDT = initialMintPriceUSDT_;
        mysteryURI = mysteryURI_;
        preRevealURI = preRevealURI_;
        contractMetadataURI = contractURI_;
        rarityCommitment = rarityCommitment_;

        _transferOwnership(owner_);
        _pause(); // fail-closed: no paid or bonus mint until registry + price are locked.
    }

    function totalSupply() public view override returns (uint256) {
        return nextTokenId - 1;
    }

    function mintPaid(uint256 quantity) external nonReentrant whenNotPaused {
        if (quantity == 0 || quantity > MAX_PER_TX) revert InvalidQuantity();
        if (paidMinted + quantity > paidMintCap) revert SoldOut();
        if (totalSupply() + quantity > MAX_SUPPLY) revert SoldOut();

        uint256 total = paidMintPriceUSDT * quantity;
        uint256 first = nextTokenId;

        USDT.safeTransferFrom(msg.sender, TREASURY, total);

        paidMinted += quantity;
        paidMintCountByWallet[msg.sender] += quantity;

        for (uint256 i; i < quantity; ++i) {
            _safeMint(msg.sender, nextTokenId++);
        }

        emit PaidMint(msg.sender, first, quantity, total);
    }

    function claimReaderBonus(
        bytes32 claimUid,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        if (claimUid == bytes32(0)) revert InvalidVoucher();
        if (block.timestamp > deadline) revert VoucherExpired();
        if (readerBonusClaimsClosed) revert ReaderBonusClaimsAreClosed();
        if (readerBonusMinted >= READER_BONUS_CAP) revert ReaderBonusExhausted();
        if (totalSupply() >= MAX_SUPPLY) revert SoldOut();
        if (readerBonusClaimedByWallet[msg.sender]) revert ReaderBonusAlreadyClaimed();
        if (usedReaderClaims[claimUid]) revert InvalidVoucher();
        if (paidMintCountByWallet[msg.sender] == 0) revert PaidMintRequired();

        bytes32 structHash = keccak256(
            abi.encode(READER_BONUS_TYPEHASH, msg.sender, claimUid, deadline)
        );
        address recovered = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (recovered != readerBonusSigner) revert InvalidVoucher();

        usedReaderClaims[claimUid] = true;
        readerBonusClaimedByWallet[msg.sender] = true;
        ++readerBonusMinted;

        uint256 tokenId = nextTokenId++;
        _safeMint(msg.sender, tokenId);
        emit ReaderBonusMinted(msg.sender, tokenId, claimUid);
    }

    function setPaidMintPrice(uint256 newPriceUSDT) external onlyOwner whenPaused {
        if (mintPriceFrozen) revert PriceIsFrozen();
        if (newPriceUSDT == 0) revert InvalidPrice();
        paidMintPriceUSDT = newPriceUSDT;
        emit PaidMintPriceSet(newPriceUSDT);
    }

    function freezePaidMintPrice() external onlyOwner whenPaused {
        if (mintPriceFrozen) revert PriceIsFrozen();
        mintPriceFrozen = true;
        emit PaidMintPriceFrozen(paidMintPriceUSDT);
    }

    /// @notice Emergency signer rotation is allowed only while mint/bonus claims are paused.
    function setReaderBonusSigner(address signer) external onlyOwner whenPaused {
        if (signer == address(0)) revert InvalidSigner();
        address old = readerBonusSigner;
        readerBonusSigner = signer;
        emit ReaderBonusSignerSet(old, signer);
    }

    /// @notice Irreversibly closes Reader Bonus issuance and releases any unused reserved slots to paid mint.
    /// @dev Must be executed while paused. Published Reader Bonus terms should define the claim deadline/closure policy.
    function closeReaderBonusClaims() external onlyOwner whenPaused {
        if (readerBonusClaimsClosed) revert ReaderBonusClaimsAreClosed();
        readerBonusClaimsClosed = true;
        paidMintCap = MAX_SUPPLY - readerBonusMinted;
        emit ReaderBonusClaimsClosed(readerBonusMinted, paidMintCap);
    }

    function pauseMinting() external onlyOwner {
        _pause();
    }

    /// @notice Permanently freezes the ERC721-C transfer-validator address after marketplace testing.
    /// @dev The external validator's own security policy must also be configured and audited separately.
    function freezeTransferValidator() external onlyOwner whenPaused {
        address validator = address(getTransferValidator());
        if (block.chainid == 137 && (validator == address(0) || validator.code.length == 0)) {
            revert RegistryNotReady();
        }
        transferValidatorFrozen = true;
        emit TransferValidatorFrozen(validator);
    }

    /// @notice Sale cannot open until the collection is official+frozen in the Saga Registry and price is frozen.
    function unpauseMinting() external onlyOwner {
        if (metadataStage == MetadataStage.REVEALED) revert InvalidStage();
        if (!mintPriceFrozen) revert PriceNotFrozen();
        if (!transferValidatorFrozen) revert RegistryNotReady();
        if (!sagaRegistry.isOfficialCollection(address(this)) || !sagaRegistry.isCollectionFrozen(address(this))) {
            revert RegistryNotReady();
        }
        _unpause();
    }

    function setMysteryURI(string calldata uri) external onlyOwner {
        if (metadataFrozen) revert MetadataIsFrozen();
        if (metadataStage != MetadataStage.MYSTERY) revert InvalidStage();
        if (!_isIPFSURI(uri)) revert InvalidURI();
        mysteryURI = uri;
    }

    function setPreRevealURI(string calldata uri) external onlyOwner {
        if (metadataFrozen) revert MetadataIsFrozen();
        if (metadataStage == MetadataStage.REVEALED) revert InvalidStage();
        if (!_isIPFSURI(uri)) revert InvalidURI();
        preRevealURI = uri;
    }

    function setContractURI(string calldata uri) external onlyOwner {
        if (metadataFrozen) revert MetadataIsFrozen();
        if (!_isIPFSURI(uri)) revert InvalidURI();
        contractMetadataURI = uri;
        emit ContractURISet(uri);
    }

    function activatePreReveal() external onlyOwner {
        if (metadataFrozen || metadataStage != MetadataStage.MYSTERY) revert InvalidStage();
        metadataStage = MetadataStage.PRE_REVEAL;
        emit PreRevealActivated(preRevealURI);
    }

    /// @notice Reveals final metadata and the precommitted exact rarity permutation.
    /// @dev raritySeed must have been generated offline before deployment and kept secret until reveal.
    function reveal(string calldata baseURI_, bytes32 raritySeed) external onlyOwner {
        if (metadataFrozen || metadataStage != MetadataStage.PRE_REVEAL) revert InvalidStage();
        if (!paused()) revert InvalidStage();
        if (totalSupply() != MAX_SUPPLY) revert SupplyNotFinalized();
        if (!readerBonusClaimsClosed && readerBonusMinted != READER_BONUS_CAP) revert SupplyNotFinalized();
        if (!_isIPFSBaseURI(baseURI_)) revert InvalidURI();
        if (keccak256(abi.encode(raritySeed)) != rarityCommitment) revert InvalidRaritySeed();

        _baseTokenURI = baseURI_;

        // Offset range 165..1651 guarantees the single Unicorn resolves to tokenId 1..1487,
        // i.e. inside the paid allocation whenever the paid mint reaches its fixed cap.
        rarityOffset = 165 + (uint256(keccak256(abi.encodePacked(raritySeed, address(this)))) % 1_487);
        unicornTokenId = MAX_SUPPLY - rarityOffset;

        rarityRevealed = true;
        metadataStage = MetadataStage.REVEALED;

        emit Revealed(baseURI_, rarityOffset, unicornTokenId);
    }

    function freezeMetadata() external onlyOwner {
        if (metadataStage != MetadataStage.REVEALED) revert MetadataNotRevealed();
        if (metadataFrozen) revert MetadataIsFrozen();
        metadataFrozen = true;
        emit MetadataFrozen(_baseTokenURI, contractMetadataURI);
    }

    function contractURI() external view returns (string memory) {
        return contractMetadataURI;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireMinted(tokenId);

        if (metadataStage == MetadataStage.MYSTERY) return mysteryURI;
        if (metadataStage == MetadataStage.PRE_REVEAL) return preRevealURI;

        return string.concat(_baseTokenURI, tokenId.toString(), ".json");
    }

    function rarityTier(uint256 tokenId) public view override returns (uint8) {
        _requireMinted(tokenId);
        if (!rarityRevealed) revert RarityNotRevealed();

        uint256 slot = ((tokenId - 1 + rarityOffset) % MAX_SUPPLY) + 1;

        if (slot <= 826) return RARITY_COMMON;
        if (slot <= 1_239) return RARITY_UNCOMMON;
        if (slot <= 1_487) return RARITY_RARE;
        if (slot <= 1_586) return RARITY_EPIC;
        if (slot <= 1_635) return RARITY_LEGENDARY;
        if (slot <= 1_651) return RARITY_MYTHIC;
        return RARITY_UNICORN;
    }

    function rarityMultiplierBps(uint256 tokenId) external view override returns (uint16) {
        uint8 tier = rarityTier(tokenId);
        if (tier == RARITY_COMMON) return 10_000;
        if (tier == RARITY_UNCOMMON) return 10_500;
        if (tier == RARITY_RARE) return 11_000;
        if (tier == RARITY_EPIC) return 12_000;
        if (tier == RARITY_LEGENDARY) return 13_500;
        if (tier == RARITY_MYTHIC) return 15_000;
        return 20_000; // Unicorn = 2.00x
    }

    function isUnicornToken(uint256 tokenId) external view override returns (bool) {
        return rarityTier(tokenId) == RARITY_UNICORN;
    }

    function _isIPFSURI(string memory uri) internal pure returns (bool) {
        bytes memory b = bytes(uri);
        if (b.length < 8) return false;
        return
            b[0] == 0x69 &&
            b[1] == 0x70 &&
            b[2] == 0x66 &&
            b[3] == 0x73 &&
            b[4] == 0x3a &&
            b[5] == 0x2f &&
            b[6] == 0x2f;
    }

    function _isIPFSBaseURI(string memory uri) internal pure returns (bool) {
        bytes memory b = bytes(uri);
        return _isIPFSURI(uri) && b[b.length - 1] == 0x2f;
    }

    function _afterTokenTransfer(
        address from,
        address to,
        uint256 firstTokenId,
        uint256 batchSize
    ) internal virtual override {
        super._afterTokenTransfer(from, to, firstTokenId, batchSize);

        for (uint256 i; i < batchSize; ++i) {
            sagaRegistry.notifyTransfer(from, to);
        }
    }

    /// @dev Freezes all CreatorTokenBase owner-permissioned validator mutations once transferValidatorFrozen is true.
    function _requireCallerIsContractOwner() internal view virtual override(OwnableBasic, OwnablePermissions) {
        if (transferValidatorFrozen) revert TransferValidatorIsFrozen();
        super._requireCallerIsContractOwner();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721C, ERC2981)
        returns (bool)
    {
        return
            interfaceId == type(IThrinwulfCollection).interfaceId ||
            ERC721C.supportsInterface(interfaceId) ||
            ERC2981.supportsInterface(interfaceId);
    }
}
