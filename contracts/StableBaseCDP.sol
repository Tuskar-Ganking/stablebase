// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "./Structures.sol";
import "./Utilities.sol";
import "./SBDToken.sol";
import "./dependencies/price-oracle/MockPriceOracle.sol";
import "./interfaces/IPriceOracle.sol";
import "./library/OrderedDoublyLinkedList.sol";

contract StableBaseCDP {
    uint256 private originationFeeRateBasisPoints = 0; // start with 0% origination fee
    uint256 private liquidationRatio = 110; // 110% liquidation ratio
    uint256 private constant BASIS_POINTS_DIVISOR = 10000;

    // Mapping to track Safe balances
    mapping(bytes32 => SBStructs.Safe) public safes;

    SBStructs.Mode public mode = SBStructs.Mode.BOOTSTRAP;

    mapping(address => SBStructs.WhitelistedToken) public whitelistedTokens;

    SBDToken public sbdToken;

    address public orderedReserveList;

    address public orderedOriginationFeeList;

    constructor(address _sbdToken) {
        whitelistedTokens[address(0)] = SBStructs.WhitelistedToken({
            priceOracle: address(new MockPriceOracle()),
            collateralRatio: 110
        });
        sbdToken = SBDToken(_sbdToken);
        orderedReserveList = address(new OrderedDoublyLinkedList());
        orderedOriginationFeeList = address(new OrderedDoublyLinkedList());
    }

    /**
     * @dev Opens a new Safe for the borrower and tracks the collateral deposited, etc.
     * Send any amount of ERC20 tokens or ETH
     *
     * @param _token Address of the ERC20 token, use address(0) for ETH
     * @param _amount Amount of tokens or ETH to deposit as collateral
     * @param _reserveRatio Reserve ratio specified by the user
     */
    // function openSafe(address _token, uint256 _amount, uint256 _reserveRatio, uint256 _positionInReserve) external payable {
    // function openSafe(address _token, uint256 _amount, uint256 _reserveRatio, uint256 /*_positionInReserve*/) external payable {
    function openSafe(address _token, uint256 _amount, uint256 _reserveRatio) external payable {
        require(_amount > 0, "Amount must be greater than 0");
        bytes32 id = SBUtils.getSafeId(msg.sender, _token);

        // Create a new Safe
        SBStructs.Safe memory safe = SBStructs.Safe({
            token: _token,
            depositedAmount: _amount,
            borrowedAmount: 0,
            reserveRatio: _reserveRatio,
            originationFeePaid: 0
        });

        // Deposit ETH or ERC20 token using SBUtils library
        if (_token == address(0)) {
            require(msg.value == _amount, "Invalid deposit amount");
            safe.depositedAmount = msg.value; // Assign ETH amount to depositedAmount
        } else {
            SBUtils.depositEthOrToken(_token, address(this), _amount);
            safe.depositedAmount = _amount; // Assign ERC20 amount to depositedAmount
        }

        // Add the Safe to the mapping
        safes[id] = safe;
    }

    /**
     * @dev Closes a Safe and returns the collateral to the owner.
     * Check if the borrowedAmount is 0, if there is any SB token borrowed, close should not work.
     * Return back the collateral
     * @param collateralToken ID of the Safe to close, derived from keccak256(msg.sender, _token)
     */
    function closeSafe(address collateralToken) external {
        bytes32 id = SBUtils.getSafeId(msg.sender, collateralToken);
        SBStructs.Safe storage safe = safes[id];
        require(safe.borrowedAmount == 0, "Cannot close Safe with borrowed amount");

        // Withdraw ETH or ERC20 token using SBUtils library (Transfer collateral back to the owner)
        SBUtils.withdrawEthOrToken(safe.token, msg.sender, safe.depositedAmount);

        // Remove the Safe from the mapping
        delete safes[id];
    }

    function borrow(address _token, uint256 _amount) external {
        bytes32 id = SBUtils.getSafeId(msg.sender, _token);
        SBStructs.Safe storage safe = safes[id];
        require(safe.depositedAmount > 0, "Safe does not exist");

        IPriceOracle priceOracle = IPriceOracle(whitelistedTokens[_token].priceOracle);

        // Fetch the price of the collateral from the oracle
        uint256 price = priceOracle.getPrice();

        // Calculate the maximum borrowable amount
        uint256 maxBorrowAmount = (safe.depositedAmount * price * 100) / liquidationRatio;

        // Check if the requested amount is within the maximum borrowable limit
        require(safe.borrowedAmount + _amount <= maxBorrowAmount, "Borrow amount exceeds the maximum allowed");

        // Calculate origination fee
        uint256 originationFee = (_amount * originationFeeRateBasisPoints) / BASIS_POINTS_DIVISOR;

        // Update the Safe's borrowed amount and origination fee paid
        safe.borrowedAmount += _amount;
        safe.originationFeePaid += originationFee;

        // Mint SBD tokens to the borrower
        sbdToken.mint(msg.sender, _amount - originationFee);
        // TODO: Mint origination fee to the fee holder
        //sbdToken.mint(feeHolder, originationFee);
    }

    /**
     * @dev Repays the borrowed amount and reduces the Safe's borrowed amount.
     * @param collateralToken ID of the Safe to repay, derived from keccak256(msg.sender, _token)
     * @param amount Amount of SBD tokens to repay
     */
    function repay(address collateralToken, uint256 amount) external {
        bytes32 id = SBUtils.getSafeId(msg.sender, collateralToken);
        SBStructs.Safe storage safe = safes[id];

        // Check if the Safe exists and has borrowed amount
        require(safe.depositedAmount > 0, "Safe does not exist");
        require(safe.borrowedAmount > 0, "No borrowed amount to repay");

        // Calculate the maximum amount that can be repaid
        uint256 repayAmount = amount > safe.borrowedAmount ? safe.borrowedAmount : amount;

        // Transfer SBD tokens from the user to the contract
        require(sbdToken.transferFrom(msg.sender, address(this), amount), "Token transfer failed");

        // Update the Safe's borrowed amount and mint the repaid amount back to the user
        safe.borrowedAmount -= repayAmount;
        // sbdToken.mint(msg.sender, repayAmount);

        // Check if the Safe's borrowed amount has been fully repaid
        if (safe.borrowedAmount == 0) {
            // Refund any remaining origination fee if applicable
            uint256 remainingFee = safe.originationFeePaid;
            if (remainingFee > 0) {
                sbdToken.mint(msg.sender, remainingFee);
            }
        }
    }
}
