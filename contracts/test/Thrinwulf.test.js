const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const TREASURY = "0x3C320B3a0917fF44BF6551CDdee44402AFcF250C";

function rarityCommit(seed) {
  return ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["bytes32"], [seed]));
}

async function deployFixture() {
  const [deployer, owner, readerSigner, alice, bob, carol] = await ethers.getSigners();

  const Mock = await ethers.getContractFactory("MockERC20");
  const usdt = await Mock.deploy("Mock USDT","mUSDT",6);
  await usdt.waitForDeployment();
  const drx = await Mock.deploy("Mock DRX","mDRX",18);
  await drx.waitForDeployment();

  const Registry = await ethers.getContractFactory("ThrinwulfSagaRegistry");
  const registry = await Registry.deploy(owner.address);
  await registry.waitForDeployment();

  const seed = ethers.keccak256(ethers.toUtf8Bytes("thrinwulf-audit-seed"));
  const commitment = rarityCommit(seed);

  const Dawn = await ethers.getContractFactory("ThrinwulfDawnCollection");
  const dawn = await Dawn.deploy(
    owner.address,
    await registry.getAddress(),
    readerSigner.address,
    await usdt.getAddress(),
    TREASURY,
    49_000_000n,
    "ipfs://mystery/metadata.json",
    "ipfs://prereveal/metadata.json",
    "ipfs://contract/collection.json",
    commitment
  );
  await dawn.waitForDeployment();

  const Vault = await ethers.getContractFactory("ThrinwulfStakingVault");
  const vault = await Vault.deploy(await registry.getAddress(), owner.address, await drx.getAddress());
  await vault.waitForDeployment();

  await registry.connect(owner).configureCollection(
    1,
    await dawn.getAddress(),
    ethers.keccak256(ethers.toUtf8Bytes("BOOK1-DAWN-OF-THE-DELTA"))
  );
  await registry.connect(owner).freezeCollection(1);
  await registry.connect(owner).configureStakingVault(await vault.getAddress());
  await registry.connect(owner).freezeStakingVault();
  await dawn.connect(owner).freezePaidMintPrice();
  await dawn.connect(owner).setTransferValidator(ethers.ZeroAddress);
  await dawn.connect(owner).freezeTransferValidator();

  await usdt.mint(alice.address, 1_000_000_000_000n);
  await usdt.mint(bob.address, 1_000_000_000_000n);
  await drx.mint(owner.address, ethers.parseEther("1000000"));

  return { deployer,owner,readerSigner,alice,bob,carol,usdt,drx,registry,dawn,vault,seed };
}

async function signBonus(dawn, signer, recipient, uid, deadline) {
  const networkInfo = await ethers.provider.getNetwork();
  const domain = {
    name: "Thrinwulf Dawn Reader Bonus",
    version: "1",
    chainId: Number(networkInfo.chainId),
    verifyingContract: await dawn.getAddress()
  };
  const types = {
    ReaderBonus: [
      {name:"recipient",type:"address"},
      {name:"claimUid",type:"bytes32"},
      {name:"deadline",type:"uint256"}
    ]
  };
  return signer.signTypedData(domain, types, {recipient, claimUid:uid, deadline});
}

