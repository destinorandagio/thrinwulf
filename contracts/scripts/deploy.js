const hre = require("hardhat");
const { ethers } = hre;

const MAINNET = {
  USDT: "0xc2132D05D31c914a87C6611C10748AEb04B58e8F",
  DRX: "0x933767F8493f0AEB11A5f47f3BC28ab9072b1D27",
  TREASURY: "0x3C320B3a0917fF44BF6551CDdee44402AFcF250C"
};

function required(name) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing ${name}`);
  return v;
}
function address(name) {
  const v = required(name);
  if (!ethers.isAddress(v)) throw new Error(`Invalid ${name}`);
  return v;
}

async function tokenDecimals(tokenAddress) {
  const abi = ["function decimals() view returns (uint8)"];
  const c = new ethers.Contract(tokenAddress, abi, ethers.provider);
  return Number(await c.decimals());
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);
  if (![137,80002].includes(chainId)) throw new Error(`Wrong chain ${chainId}`);

  const finalOwner = address("FINAL_OWNER_ADDRESS");
  const readerSigner = address("READER_BONUS_SIGNER");
  const commitment = required("RARITY_COMMITMENT");
  if (!/^0x[0-9a-fA-F]{64}$/.test(commitment) || commitment === ethers.ZeroHash) {
    throw new Error("RARITY_COMMITMENT must be a non-zero bytes32 hash");
  }

  const mysteryURI = required("MYSTERY_METADATA_URI");
  const preRevealURI = required("PRE_REVEAL_METADATA_URI");
  const contractURI = required("CONTRACT_METADATA_URI");
  for (const uri of [mysteryURI,preRevealURI,contractURI]) {
    if (!uri.startsWith("ipfs://")) throw new Error("All metadata URIs must use ipfs://");
  }

  let usdtAddress, drxAddress, treasury;
  let mockUSDT = null, mockDRX = null;

  if (chainId === 137) {
    usdtAddress = MAINNET.USDT;
    drxAddress = MAINNET.DRX;
    treasury = MAINNET.TREASURY;

    if ((await ethers.provider.getCode(usdtAddress)) === "0x") throw new Error("Mainnet USDT has no code");
    if ((await ethers.provider.getCode(drxAddress)) === "0x") throw new Error("Mainnet DRX has no code");
    if (await tokenDecimals(usdtAddress) !== 6) throw new Error("Unexpected Polygon USDT decimals");
    if (await tokenDecimals(drxAddress) !== 18) throw new Error("Unexpected DRX decimals");
  } else {
    const Mock = await ethers.getContractFactory("MockERC20");
    mockUSDT = await Mock.deploy("THRINWULF Amoy USDT","tUSDT",6);
    await mockUSDT.waitForDeployment();
    mockDRX = await Mock.deploy("THRINWULF Amoy DRX","tDRX",18);
    await mockDRX.waitForDeployment();
    usdtAddress = await mockUSDT.getAddress();
    drxAddress = await mockDRX.getAddress();
    treasury = deployer.address;
  }

  // Bootstrap with deployer ownership so configuration/freeze can be atomic.
  const Registry = await ethers.getContractFactory("ThrinwulfSagaRegistry");
  const registry = await Registry.deploy(deployer.address);
  await registry.waitForDeployment();

  const Dawn = await ethers.getContractFactory("ThrinwulfDawnCollection");
  const dawn = await Dawn.deploy(
    deployer.address,
    await registry.getAddress(),
    readerSigner,
    usdtAddress,
    treasury,
    49_000_000n,
    mysteryURI,
    preRevealURI,
    contractURI,
    commitment
  );
  await dawn.waitForDeployment();

  const Vault = await ethers.getContractFactory("ThrinwulfStakingVault");
  const vault = await Vault.deploy(await registry.getAddress(), deployer.address, drxAddress);
  await vault.waitForDeployment();

  // Canonical release wiring, all while mint + staking remain paused.
  const loreHash = ethers.keccak256(ethers.toUtf8Bytes("THRINWULF|BOOK1|DAWN_OF_THE_DELTA|CANON_V1"));
  await (await registry.configureCollection(1, await dawn.getAddress(), loreHash)).wait();
  await (await registry.freezeCollection(1)).wait();
  await (await registry.configureStakingVault(await vault.getAddress())).wait();
  await (await registry.freezeStakingVault()).wait();
  await (await dawn.freezePaidMintPrice()).wait();

  if (chainId === 80002 && await dawn.getTransferValidator() !== ethers.ZeroAddress) {
    await (await dawn.setTransferValidator(ethers.ZeroAddress)).wait();
  }
  const validator = await dawn.getTransferValidator();
  if (chainId === 137 && (validator === ethers.ZeroAddress || (await ethers.provider.getCode(validator)) === "0x")) {
    throw new Error("ERC721-C transfer validator is not deployed on Polygon; do not freeze/open mint");
  }
  await (await dawn.freezeTransferValidator()).wait();

  // Ownership handoff. Registry/Vault are Ownable2Step and require FINAL_OWNER to accept.
  if (finalOwner.toLowerCase() !== deployer.address.toLowerCase()) {
    await (await dawn.transferOwnership(finalOwner)).wait();
    await (await registry.transferOwnership(finalOwner)).wait();
    await (await vault.transferOwnership(finalOwner)).wait();
  }

  const result = {
    network: chainId === 137 ? "polygon-mainnet" : "polygon-amoy",
    chainId,
    deployer: deployer.address,
    finalOwner,
    readerBonusSigner: readerSigner,
    treasury,
    usdt: usdtAddress,
    drx: drxAddress,
    registry: await registry.getAddress(),
    dawnCollection: await dawn.getAddress(),
    stakingVault: await vault.getAddress(),
    publicMintPriceMicroUSDT: "49000000",
    publicMintPriceUSDT: "49",
    initialPaidCap: 1487,
    readerBonusMax: 165,
    maxSupply: 1652,
    status: {
      mintPaused: await dawn.paused(),
      paidPriceFrozen: await dawn.mintPriceFrozen(),
      transferValidatorFrozen: await dawn.transferValidatorFrozen(),
      stakingPaused: await vault.newStakesPaused(),
      collectionSlotFrozen: await registry.isCollectionFrozen(await dawn.getAddress()),
      stakingVaultFrozen: await registry.stakingVaultFrozen()
    },
    ownershipAcceptanceRequired: finalOwner.toLowerCase() !== deployer.address.toLowerCase()
  };

  console.log(JSON.stringify(result,null,2));
  console.log("\nPRODUCTION REMAINS FAIL-CLOSED.");
  console.log("Do NOT unpause mint until source verification, ERC721-C marketplace policy checks, DApp address checks and owner handoff are complete.");
}

main().catch((err)=>{ console.error(err); process.exit(1); });
