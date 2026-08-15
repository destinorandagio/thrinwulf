// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./interfaces/IThrinwulfSystem.sol";

/// @title THRINWULF Saga Registry
/// @notice Canonical registry, beneficial-holdings ledger, DAO rank oracle and World Guardian clock.
/// @dev Official collections must notify every mint/transfer/burn. The staking vault notifies stake/unstake deltas.
contract ThrinwulfSagaRegistry is Ownable2Step {
    uint8 public constant BOOK_COUNT = 9;
    uint256 public constant WORLD_GUARDIAN_THRESHOLD = 100;
    uint256 public constant WORLD_GUARDIAN_HOLD_DAYS = 365 days;

    struct CollectionRecord {
        address collection;
        bytes32 loreHash;
        bool frozen;
    }

    mapping(uint8 => CollectionRecord) private _records;
    mapping(address => uint8) public bookOfCollection;

    address public stakingVault;
    bool public stakingVaultFrozen;

    mapping(address => uint256) public directOfficialHoldings;
    mapping(address => uint256) public stakedOfficialHoldings;

    mapping(address => uint64) public worldGuardianSince;
    mapping(address => bool) public worldGuardianUnlocked;

    event CollectionConfigured(uint8 indexed book, address indexed collection, bytes32 indexed loreHash);
    event CollectionFrozen(uint8 indexed book, address indexed collection);
    event StakingVaultConfigured(address indexed vault);
    event StakingVaultFrozen(address indexed vault);
    event HoldingsChanged(address indexed user, uint256 directHoldings, uint256 stakedHoldings, uint256 totalEligible);
    event WorldGuardianClockStarted(address indexed user, uint64 since);
    event WorldGuardianClockReset(address indexed user);
    event WorldGuardianUnlocked(address indexed user, uint64 qualifiedSince, uint64 unlockedAt);

    error InvalidBook();
    error InvalidCollection();
    error InvalidLoreHash();
    error SlotFrozen();
    error CollectionAlreadyRegistered();
    error CollectionAlreadyMinted();
    error NotOfficialCollection();
    error NotStakingVault();
    error VaultFrozen();
    error HoldingsInvariant();
    error WorldGuardianNotReady();
    error AlreadyUnlocked();

    constructor(address owner_) {
        if (owner_ == address(0)) revert InvalidCollection();
        _transferOwnership(owner_);
    }

    function configureCollection(uint8 book, address collection, bytes32 loreHash) external onlyOwner {
        if (book == 0 || book > BOOK_COUNT) revert InvalidBook();
        if (collection == address(0) || collection.code.length == 0) revert InvalidCollection();
        if (loreHash == bytes32(0)) revert InvalidLoreHash();
        if (_records[book].frozen) revert SlotFrozen();

        uint8 existing = bookOfCollection[collection];
        if (existing != 0 && existing != book) revert CollectionAlreadyRegistered();

        try IERC165(collection).supportsInterface(type(IERC721).interfaceId) returns (bool ok721) {
            if (!ok721) revert InvalidCollection();
        } catch {
            revert InvalidCollection();
        }

        try IERC165(collection).supportsInterface(type(IThrinwulfCollection).interfaceId) returns (bool okThrinwulf) {
            if (!okThrinwulf) revert InvalidCollection();
        } catch {
            revert InvalidCollection();
        }

        try IThrinwulfCollection(collection).totalSupply() returns (uint256 supply) {
            if (supply != 0) revert CollectionAlreadyMinted();
        } catch {
            revert InvalidCollection();
        }

        address old = _records[book].collection;
        if (old != address(0) && old != collection) {
            delete bookOfCollection[old];
        }

        _records[book] = CollectionRecord({
            collection: collection,
            loreHash: loreHash,
            frozen: false
        });
        bookOfCollection[collection] = book;

        emit CollectionConfigured(book, collection, loreHash);
    }

    function freezeCollection(uint8 book) external onlyOwner {
        if (book == 0 || book > BOOK_COUNT) revert InvalidBook();
        CollectionRecord storage r = _records[book];
        if (r.collection == address(0)) revert InvalidCollection();
        r.frozen = true;
        emit CollectionFrozen(book, r.collection);
    }

    function configureStakingVault(address vault) external onlyOwner {
        if (stakingVaultFrozen) revert VaultFrozen();
        if (vault == address(0) || vault.code.length == 0) revert InvalidCollection();
        try IThrinwulfStakingVaultView(vault).stakedCount(address(this)) returns (uint256) {
        } catch {
            revert InvalidCollection();
        }
        stakingVault = vault;
        emit StakingVaultConfigured(vault);
    }

    function freezeStakingVault() external onlyOwner {
        if (stakingVault == address(0)) revert InvalidCollection();
        stakingVaultFrozen = true;
        emit StakingVaultFrozen(stakingVault);
    }

    function getCollection(uint8 book) external view returns (CollectionRecord memory) {
        if (book == 0 || book > BOOK_COUNT) revert InvalidBook();
        return _records[book];
    }

    function isOfficialCollection(address collection) public view returns (bool) {
        uint8 book = bookOfCollection[collection];
        return book != 0 && _records[book].collection == collection;
    }

    function isCollectionFrozen(address collection) external view returns (bool) {
        uint8 book = bookOfCollection[collection];
        return book != 0 && _records[book].collection == collection && _records[book].frozen;
    }

    /// @notice Called by an official collection after each individual mint/transfer/burn.
    function notifyTransfer(address from, address to) external {
        if (!isOfficialCollection(msg.sender)) revert NotOfficialCollection();

        if (from != address(0)) {
            uint256 directFrom = directOfficialHoldings[from];
            if (directFrom == 0) revert HoldingsInvariant();
            unchecked { directOfficialHoldings[from] = directFrom - 1; }
        }
        if (to != address(0)) {
            directOfficialHoldings[to] += 1;
        }

        // A transfer into/out of the official vault is only an ownership-form change.
        // The vault checkpoints the beneficial holder after its stake accounting is complete.
        if (from != address(0) && from != stakingVault && to != stakingVault) {
            _checkpointWorldGuardian(from);
            _emitHoldings(from);
        }
        if (to != address(0) && to != stakingVault && from != stakingVault && to != from) {
            _checkpointWorldGuardian(to);
            _emitHoldings(to);
        }
    }

    /// @notice Called once per completed stake/unstake batch by the frozen official staking vault.
    function notifyStakeChange(address user, uint256 quantity, bool staking) external {
        if (msg.sender != stakingVault || !stakingVaultFrozen) revert NotStakingVault();
        if (user == address(0) || quantity == 0) revert HoldingsInvariant();

        if (staking) {
            stakedOfficialHoldings[user] += quantity;
        } else {
            uint256 current = stakedOfficialHoldings[user];
            if (current < quantity) revert HoldingsInvariant();
            unchecked { stakedOfficialHoldings[user] = current - quantity; }
        }

        _checkpointWorldGuardian(user);
        _emitHoldings(user);
    }

    function eligibleHoldings(address user) public view returns (uint256) {
        return directOfficialHoldings[user] + stakedOfficialHoldings[user];
    }

    /// @notice 0=None, 1=Bronze, 2=Silver, 3=Gold, 4=Platinum.
    function wolfRank(address user) external view returns (uint8) {
        return wolfRankForCount(eligibleHoldings(user));
    }

    function wolfRankForCount(uint256 count) public pure returns (uint8) {
        if (count >= 20) return 4;
        if (count >= 10) return 3;
        if (count >= 5) return 2;
        if (count >= 1) return 1;
        return 0;
    }

    function daoWeight(address user) external view returns (uint8) {
        return daoWeightForCount(eligibleHoldings(user));
    }

    function daoWeightForCount(uint256 count) public pure returns (uint8) {
        if (count >= 20) return 8;
        if (count >= 10) return 4;
        if (count >= 5) return 2;
        if (count >= 1) return 1;
        return 0;
    }

    function worldGuardianEligible(address user) public view returns (bool) {
        if (worldGuardianUnlocked[user]) return true;
        uint64 since = worldGuardianSince[user];
        return since != 0 &&
            eligibleHoldings(user) >= WORLD_GUARDIAN_THRESHOLD &&
            block.timestamp >= uint256(since) + WORLD_GUARDIAN_HOLD_DAYS;
    }

    /// @notice Permanently records wallet-level qualification after 365 uninterrupted qualifying days.
    /// @dev Off-chain KYC/terms enforce the separate one-lifetime-trip-per-natural-person rule.
    function unlockWorldGuardian() external {
        if (worldGuardianUnlocked[msg.sender]) revert AlreadyUnlocked();
        if (!worldGuardianEligible(msg.sender)) revert WorldGuardianNotReady();
        uint64 since = worldGuardianSince[msg.sender];
        worldGuardianUnlocked[msg.sender] = true;
        emit WorldGuardianUnlocked(msg.sender, since, uint64(block.timestamp));
    }

    function _checkpointWorldGuardian(address user) internal {
        if (user == address(0) || worldGuardianUnlocked[user]) return;

        uint256 count = eligibleHoldings(user);
        uint64 since = worldGuardianSince[user];

        if (count >= WORLD_GUARDIAN_THRESHOLD) {
            if (since == 0) {
                uint64 now64 = uint64(block.timestamp);
                worldGuardianSince[user] = now64;
                emit WorldGuardianClockStarted(user, now64);
            }
        } else if (since != 0) {
            worldGuardianSince[user] = 0;
            emit WorldGuardianClockReset(user);
        }
    }

    function _emitHoldings(address user) internal {
        emit HoldingsChanged(
            user,
            directOfficialHoldings[user],
            stakedOfficialHoldings[user],
            eligibleHoldings(user)
        );
    }
}