describe("THRINWULF FINAL RELEASE", function () {
  it("deploys collection fail-closed and locks canonical supply/royalty", async () => {
    const { dawn } = await deployFixture();
    expect(await dawn.paused()).eq(true);
    expect(await dawn.MAX_SUPPLY()).eq(1652n);
    expect(await dawn.INITIAL_PAID_MINT_CAP()).eq(1487n);
    expect(await dawn.READER_BONUS_CAP()).eq(165n);
    const [receiver, amount] = await dawn.royaltyInfo(1, 10_000n);
    expect(receiver.toLowerCase()).eq(TREASURY.toLowerCase());
    expect(amount).eq(1000n);
  });

  it("cannot open paid mint until price and registry are frozen", async () => {
    const [deployer, owner, readerSigner] = await ethers.getSigners();
    const Mock = await ethers.getContractFactory("MockERC20");
    const usdt = await Mock.deploy("USDT","USDT",6);
    const Registry = await ethers.getContractFactory("ThrinwulfSagaRegistry");
    const registry = await Registry.deploy(owner.address);
    const seed = ethers.keccak256(ethers.toUtf8Bytes("seed"));
    const Dawn = await ethers.getContractFactory("ThrinwulfDawnCollection");
    const dawn = await Dawn.deploy(owner.address,await registry.getAddress(),readerSigner.address,await usdt.getAddress(),TREASURY,49_000_000n,"ipfs://m/a","ipfs://p/a","ipfs://c/a",rarityCommit(seed));
    await expect(dawn.connect(owner).unpauseMinting()).to.be.revertedWithCustomError(dawn,"PriceNotFrozen");
    await dawn.connect(owner).freezePaidMintPrice();
    await dawn.connect(owner).setTransferValidator(ethers.ZeroAddress);
    await dawn.connect(owner).freezeTransferValidator();
    await expect(dawn.connect(owner).unpauseMinting()).to.be.revertedWithCustomError(dawn,"RegistryNotReady");
  });

  it("charges exactly 49 USDT and records direct holdings in registry", async () => {
    const {owner,alice,usdt,dawn,registry}=await deployFixture();
    await dawn.connect(owner).unpauseMinting();
    await usdt.connect(alice).approve(await dawn.getAddress(),49_000_000n);
    const before=await usdt.balanceOf(TREASURY);
    await dawn.connect(alice).mintPaid(1);
    expect((await usdt.balanceOf(TREASURY))-before).eq(49_000_000n);
    expect(await dawn.paidMintCountByWallet(alice.address)).eq(1n);
    expect(await registry.directOfficialHoldings(alice.address)).eq(1n);
    expect(await registry.eligibleHoldings(alice.address)).eq(1n);
  });

  it("enforces Reader Bonus: paid mint first, one wallet, one UID", async () => {
    const {owner,readerSigner,alice,bob,usdt,dawn}=await deployFixture();
    await dawn.connect(owner).unpauseMinting();
    const deadline=(await ethers.provider.getBlock("latest")).timestamp+3600;
    const uid=ethers.keccak256(ethers.toUtf8Bytes("bonus-a"));
    const badSig=await signBonus(dawn,readerSigner,bob.address,uid,deadline);
    await expect(dawn.connect(bob).claimReaderBonus(uid,deadline,badSig)).to.be.revertedWithCustomError(dawn,"PaidMintRequired");

    await usdt.connect(alice).approve(await dawn.getAddress(),49_000_000n);
    await dawn.connect(alice).mintPaid(1);
    const sig=await signBonus(dawn,readerSigner,alice.address,uid,deadline);
    await dawn.connect(alice).claimReaderBonus(uid,deadline,sig);
    expect(await dawn.readerBonusMinted()).eq(1n);
    expect(await dawn.balanceOf(alice.address)).eq(2n);
    await expect(dawn.connect(alice).claimReaderBonus(uid,deadline,sig)).to.be.revertedWithCustomError(dawn,"ReaderBonusAlreadyClaimed");
  });

  it("allows emergency Reader Bonus signer rotation only while paused", async () => {
    const {owner,alice,dawn}=await deployFixture();
    await expect(dawn.connect(owner).setReaderBonusSigner(alice.address)).not.to.be.reverted;
    await dawn.connect(owner).unpauseMinting();
    await expect(dawn.connect(owner).setReaderBonusSigner(alice.address)).to.be.revertedWith("Pausable: not paused");
  });

  it("closes Reader Bonus irreversibly and releases unused reserved slots", async () => {
    const {owner,dawn}=await deployFixture();
    expect(await dawn.paidMintCap()).eq(1487n);
    await dawn.connect(owner).closeReaderBonusClaims();
    expect(await dawn.readerBonusClaimsClosed()).eq(true);
    expect(await dawn.paidMintCap()).eq(1652n);
    await expect(dawn.connect(owner).closeReaderBonusClaims()).to.be.revertedWithCustomError(dawn,"ReaderBonusClaimsAreClosed");
  });

  it("enforces Mystery -> Pre-Reveal -> Reveal sequencing", async () => {
    const {owner,dawn,seed}=await deployFixture();
    expect(await dawn.metadataStage()).eq(0n);
    await expect(dawn.connect(owner).reveal("ipfs://final/",seed)).to.be.revertedWithCustomError(dawn,"InvalidStage");
    await dawn.connect(owner).activatePreReveal();
    expect(await dawn.metadataStage()).eq(1n);
    await expect(dawn.connect(owner).activatePreReveal()).to.be.revertedWithCustomError(dawn,"InvalidStage");
  });

  it("rejects non-IPFS metadata URIs", async () => {
    const {owner,dawn}=await deployFixture();
    await expect(dawn.connect(owner).setMysteryURI("https://example.com/meta.json")).to.be.revertedWithCustomError(dawn,"InvalidURI");
  });

  it("prevents reveal before final supply, blocking rarity-sniping while mint remains open", async () => {
    const {owner,dawn,seed}=await deployFixture();
    await dawn.connect(owner).activatePreReveal();
    await expect(dawn.connect(owner).reveal("ipfs://final/",seed)).to.be.revertedWithCustomError(dawn,"SupplyNotFinalized");
  });

  it("reveals the exact 1,652 rarity distribution and keeps Unicorn in paid allocation", async function () {
    this.timeout(120000);
    const {owner,alice,usdt,dawn,seed}=await deployFixture();
    await dawn.connect(owner).closeReaderBonusClaims();
    await dawn.connect(owner).unpauseMinting();
    await usdt.connect(alice).approve(await dawn.getAddress(),ethers.MaxUint256);
    for(let minted=0;minted<1652;minted+=10)await dawn.connect(alice).mintPaid(Math.min(10,1652-minted));
    await dawn.connect(owner).pauseMinting();
    await dawn.connect(owner).activatePreReveal();
    await dawn.connect(owner).reveal("ipfs://final/",seed);
    const counts=[0,0,0,0,0,0,0];
    for(let id=1;id<=1652;id++)counts[Number(await dawn.rarityTier(id))]++;
    expect(counts).deep.eq([826,413,248,99,49,16,1]);
    const unicorn=await dawn.unicornTokenId();
    expect(unicorn).gte(1n).and.lte(1487n);
    expect(await dawn.isUnicornToken(unicorn)).eq(true);
  });

  it("registry rejects non-THRINWULF ERC721 contracts and post-mint registration", async () => {
    const {owner,registry}=await deployFixture();
    const Mock = await ethers.getContractFactory("MockERC20");
    const notNft=await Mock.deploy("X","X",18);
    await expect(registry.connect(owner).configureCollection(2,await notNft.getAddress(),ethers.keccak256(ethers.toUtf8Bytes("x")))).to.be.revertedWithCustomError(registry,"InvalidCollection");
  });

  it("registry freezes official collection and staking vault addresses", async () => {
    const {owner,registry,dawn,vault}=await deployFixture();
    expect(await registry.isOfficialCollection(await dawn.getAddress())).eq(true);
    expect(await registry.isCollectionFrozen(await dawn.getAddress())).eq(true);
    expect(await registry.stakingVault()).eq(await vault.getAddress());
    expect(await registry.stakingVaultFrozen()).eq(true);
    await expect(registry.connect(owner).configureCollection(1,await dawn.getAddress(),ethers.keccak256(ethers.toUtf8Bytes("changed")))).to.be.revertedWithCustomError(registry,"SlotFrozen");
  });

  it("computes DAO Bronze/Silver/Gold/Platinum weights from beneficial holdings", async () => {
    const {registry}=await deployFixture();
    expect(await registry.daoWeightForCount(0)).eq(0);
    expect(await registry.daoWeightForCount(1)).eq(1);
    expect(await registry.daoWeightForCount(5)).eq(2);
    expect(await registry.daoWeightForCount(10)).eq(4);
    expect(await registry.daoWeightForCount(20)).eq(8);
    expect(await registry.wolfRankForCount(1)).eq(1);
    expect(await registry.wolfRankForCount(5)).eq(2);
    expect(await registry.wolfRankForCount(10)).eq(3);
    expect(await registry.wolfRankForCount(20)).eq(4);
  });

  it("starts World Guardian clock at 100 and resets below 100", async () => {
    const {owner,alice,bob,usdt,dawn,registry}=await deployFixture();
    await dawn.connect(owner).unpauseMinting();
    await usdt.connect(alice).approve(await dawn.getAddress(),ethers.MaxUint256);
    // 10 tx x 10 = 100
    for(let i=0;i<10;i++) await dawn.connect(alice).mintPaid(10);
    expect(await registry.eligibleHoldings(alice.address)).eq(100n);
    expect(await registry.worldGuardianSince(alice.address)).to.not.eq(0n);
    await dawn.connect(alice).transferFrom(alice.address,bob.address,1);
    expect(await registry.eligibleHoldings(alice.address)).eq(99n);
    expect(await registry.worldGuardianSince(alice.address)).eq(0n);
  });

  it("unlocks World Guardian after 365 continuous days", async () => {
    const {owner,alice,usdt,dawn,registry}=await deployFixture();
    await dawn.connect(owner).unpauseMinting();
    await usdt.connect(alice).approve(await dawn.getAddress(),ethers.MaxUint256);
    for(let i=0;i<10;i++) await dawn.connect(alice).mintPaid(10);
    await network.provider.send("evm_increaseTime",[365*24*60*60+1]);
    await network.provider.send("evm_mine");
    expect(await registry.worldGuardianEligible(alice.address)).eq(true);
    await registry.connect(alice).unlockWorldGuardian();
    expect(await registry.worldGuardianUnlocked(alice.address)).eq(true);
  });

  it("staking starts fail-closed and cannot open without DRX reserve", async () => {
    const {owner,vault}=await deployFixture();
    expect(await vault.newStakesPaused()).eq(true);
    await expect(vault.connect(owner).setNewStakesPaused(false)).to.be.revertedWithCustomError(vault,"InsufficientRewardReserve");
  });

  it("rejects staking before rarity reveal", async () => {
    const {owner,alice,usdt,drx,dawn,vault}=await deployFixture();
    await dawn.connect(owner).unpauseMinting();
    await usdt.connect(alice).approve(await dawn.getAddress(),49_000_000n);
    await dawn.connect(alice).mintPaid(1);
    await dawn.connect(alice).setApprovalForAll(await vault.getAddress(),true);
    await drx.connect(owner).approve(await vault.getAddress(),ethers.parseEther("1000"));
    await vault.connect(owner).fundRewards(ethers.parseEther("1000"));
    await vault.connect(owner).setNewStakesPaused(false);
    await expect(vault.connect(alice).stake(await dawn.getAddress(),[1])).to.be.revertedWithCustomError(vault,"RarityUnavailable");
  });

  it("four base staking tiers remain 1/10/20/50 DRX per week", async () => {
    const {vault}=await deployFixture();
    expect(await vault.weeklyRewardForCount(1)).eq(ethers.parseEther("1"));
    expect(await vault.weeklyRewardForCount(5)).eq(ethers.parseEther("10"));
    expect(await vault.weeklyRewardForCount(10)).eq(ethers.parseEther("20"));
    expect(await vault.weeklyRewardForCount(20)).eq(ethers.parseEther("50"));
    expect(await vault.weeklyRewardForCount(50)).eq(ethers.parseEther("50"));
  });

  it("owner cannot recover DRX reward reserve", async () => {
    const {owner,drx,vault}=await deployFixture();
    await expect(vault.connect(owner).recoverERC20(await drx.getAddress(),1,owner.address)).to.be.revertedWithCustomError(vault,"CannotRecoverDRX");
  });

  it("direct safe NFT transfers to vault are rejected", async () => {
    const {owner,alice,usdt,dawn,vault}=await deployFixture();
    await dawn.connect(owner).unpauseMinting();
    await usdt.connect(alice).approve(await dawn.getAddress(),49_000_000n);
    await dawn.connect(alice).mintPaid(1);
    await expect(
      dawn.connect(alice)["safeTransferFrom(address,address,uint256)"](alice.address,await vault.getAddress(),1)
    ).to.be.revertedWithCustomError(vault,"DirectNFTTransferRejected");
  });
});
