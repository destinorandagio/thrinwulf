// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./interfaces/IThrinwulfSystem.sol";

/// @title THRINWULF Multi-Collection NFT Staking Vault
/// @notice Four whole-wallet DRX tiers with a weighted rarity multiplier over the NFTs actually staked.
/// @dev Starts with NEW STAKES PAUSED. Claims/unstakes remain available even if new stakes are paused.
contract ThrinwulfStakingVault is Ownable2Step, ReentrancyGuard, IERC721Receiver, IThrinwulfStakingVaultView {
    using SafeERC20 for IERC20;

    IERC20 public immutable DRX;
    uint256 public constant MAX_STAKED_PER_WALLET = 50;
    uint256 public constant BPS = 10_000;

    IThrinwulfSagaRegistry public immutable registry;
    bool public newStakesPaused = true;

    bool private _receiving;
    address private _expectedCollection;
    address private _expectedFrom;
    uint256 private _expectedTokenId;

    struct Asset {
        address collection;
        uint256 tokenId;
        uint16 rarityMultiplierBps;
    }

    struct UserState {
        uint256 accrued;
        uint64 lastCheckpoint;
    }

    mapping(bytes32 => address) public stakerOf;
    mapping(address => Asset[]) private _assets;
    mapping(address => mapping(bytes32 => uint256)) private _assetIndexPlusOne;
    mapping(address => UserState) public userState;
    mapping(address => uint256) private _multiplierSumBps;

    uint256 public totalStaked;
    uint256 public totalRewardsPaid;
    uint256 public totalRewardsFunded;

    event Staked(address indexed user, address indexed collection, uint256 indexed tokenId, uint16 rarityMultiplierBps);
    event Unstaked(address indexed user, address indexed collection, uint256 indexed tokenId);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardsFunded(address indexed funder, uint256 requestedAmount, uint256 receivedAmount);
    event NewStakesPaused(bool paused);

    error NotOfficialCollection();
    error InvalidQuantity();
    error NotStaker();
    error TooManyStaked();
    error NewStakesArePaused();
    error NothingToClaim();
    error InsufficientRewardReserve();
    error DirectNFTTransferRejected();
    error CannotRecoverDRX();
    error InvalidAddress();
    error RegistryNotReady();
    error RarityUnavailable();
    error InvalidRarityMultiplier();

    constructor(address registry_, address owner_, address drx_) {
        if (registry_ == address(0) || owner_ == address(0) || drx_ == address(0) || drx_.code.length == 0) {
            revert InvalidAddress();
        }
        if (IERC20Metadata(drx_).decimals() != 18) revert InvalidAddress();
        registry = IThrinwulfSagaRegistry(registry_);
        DRX = IERC20(drx_);
        _transferOwnership(owner_);
    }

    function tierForCount(uint256 count) public pure returns (uint8) {
        if (count >= 20) return 4;
        if (count >= 10) return 3;
        if (count >= 5) return 2;
        if (count >= 1) return 1;
        return 0;
    }

    function weeklyRewardForCount(uint256 count) public pure returns (uint256) {
        if (count >= 20) return 50 ether;
        if (count >= 10) return 20 ether;
        if (count >= 5) return 10 ether;
        if (count >= 1) return 1 ether;
        return 0;
    }

    function stakedCount(address user) public view override returns (uint256) {
        return _assets[user].length;
    }

    function stakedAssets(address user) external view returns (Asset[] memory) {
        return _assets[user];
    }

    function averageRarityMultiplierBps(address user) public view returns (uint256) {
        uint256 count = _assets[user].length;
        if (count == 0) return BPS;
        return _multiplierSumBps[user] / count;
    }

    function weeklyRewardForUser(address user) public view returns (uint256) {
        uint256 baseRate = weeklyRewardForCount(_assets[user].length);
        if (baseRate == 0) return 0;
        return (baseRate * averageRarityMultiplierBps(user)) / BPS;
    }

    function pendingRewards(address user) public view returns (uint256) {
        UserState memory s = userState[user];
        uint256 pending = s.accrued;
        if (s.lastCheckpoint != 0) {
            uint256 elapsed = block.timestamp - uint256(s.lastCheckpoint);
            pending += (weeklyRewardForUser(user) * elapsed) / 1 weeks;
        }
        return pending;
    }

    function _checkpoint(address user) internal {
        UserState storage s = userState[user];
        if (s.lastCheckpoint == 0) {
            s.lastCheckpoint = uint64(block.timestamp);
            return;
        }
        uint256 elapsed = block.timestamp - uint256(s.lastCheckpoint);
        s.accrued += (weeklyRewardForUser(user) * elapsed) / 1 weeks;
        s.lastCheckpoint = uint64(block.timestamp);
    }

    function stake(address collection, uint256[] calldata tokenIds) external nonReentrant {
        if (tokenIds.length == 0) revert InvalidQuantity();
        if (newStakesPaused) revert NewStakesArePaused();
        if (!registry.isOfficialCollection(collection)) revert NotOfficialCollection();
        if (_assets[msg.sender].length + tokenIds.length > MAX_STAKED_PER_WALLET) revert TooManyStaked();

        _checkpoint(msg.sender);

        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            bytes32 key = keccak256(abi.encode(collection, tokenId));
            if (stakerOf[key] != address(0)) revert NotStaker();

            uint16 multiplier;
            try IThrinwulfCollection(collection).rarityMultiplierBps(tokenId) returns (uint16 m) {
                multiplier = m;
            } catch {
                revert RarityUnavailable();
            }
            if (multiplier < BPS || multiplier > 20_000) revert InvalidRarityMultiplier();

            stakerOf[key] = msg.sender;
            _assets[msg.sender].push(Asset(collection, tokenId, multiplier));
            _assetIndexPlusOne[msg.sender][key] = _assets[msg.sender].length;
            _multiplierSumBps[msg.sender] += multiplier;

            _receiving = true;
            _expectedCollection = collection;
            _expectedFrom = msg.sender;
            _expectedTokenId = tokenId;

            IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId);

            _receiving = false;
            _expectedCollection = address(0);
            _expectedFrom = address(0);
            _expectedTokenId = 0;

            ++totalStaked;
            emit Staked(msg.sender, collection, tokenId, multiplier);
        }

        registry.notifyStakeChange(msg.sender, tokenIds.length, true);
    }

    function unstake(address collection, uint256[] calldata tokenIds) external nonReentrant {
        if (tokenIds.length == 0) revert InvalidQuantity();

        _checkpoint(msg.sender);

        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            bytes32 key = keccak256(abi.encode(collection, tokenId));
            if (stakerOf[key] != msg.sender) revert NotStaker();

            uint256 indexPlusOne = _assetIndexPlusOne[msg.sender][key];
            if (indexPlusOne == 0) revert NotStaker();

            uint256 index = indexPlusOne - 1;
            uint256 last = _assets[msg.sender].length - 1;
            uint16 removedMultiplier = _assets[msg.sender][index].rarityMultiplierBps;

            if (index != last) {
                Asset memory moved = _assets[msg.sender][last];
                _assets[msg.sender][index] = moved;
                bytes32 movedKey = keccak256(abi.encode(moved.collection, moved.tokenId));
                _assetIndexPlusOne[msg.sender][movedKey] = index + 1;
            }

            _assets[msg.sender].pop();
            delete _assetIndexPlusOne[msg.sender][key];
            delete stakerOf[key];
            _multiplierSumBps[msg.sender] -= removedMultiplier;

            --totalStaked;
            IERC721(collection).safeTransferFrom(address(this), msg.sender, tokenId);

            emit Unstaked(msg.sender, collection, tokenId);
        }

        registry.notifyStakeChange(msg.sender, tokenIds.length, false);
        userState[msg.sender].lastCheckpoint = uint64(block.timestamp);
    }

    function claimRewards() external nonReentrant {
        _checkpoint(msg.sender);

        UserState storage s = userState[msg.sender];
        uint256 amount = s.accrued;
        if (amount == 0) revert NothingToClaim();
        if (DRX.balanceOf(address(this)) < amount) revert InsufficientRewardReserve();

        s.accrued = 0;
        totalRewardsPaid += amount;

        DRX.safeTransfer(msg.sender, amount);
        emit RewardsClaimed(msg.sender, amount);
    }

    function fundRewards(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidQuantity();

        uint256 beforeBalance = DRX.balanceOf(address(this));
        DRX.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = DRX.balanceOf(address(this)) - beforeBalance;

        if (received == 0) revert InvalidQuantity();
        totalRewardsFunded += received;
        emit RewardsFunded(msg.sender, amount, received);
    }

    /// @notice New stakes can open only after the registry has frozen this vault and the reserve is funded.
    function setNewStakesPaused(bool paused_) external onlyOwner {
        if (!paused_) {
            if (
                registry.stakingVault() != address(this) ||
                !registry.stakingVaultFrozen()
            ) revert RegistryNotReady();

            if (DRX.balanceOf(address(this)) == 0) revert InsufficientRewardReserve();
        }

        newStakesPaused = paused_;
        emit NewStakesPaused(paused_);
    }

    function rewardReserve() external view returns (uint256) {
        return DRX.balanceOf(address(this));
    }

    function recoverUntrackedNFT(address collection, uint256 tokenId, address to) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        bytes32 key = keccak256(abi.encode(collection, tokenId));
        if (stakerOf[key] != address(0)) revert NotStaker();
        IERC721(collection).safeTransferFrom(address(this), to, tokenId);
    }

    function recoverERC20(address token, uint256 amount, address to) external onlyOwner {
        if (token == address(DRX)) revert CannotRecoverDRX();
        if (token == address(0) || to == address(0)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external view override returns (bytes4) {
        if (
            !_receiving ||
            operator != address(this) ||
            msg.sender != _expectedCollection ||
            from != _expectedFrom ||
            tokenId != _expectedTokenId ||
            !registry.isOfficialCollection(msg.sender)
        ) {
            revert DirectNFTTransferRejected();
        }

        return IERC721Receiver.onERC721Received.selector;
    }
}
