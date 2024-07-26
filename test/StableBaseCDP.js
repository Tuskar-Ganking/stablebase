const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("StableBaseCDP", function () {
  let stableBaseCDP, sbdToken, mockToken, owner, addr1, priceOracle, mockOracle;

  beforeEach(async function () {
    [owner, addr1] = await ethers.getSigners();

    // Deploy SBDToken
    const SBDToken = await ethers.getContractFactory("SBDToken");
    sbdToken = await SBDToken.deploy("SBD Token", "SBD");
    await sbdToken.waitForDeployment();

    // // Deploy mock oracle
    // const MockOracle = await ethers.getContractFactory("MockV3Aggregator");
    // mockOracle = await MockOracle.deploy(8, ethers.parseUnits("1000", 8)); // 8 decimal places, price 1000
    // await mockOracle.waitForDeployment();

    // // Deploy ChainlinkPriceOracle
    // const PriceConsumer = await ethers.getContractFactory("ChainlinkPriceOracle");
    // priceOracle = await PriceConsumer.deploy(mockOracle.address);
    // // priceOracle = await PriceConsumer.deploy(ethers.ZeroAddress);
    // await priceOracle.waitForDeployment();

    // Deploy StableBaseCDP with the price oracle address
    const StableBaseCDPFactory = await ethers.getContractFactory("StableBaseCDP");
    stableBaseCDP = await StableBaseCDPFactory.deploy(sbdToken.target);
    await stableBaseCDP.waitForDeployment();

    // Set the minter to StableBaseCDP contract
    await sbdToken.setMinter(stableBaseCDP.target);

    // Deploy a mock ERC20 token
    const MockToken = await ethers.getContractFactory("SBDToken");
    mockToken = await MockToken.deploy("Mock Token", "MKT");
    await mockToken.waitForDeployment();

    // Mint tokens to owner so that we can transfer them to addr1
    await mockToken.mint(owner.address, ethers.parseEther("1000"));

    // Transfer some tokens to addr1
    await mockToken.transfer(addr1.address, ethers.parseEther("100"));
  });

  console.log("ethers:-> ", ethers);

  // Test case for opening a new safe with ETH
  it("should open a new safe with ETH", async function () {
    const depositAmount = ethers.parseEther("1");
    const reserveRatio = 100;

    // Open a safe with ETH
    await stableBaseCDP.connect(addr1).openSafe(ethers.ZeroAddress, depositAmount, reserveRatio, { value: depositAmount });

    // Compute the safe ID
    const safeId = ethers.solidityPackedKeccak256(["address", "address"], [addr1.address, ethers.ZeroAddress]);
    const safe = await stableBaseCDP.safes(safeId);

    // Check if the safe has the correct deposited amount and reserve ratio
    expect(safe.token).to.equal(ethers.ZeroAddress);
    expect(safe.depositedAmount).to.equal(depositAmount);
    expect(safe.reserveRatio).to.equal(reserveRatio);
  });

  // Test case for opening a new safe with ERC20 token
  it("should open a new safe with ERC20 token", async function () {
    const depositAmount = ethers.parseEther("100");
    const reserveRatio = 100;

    // Approve the token transfer and open a safe with the ERC20 token
    await mockToken.connect(addr1).approve(stableBaseCDP.target, depositAmount); // approve token transfer
    await stableBaseCDP.connect(addr1).openSafe(mockToken.target, depositAmount, reserveRatio); // open safe

    // Compute the safe ID
    const safeId = ethers.solidityPackedKeccak256(["address", "address"], [addr1.address, mockToken.target]);
    const safe = await stableBaseCDP.safes(safeId);

    // Check if the safe has the correct deposited amount and reserve ratio
    expect(safe.token).to.equal(mockToken.target);
    expect(safe.depositedAmount).to.equal(depositAmount);
    expect(safe.reserveRatio).to.equal(reserveRatio);
  });

  // Test case for borrowing against the collateral in a safe
  it("should allow borrowing SBD tokens against the collateral and return the borrowed amount", async function () {
    const depositAmount = ethers.parseEther("1");
    const reserveRatio = 100;

    // Open a safe with ETH
    await stableBaseCDP.connect(addr1).openSafe(ethers.ZeroAddress, depositAmount, reserveRatio, { value: depositAmount });

    // Calculate the maximum borrowable amount based on the dummy price and liquidation ratio
    const price = BigInt(1000); // Dummy price from getPriceFromOracle
    // console.log("priceOracle:-> ", priceOracle);
    // const price = await priceOracle.getPrice();
    console.log("price:-> ",price);
    const liquidationRatio = BigInt(110); // Ensure consistency with contract
    const maxBorrowAmount = (depositAmount * price * BigInt(100)) / liquidationRatio; // BigInt calculation

    // Adjust the borrow amount to be within the limit
    const borrowAmount = maxBorrowAmount - BigInt(1); // Slightly less than max borrowable amount

    // Borrow SBD tokens
    await stableBaseCDP.connect(addr1).borrow(ethers.ZeroAddress, borrowAmount);

    // Compute the safe ID
    const safeId = ethers.solidityPackedKeccak256(["address", "address"], [addr1.address, ethers.ZeroAddress]);
    const safe = await stableBaseCDP.safes(safeId);

    // Check if the safe has the correct borrowed amount
    expect(safe.borrowedAmount).to.equal(borrowAmount);

    // Check if the SBD tokens have been minted to the borrower
    const sbdBalance = await sbdToken.balanceOf(addr1.address);
    expect(sbdBalance).to.equal(borrowAmount);
  });

//   // Test case for repaying borrowed amount
// it("should allow repaying part of the borrowed amount", async function () {
//   const depositAmount = ethers.parseEther("1");
//   const reserveRatio = 100;
//   const borrowAmount = ethers.parseEther("500"); // Large borrow amount

//   // Open a safe with ETH
//   await stableBaseCDP.connect(addr1).openSafe(ethers.ZeroAddress, depositAmount, reserveRatio, { value: depositAmount });

//   // Borrow SBD tokens
//   await stableBaseCDP.connect(addr1).borrow(ethers.ZeroAddress, borrowAmount);

//   // Compute the safe ID
//   const safeId = ethers.solidityPackedKeccak256(["address", "address"], [addr1.address, ethers.ZeroAddress]);

//   // Check initial borrowed amount
//   const safeBefore = await stableBaseCDP.safes(safeId);
//   expect(safeBefore.borrowedAmount).to.equal(borrowAmount);

//   // Repay a portion of the borrowed amount
//   const repayAmount = ethers.parseEther("100"); // Partial repayment
//   await sbdToken.connect(addr1).approve(stableBaseCDP.target, repayAmount); // Approve repayment
//   await stableBaseCDP.connect(addr1).repay(ethers.ZeroAddress, repayAmount);

//   // Check updated borrowed amount
//   const safeAfter = await stableBaseCDP.safes(safeId);
//   expect(safeAfter.borrowedAmount).to.equal(borrowAmount.sub(repayAmount));

//   // Check SBD token balance of the borrower
//   const sbdBalance = await sbdToken.balanceOf(addr1.address);
//   expect(sbdBalance).to.equal(repayAmount);
// });


it("should repay borrowed amount", async function () {
  const collateralTokenAddress = mockToken.target;
  const amount = ethers.parseUnits("100", 18);
console.log("testing..1");

  // Approve the stableBaseCDP contract to spend the mock token
  await mockToken.connect(addr1).approve(stableBaseCDP.target, amount);
  console.log("testing..2");
  // Open a safe with the mock token
  await stableBaseCDP.connect(addr1).openSafe(collateralTokenAddress, amount, 100);
  console.log("testing..3");
  // Borrow some SBD tokens
  // await stableBaseCDP.connect(addr1).borrow(collateralTokenAddress, amount);
  await stableBaseCDP.connect(addr1).borrow(collateralTokenAddress, amount);
  console.log("testing..4");
  // Repay some SBD tokens
  const repayAmount = ethers.parseUnits("50", 18);
  await sbdToken.connect(addr1).approve(stableBaseCDP.address, repayAmount);
  await stableBaseCDP.connect(addr1).repay(collateralTokenAddress, repayAmount);
  console.log("testing..4");
  // Check that the borrowed amount has been reduced
  const safeId = ethers.solidityPackedKeccak256(["address", "address"], [addr1.address, collateralTokenAddress]);
  const safe = await stableBaseCDP.safes(safeId);
  expect(safe.borrowedAmount).to.be.equal(amount - repayAmount);
});


  // Test case for closing a safe and returning the collateral
  it("should close a safe and return the collateral to the owner", async function () {
    const depositAmount = ethers.parseEther("1");
    const reserveRatio = 100;

    // Open a safe with ETH
    await stableBaseCDP.connect(addr1).openSafe(ethers.ZeroAddress, depositAmount, reserveRatio, { value: depositAmount });

    // Compute the safe ID
    const safeId = ethers.solidityPackedKeccak256(["address", "address"], [addr1.address, ethers.ZeroAddress]);
    await stableBaseCDP.connect(addr1).closeSafe(ethers.ZeroAddress); // Close the safe

    // Check if the safe has been closed (deposited amount should be 0)
    const safe = await stableBaseCDP.safes(safeId);
    expect(safe.depositedAmount).to.equal(0);
    expect(safe.borrowedAmount).to.equal(0);
  });

});
