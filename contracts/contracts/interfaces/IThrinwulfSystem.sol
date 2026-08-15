// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IThrinwulfCollection {
    function totalSupply() external view returns (uint256);
    function rarityRevealed() external view returns (bool);
    function rarityTier(uint256 tokenId) external view returns (uint8);
    function rarityMultiplierBps(uint256 tokenId) external view returns (uint16);
    function isUnicornToken(uint256 tokenId) external view returns (bool);
}

interface IThrinwulfSagaRegistry {
    function isOfficialCollection(address collection) external view returns (bool);
    function isCollectionFrozen(address collection) external view returns (bool);
    function stakingVault() external view returns (address);
    function stakingVaultFrozen() external view returns (bool);
    function notifyTransfer(address from, address to) external;
    function notifyStakeChange(address user, uint256 quantity, bool staking) external;
}

interface IThrinwulfStakingVaultView {
    function stakedCount(address user) external view returns (uint256);
}
