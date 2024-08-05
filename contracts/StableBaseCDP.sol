// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

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

    address public orderedReserveRatios;

    address public orderedTargetShieldedRates;

    address public shieldedSafes;

    Math.Rate public referenceShieldingRate;

    constructor(address _sbdToken) {
        whitelistedTokens[address(0)] = SBStructs.WhitelistedToken({
            priceOracle: address(new MockPriceOracle()),
            collateralRatio: 110
        });
        sbdToken = SBDToken(_sbdToken);
        orderedReserveRatios = address(new OrderedDoublyLinkedList());
        orderedTargetShieldedRates = address(new OrderedDoublyLinkedList());
        shieldedSafes = address(new OrderedDoublyLinkedList());
    }

    /**
     * @dev Opens a new Safe for the borrower and tracks the collateral deposited, etc.
     * Send any amount of ERC20 tokens or ETH
     *
     * @param _token Address of the ERC20 token, use address(0) for ETH
     * @param _amount Amount of tokens or ETH to deposit as collateral
     * 
     */
    // function openSafe(address _token, uint256 _amount, uint256 _reserveRatio, uint256 _positionInReserve) external payable {
    // function openSafe(address _token, uint256 _amount, uint256 _reserveRatio, uint256 /*_positionInReserve*/) external payable {
    function openSafe(address _token, uint256 _amount) external payable {
        require(_amount > 0, "Amount must be greater than 0");
        bytes32 id = SBUtils.getSafeId(msg.sender, _token);

        // Create a new Safe
        SBStructs.Safe memory safe = SBStructs.Safe({
            token: _token,
            depositedAmount: _amount,
            borrowedAmount: 0,
            rates: 0,
            shieldedUntil: 0
        });

        // Deposit ETH or ERC20 token using SBUtils library
        if (_token == address(0)) {
            safe.depositedAmount = msg.value; // Assign ETH amount to depositedAmount
        } else {
            safe.depositedAmount = _amount; // Assign ERC20 amount to depositedAmount
        }
        SBUtils.depositEthOrToken(_token, address(this), _amount);

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
        require(
            safe.borrowedAmount == 0,
            "Cannot close Safe with borrowed amount"
        );

        // Withdraw ETH or ERC20 token using SBUtils library (Transfer collateral back to the owner)
        SBUtils.withdrawEthOrToken(
            safe.token,
            msg.sender,
            safe.depositedAmount
        );

        // Remove the Safe from the mapping
        delete safes[id];
    }

    /**
     * Borrow stablecoins from the protocol
     * 
     * _borrowParams:
     * minimum: 36 bytes, maximum 68 bytes
     * bytes 0-3:
     *     bit: 0 - shieldingRate, 1 - reserveRatio
     *     bits 1-15: rate (either shieldingRate or reserveRatio)
     *     bit 16: 1 if target shielding rate is set, 0 otherwise
     *     bits 17-31: target shielding rate
     * bytes 4-35: Nearest Spot in either shieldedSafes or orderedReserveRatiosList list
     * bytes 36-67: If exists, is always the nearest spot in the orderedTargetShieldedRatesList
     * 
     */
    function borrowWithParams(address _token, uint256 _amount, bytes calldata _borrowParams) external {
        bytes32 id = SBUtils.getSafeId(msg.sender, _token);
        SBStructs.Safe storage safe = safes[id];
        require(safe.depositedAmount > 0, "Safe does not exist");
        //bytes2 _rateByte = bytes2(_borrowParams[0: 2]);
        //uint256 _rate = uint256(uint16(_rateByte) & 0x7FFF);
        //SBStructs.StabilityType _rateType = (uint16(_rateByte) & 0x8000) >= 1 ? SBStructs.StabilityType.RESERVE_RATIO : SBStructs.StabilityType.SHIELDING_RATE;
        //uint256 _nearestSpot = abi.decode(_borrowParams[4:32], (uint256));

        IPriceOracle priceOracle = IPriceOracle(whitelistedTokens[_token].priceOracle);

        // Fetch the price of the collateral from the oracle
        //uint256 price = priceOracle.getPrice();

        // Calculate the maximum borrowable amount
        uint256 maxBorrowAmount = (safe.depositedAmount * priceOracle.getPrice() * 100) / liquidationRatio;

        // Check if the requested amount is within the maximum borrowable limits
        require(safe.borrowedAmount + _amount <= maxBorrowAmount, "Borrow amount exceeds the maximum allowed");

        // Calculate reserve or shielding rate
        (uint256 shieldingRate, uint256 shieldingEnabled) = Math.getRate(0, SBStructs.StabilityType.SHIELDING_RATE);
        (uint256 reserveRatio, uint256 reserveRatioEnabled) = Math.getRate(0, SBStructs.StabilityType.RESERVE_RATIO);

        uint256 _amountToBorrow = _amount;
        if (reserveRatioEnabled == 1) {
            // Calculate origination fee
            uint256 _reservePoolDeposit = (_amount * reserveRatio) / BASIS_POINTS_DIVISOR;
            _amountToBorrow = _amount - _reservePoolDeposit;
        } else {
            uint256 _shieldingFee = (_amount * shieldingRate) / BASIS_POINTS_DIVISOR;
            _amountToBorrow = _amount - _shieldingFee;
            // Update the Safe's shieldedUntil timestamp
            uint256 _shieldingHours = Math.getShieldingHours(referenceShieldingRate, shieldingRate);
            safe.shieldedUntil = block.timestamp + Math.toSeconds(_shieldingHours);
        }

        // Update the Safe's borrowed amount and origination fee paid
        safe.borrowedAmount += _amount;

        // Mint SBD tokens to the borrower
        sbdToken.mint(msg.sender, _amountToBorrow);
        // TODO: Mint origination fee to the fee holder
        //sbdToken.mint(feeHolder, originationFee);
    }

    // borrow function
    function borrow(address _token, uint256 _amount) external {
        bytes32 id = SBUtils.getSafeId(msg.sender, _token);
        SBStructs.Safe storage safe = safes[id];
        require(safe.depositedAmount > 0, "Safe does not exist");

        IPriceOracle priceOracle = IPriceOracle(
            whitelistedTokens[_token].priceOracle
        );

        // Fetch the price of the collateral from the oracle
        uint256 price = priceOracle.getPrice();

        // Calculate the maximum borrowable amount
        uint256 maxBorrowAmount = (safe.depositedAmount * price * 100) /
            liquidationRatio;

        // Check if the requested amount is within the maximum borrowable limit
        require(
            safe.borrowedAmount + _amount <= maxBorrowAmount,
            "Borrow amount exceeds the maximum allowed"
        );

        // Calculate origination fee
        uint256 originationFee = (_amount * originationFeeRateBasisPoints) /
            BASIS_POINTS_DIVISOR;

        // Update the Safe's borrowed amount and origination fee paid
        safe.borrowedAmount += _amount;
        //safe.originationFeePaid += originationFee;

        // Mint SBD tokens to the borrower
        sbdToken.mint(msg.sender, _amount - originationFee);
        // TODO: Mint origination fee to the fee holder
        //sbdToken.mint(feeHolder, originationFee);
    }

    // Repay function
    function repay(address _token, uint256 _amount) external {
        bytes32 id = SBUtils.getSafeId(msg.sender, _token);
        SBStructs.Safe storage safe = safes[id];
        require(safe.borrowedAmount > 0, "No borrowed amount to repay");

        // Check if the repayment amount is valid
        require(
            _amount <= safe.borrowedAmount,
            "Repayment amount exceeds borrowed amount"
        );

        // Calculate the origination fee (assuming it's a percentage of the borrowed amount)
        uint256 originationFee = (safe.borrowedAmount *
            originationFeeRateBasisPoints) / BASIS_POINTS_DIVISOR;

        // Burn SBD tokens from the user to repay the borrowed amount
        sbdToken.burnFrom(msg.sender, _amount + originationFee);

        // Update the Safe's borrowed amount and origination fee paid
        safe.borrowedAmount -= _amount;
        // safe.originationFeePaid += originationFee;

        // Check if the borrowed amount is fully repaid
        if (safe.borrowedAmount == 0) {
            // Reset the borrowed amount and origination fee paid
            safe.borrowedAmount = 0;
            // safe.originationFeePaid = 0;
        }
    }

    // Withdraw collateral function
    function withdrawCollateral(address _token, uint256 _amount) external {
        bytes32 id = SBUtils.getSafeId(msg.sender, _token);
        SBStructs.Safe storage safe = safes[id];
        require(safe.depositedAmount > 0, "No collateral to withdraw");

        if (safe.borrowedAmount > 0) {
            // Calculate the price of the collateral
            IPriceOracle priceOracle = IPriceOracle(
                whitelistedTokens[_token].priceOracle
            );
            uint256 price = priceOracle.getPrice();

            // Calculate the maximum withdrawal amount that maintains the liquidation ratio
            uint256 maxWithdrawal = safe.depositedAmount -
                (safe.borrowedAmount * liquidationRatio) /
                (price * 100);
            require(_amount <= maxWithdrawal, "Insufficient collateral");

            // Check if the remaining collateral is sufficient to cover the borrowed amount after withdrawal
            require(
                ((safe.depositedAmount - _amount) * price * 100) /
                    safe.borrowedAmount >=
                    liquidationRatio,
                "Insufficient collateral after withdrawal"
            );
        } else {
            // If there's no borrowed amount, ensure the withdrawal does not exceed deposited collateral
            require(_amount <= safe.depositedAmount, "Insufficient collateral");
        }

        // Withdraw ETH or ERC20 token using SBUtils library
        SBUtils.withdrawEthOrToken(safe.token, msg.sender, _amount);

        // Update the Safe's deposited amount
        safe.depositedAmount -= _amount;
    }

    /**
     * @dev Redeem collateral for the specified amount of stablecoins.
     * @param amount Amount of stablecoins to redeem for collateral.
     */
    function redeem(uint256 amount) external {
        bytes32 id = SBUtils.getSafeId(msg.sender, address(0)); // assume ETH collateral for now
        SBStructs.Safe storage safe = safes[id];

        // Ensure there is enough collateral deposited
        require(safe.depositedAmount > 0, "No collateral to redeem");

        // Check for outstanding debt
        require(
            safe.borrowedAmount == 0 || safe.borrowedAmount >= amount,
            "Cannot redeem collateral with outstanding debt"
        );

        // Calculate the amount of collateral to redeem
        uint256 collateralAmount;
        if (safe.borrowedAmount > 0) {
            // Redeeming against debt, use price oracle for calculation
            IPriceOracle priceOracle = IPriceOracle(
                whitelistedTokens[address(0)].priceOracle
            );
            uint256 price = priceOracle.getPrice();
            collateralAmount = (amount * liquidationRatio) / (price * 100);
        } else {
            // Redeeming deposited collateral without outstanding debt
            collateralAmount =
                (amount * liquidationRatio) /
                BASIS_POINTS_DIVISOR;
        }

        // Ensure the user has sufficient collateral to redeem
        require(
            safe.depositedAmount >= collateralAmount,
            "Insufficient collateral to redeem"
        );

        // Burn or mint SBD tokens accordingly
        if (safe.borrowedAmount > 0) {
            // Burn the stablecoins from the sender
            sbdToken.burnFrom(msg.sender, amount);
            // Update the Safe's borrowed amount
            safe.borrowedAmount -= amount;
        } else {
            // Mint new SBD tokens to the user
            sbdToken.mint(msg.sender, amount);
        }

        // Transfer the collateral to the sender
        SBUtils.withdrawEthOrToken(safe.token, msg.sender, collateralAmount);

        // Update the Safe's deposited amount
        safe.depositedAmount -= collateralAmount;
    }
}
