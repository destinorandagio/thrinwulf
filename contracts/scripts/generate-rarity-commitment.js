const crypto = require("crypto");
const { ethers } = require("ethers");

const seed = "0x" + crypto.randomBytes(32).toString("hex");
const commitment = ethers.keccak256(
  ethers.AbiCoder.defaultAbiCoder().encode(["bytes32"], [seed])
);

console.log("THRINWULF RARITY SEED — KEEP OFFLINE / SECRET UNTIL REVEAL");
console.log("SEED:", seed);
console.log("PUBLIC COMMITMENT:", commitment);
console.log("\nStore the SEED offline. Put ONLY the PUBLIC COMMITMENT into deployment configuration.");
