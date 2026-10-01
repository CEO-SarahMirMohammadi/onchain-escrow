const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Onchain Escrow", function () {
  const units = (amount) => ethers.parseUnits(amount.toString(), 6);
  const hash = (value) => ethers.keccak256(ethers.toUtf8Bytes(value));
  let buyer;
  let seller;
  let other;
  let arbitrator;
  let token;
  let escrow;

  async function createEscrow(milestones = 1, { deadlineOffset = 3600 } = {}) {
    const now = (await ethers.provider.getBlock("latest")).timestamp;
    const deadline = now + deadlineOffset;
    const id = await escrow.nextEscrowId();
    await escrow.connect(buyer).createEscrow(
      seller.address,
      await token.getAddress(),
      units(100 * milestones),
      units(100),
      milestones,
      deadline
    );
    return id;
  }

  async function fundAndAccept(id) {
    await escrow.connect(buyer).fundEscrow(id);
    await escrow.connect(seller).acceptEscrow(id);
  }

  beforeEach(async function () {
    [buyer, seller, other, arbitrator] = await ethers.getSigners();
    token = await ethers.deployContract("MockUSDC");
    escrow = await ethers.deployContract("Escrow");
    await token.mint(buyer.address, units(10_000));
    await token.connect(buyer).approve(await escrow.getAddress(), ethers.MaxUint256);
  });

  it("deploys a six-decimal token and starts escrow IDs at one", async function () {
    expect(await token.decimals()).to.equal(6);
    expect(await escrow.nextEscrowId()).to.equal(1);
  });

  it("creates, funds, accepts, approves, releases, and withdraws a milestone", async function () {
    const id = await createEscrow();
    let record = await escrow.getEscrow(id);
    expect(record.buyer).to.equal(buyer.address);
    expect(record.state).to.equal(0);
    expect(await escrow.getUserContribution(id, buyer.address)).to.equal(0);

    await fundAndAccept(id);
    expect(await token.balanceOf(await escrow.getAddress())).to.equal(units(100));
    expect(await escrow.getUserContribution(id, buyer.address)).to.equal(units(100));
    await escrow.connect(seller).submitMilestone(id, hash("delivery-1"));
    await expect(escrow.connect(buyer).approveMilestone(id))
      .to.emit(escrow, "MilestoneApproved").withArgs(id, 1, buyer.address);
    await escrow.connect(other).releaseMilestone(id);

    record = await escrow.getEscrow(id);
    expect(record.state).to.equal(3);
    expect(record.releasedAmount).to.equal(units(100));
    expect(await escrow.claimable(await token.getAddress(), seller.address)).to.equal(units(100));
    await escrow.connect(seller).withdraw(await token.getAddress());
    expect(await token.balanceOf(seller.address)).to.equal(units(100));
  });

  it("supports sequential milestones and completes only after the final release", async function () {
    const id = await createEscrow(3);
    await fundAndAccept(id);

    for (let milestone = 1; milestone <= 3; milestone += 1) {
      await escrow.connect(seller).submitMilestone(id, hash(`delivery-${milestone}`));
      await escrow.connect(buyer).approveMilestone(id);
      await escrow.releaseMilestone(id);
      expect((await escrow.getEscrow(id)).completedMilestones).to.equal(milestone);
    }

    expect((await escrow.getEscrow(id)).state).to.equal(3);
    expect(await escrow.getRemainingAmount(id)).to.equal(0);
    expect(await escrow.claimable(await token.getAddress(), seller.address)).to.equal(units(300));
  });

  it("rejects invalid plans, unauthorized roles, and invalid transitions", async function () {
    const id = await createEscrow();
    await expect(escrow.connect(other).fundEscrow(id)).to.be.revertedWithCustomError(escrow, "Unauthorized");
    await expect(escrow.connect(seller).acceptEscrow(id)).to.be.revertedWithCustomError(escrow, "InvalidState");
    await expect(escrow.connect(buyer).createEscrow(
      seller.address, await token.getAddress(), units(101), units(100), 1,
      (await ethers.provider.getBlock("latest")).timestamp + 3600
    )).to.be.revertedWithCustomError(escrow, "InvalidMilestonePlan");
    await expect(escrow.connect(other).approveMilestone(id)).to.be.revertedWithCustomError(escrow, "Unauthorized");
    await expect(escrow.connect(buyer).approveMilestone(id)).to.be.revertedWithCustomError(escrow, "InvalidState");
    await expect(escrow.releaseMilestone(id)).to.be.revertedWithCustomError(escrow, "InvalidState");
  });

  it("cancels an unfunded escrow and refunds a funded escrow before acceptance", async function () {
    const unfundedId = await createEscrow();
    await escrow.connect(buyer).cancelEscrow(unfundedId);
    expect((await escrow.getEscrow(unfundedId)).state).to.equal(6);

    const fundedId = await createEscrow();
    await escrow.connect(buyer).fundEscrow(fundedId);
    await escrow.connect(buyer).cancelEscrow(fundedId);
    await escrow.connect(buyer).refund(fundedId);
    expect(await token.balanceOf(buyer.address)).to.equal(units(10_000));
    expect((await escrow.getEscrow(fundedId)).state).to.equal(6);
  });

  it("allows buyer or seller to raise a dispute and resolves fully for the seller", async function () {
    const id = await createEscrow();
    await fundAndAccept(id);
    await escrow.connect(seller).raiseDispute(id, hash("scope-change"));
    await expect(escrow.connect(arbitrator).resolveDisputeForSeller(id))
      .to.be.revertedWithCustomError(escrow, "OwnableUnauthorizedAccount");
    await escrow.connect(buyer).resolveDisputeForSeller(id);

    expect((await escrow.getEscrow(id)).state).to.equal(5);
    expect(await escrow.claimable(await token.getAddress(), seller.address)).to.equal(units(100));
  });

  it("resolves a dispute for the buyer and issues a pull refund", async function () {
    const id = await createEscrow();
    await fundAndAccept(id);
    await escrow.connect(buyer).raiseDispute(id, hash("non-delivery"));
    await escrow.connect(buyer).resolveDisputeForBuyer(id);
    await escrow.connect(buyer).refund(id);
    expect(await token.balanceOf(buyer.address)).to.equal(units(10_000));
    expect(await escrow.getRemainingAmount(id)).to.equal(0);
  });

  it("splits arbitration proceeds and rejects shares over 100 percent", async function () {
    const id = await createEscrow();
    await fundAndAccept(id);
    await escrow.connect(seller).raiseDispute(id, hash("partial-delivery"));
    await expect(escrow.connect(buyer).resolveDisputeSplit(id, 10_001))
      .to.be.revertedWithCustomError(escrow, "InvalidShare");
    await escrow.connect(buyer).resolveDisputeSplit(id, 6_000);
    expect(await escrow.claimable(await token.getAddress(), seller.address)).to.equal(units(60));
    expect(await escrow.buyerRefundable(id)).to.equal(units(40));
    await escrow.connect(buyer).refund(id);
  });

  it("enforces the submission deadline and allows cancellation after expiry", async function () {
    const id = await createEscrow(1, { deadlineOffset: 30 });
    await fundAndAccept(id);
    await expect(escrow.connect(buyer).cancelEscrow(id))
      .to.be.revertedWithCustomError(escrow, "InvalidState");
    await ethers.provider.send("evm_increaseTime", [31]);
    await ethers.provider.send("evm_mine", []);
    await expect(escrow.connect(seller).submitMilestone(id, hash("late")))
      .to.be.revertedWithCustomError(escrow, "DeadlinePassed");
    await escrow.connect(buyer).cancelEscrow(id);
    await escrow.connect(buyer).refund(id);
    expect((await escrow.getEscrow(id)).state).to.equal(6);
  });

  it("protects pull payments from repeated or empty withdrawals and refunds", async function () {
    const id = await createEscrow();
    await fundAndAccept(id);
    await escrow.connect(seller).submitMilestone(id, hash("one-time"));
    await escrow.connect(buyer).approveMilestone(id);
    await escrow.releaseMilestone(id);
    await escrow.connect(seller).withdraw(await token.getAddress());
    await expect(escrow.connect(seller).withdraw(await token.getAddress()))
      .to.be.revertedWithCustomError(escrow, "NothingToWithdraw");
    await expect(escrow.connect(buyer).refund(id))
      .to.be.revertedWithCustomError(escrow, "InvalidState");
  });

  it("blocks a token callback from reentering funding", async function () {
    const callbackToken = await ethers.deployContract("ReentrantMockUSDC");
    const guardedEscrow = await ethers.deployContract("Escrow");
    await callbackToken.mint(buyer.address, units(100));
    await callbackToken.connect(buyer).approve(await guardedEscrow.getAddress(), units(100));

    const now = (await ethers.provider.getBlock("latest")).timestamp;
    const id = await guardedEscrow.nextEscrowId();
    await guardedEscrow.connect(buyer).createEscrow(
      seller.address,
      await callbackToken.getAddress(),
      units(100),
      units(100),
      1,
      now + 3600
    );
    await callbackToken.armCallback(
      await guardedEscrow.getAddress(),
      guardedEscrow.interface.encodeFunctionData("fundEscrow", [id])
    );

    await guardedEscrow.connect(buyer).fundEscrow(id);
    expect(await callbackToken.callbackAttempted()).to.equal(true);
    expect(await callbackToken.callbackSucceeded()).to.equal(false);
    expect((await guardedEscrow.getEscrow(id)).state).to.equal(1);
  });

  it("limits the faucet to one claim per address and restricts owner minting", async function () {
    await token.connect(other).faucet();
    await expect(token.connect(other).faucet()).to.be.revertedWithCustomError(token, "FaucetAlreadyClaimed");
    await expect(token.connect(other).mint(other.address, units(1)))
      .to.be.revertedWithCustomError(token, "OwnableUnauthorizedAccount");
  });
});