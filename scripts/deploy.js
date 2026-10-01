const { ethers } = require("hardhat");

async function main() {
  const token = await ethers.deployContract("MockUSDC");
  await token.waitForDeployment();

  const escrow = await ethers.deployContract("Escrow");
  await escrow.waitForDeployment();

  console.log(`MockUSDC: ${await token.getAddress()}`);
  console.log(`Escrow: ${await escrow.getAddress()}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});