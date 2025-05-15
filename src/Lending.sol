//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title Lending
 * @author 0xSamurai
 * @notice A lending protocol allowing users to deposit specific collateral to borrow specific tokens
 * @notice The protocol assumes there will always be liquidators
 * @dev Implements token-specific collateralization where loans are backed by specific collateral tokens
 * @dev Uses ReentrancyGuard to prevent reentrancy attacks during token transfers
 * @dev Uses Ownable to manage protocol administration
 */
contract Lending is ReentrancyGuard, Ownable {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    error Lending__TokenAddressesArrayAndPriceFeedAddressesArrayMustBeSameLength();
    error Lending__TokenAddressZero();
    error Lending__PriceFeedAddressZero();
    error Lending__NeedsMoreThanZero();
    error Lending__UnsupportedToken(address tokenAddress);
    error Lending__DepositFailed();
    error Lending__InsufficientTokenBalance(uint256 userBalance);
    error Lending__NotUpToMinimumCollateralRequiredForLoan(uint256 minimumRequiredCollateralAmount);
    error Lending__BreaksProtocolHealthFactor(uint256 userHealthFactor);
    error Lending__TransferFailed();
    error Lending__LiquidationFailed();
    error Lending__NotEnoughTokenInVaultToBorrow();
    error Lending__BorrowngTokenFailed();
    error Lending__LoanRepaymentFailed();
    error Lending__InsufficientTokenBalanceToRepayLoan(uint256 userBalance, uint256 totalDue);
    error Lending__AccountHealthFactorGreaterThanOrEqualToMinimumRequired(uint256 userHealthFactor);
    error Lending__InsufficientCollateral(uint256 available, uint256 required);
    error Lending__NoLoanFound();
    error Lending__InsufficientCollateralForLoan(uint256 freeCollateral);
    error Lending__SameTokenNotAllowed();

    /*//////////////////////////////////////////////////////////////
                                STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 80; // At 80% Loan to Value Ratio, the loan can be liquidated
    uint256 public constant MIN_HEALTH_FACTOR = 1e18; // 1.0 with 18 decimal precision
    uint256 public constant INTEREST_RATE = 3;
    uint256 public constant INTEREST_PRECISION = 100;
    uint256 public constant LIQUIDATION_REWARD = 10;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant SECONDS_PER_YEAR = 31536000; // 365 days in seconds

    address[] private s_allowedTokens;
    mapping(address token => address priceFeed) private s_tokenToPriceFeed;

    // Track collateral deposits: user => token => amount
    mapping(address user => mapping(address token => uint256 amount)) private s_accountToTokensDeposited;

    // Track loans: user => borrow token => collateral token => loan details
    mapping(address user => mapping(address borrowToken => mapping(address collateralToken => Loan))) private s_loans;

    // ============ Structs ============
    struct Loan {
        uint256 amount; // Amount borrowed
        uint256 interest; // Accrued interest
        uint256 startTime; // When the loan started
        LoanStatus status; // Status of the loan
        uint256 collateralAmount; // Amount of collateral locked for this specific loan
    }

    struct LiquidationDetails {
        uint256 totalDebt; // Total debt including interest
        uint256 totalCollateral; // Total collateral locked in loan
        uint256 totalReward; // total loan value + 10% bonus
    }

    enum LoanStatus {
        INACTIVE,
        ACTIVE,
        REPAID,
        LIQUIDATED
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed account, address indexed tokenAddress, uint256 amount);
    event CollateralFreed(address indexed account, address indexed tokenAddress, uint256 amount);
    event CollateralRedeemed(address indexed account, address indexed tokenAddress, uint256 amount);
    event LoanCreated(
        address indexed account,
        address indexed borrowToken,
        address indexed collateralToken,
        uint256 borrowAmount,
        uint256 collateralAmount
    );
    event LoanRepaid(
        address indexed account, address indexed borrowToken, address indexed collateralToken, uint256 amount
    );
    event LoanLiquidated(
        address indexed account,
        address indexed borrowToken,
        address indexed collateralToken,
        uint256 borrowAmount,
        uint256 collateralAmount,
        address liquidator
    );

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Modifier to check if amount is greater than zero
     * @param amount The amount to check
     */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert Lending__NeedsMoreThanZero();
        }
        _;
    }

    /**
     * @notice Modifier to check if token is supported by the protocol
     * @param tokenAddress The token address to check
     */
    modifier isAllowedToken(address tokenAddress) {
        if (s_tokenToPriceFeed[tokenAddress] == address(0)) {
            revert Lending__UnsupportedToken(tokenAddress);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Constructor initializes the contract with allowed tokens and their price feeds
     * @param tokenAddresses Array of allowed token addresses
     * @param priceFeedAddresses Array of corresponding price feed addresses
     * @dev Both arrays must be the same length and match indexes (token[i] corresponds to priceFeed[i])
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses) Ownable(msg.sender) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert Lending__TokenAddressesArrayAndPriceFeedAddressesArrayMustBeSameLength();
        }
        // These feeds will be the USD pairs
        // For example WETH / USD or DAI / USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            if (tokenAddresses[i] == address(0)) {
                revert Lending__TokenAddressZero();
            }
            if (priceFeedAddresses[i] == address(0)) {
                revert Lending__PriceFeedAddressZero();
            }
            s_tokenToPriceFeed[tokenAddresses[i]] = priceFeedAddresses[i];
            s_allowedTokens.push(tokenAddresses[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allows users to deposit collateral to the protocol
     * @param tokenAddress The ERC20 token address of the collateral to deposit
     * @param amount The amount of the token to deposit
     * @dev Uses nonReentrant to prevent reentrancy during token transfer
     * @dev Emits CollateralDeposited event upon successful deposit
     */
    function depositCollateral(address tokenAddress, uint256 amount)
        external
        nonReentrant
        isAllowedToken(tokenAddress)
        moreThanZero(amount)
    {
        s_accountToTokensDeposited[msg.sender][tokenAddress] += amount;
        emit CollateralDeposited(msg.sender, tokenAddress, amount);
        bool success = IERC20(tokenAddress).transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert Lending__DepositFailed();
        }
    }

    /**
     * @notice Allows users to withdraw their free collateral (not backing any loans)
     * @param tokenAddress The ERC20 token address of the collateral to withdraw
     * @param amount The amount of the token to withdraw
     * @dev Verifies that withdrawal doesn't affect any existing loans
     * @dev Uses nonReentrant to prevent reentrancy during token transfer
     */
    function withdrawCollateral(address tokenAddress, uint256 amount)
        external
        nonReentrant
        isAllowedToken(tokenAddress)
        moreThanZero(amount)
    {
        // Calculate free collateral
        uint256 freeCollateral = s_accountToTokensDeposited[msg.sender][tokenAddress];

        if (freeCollateral < amount) {
            revert Lending__InsufficientTokenBalance(freeCollateral);
        }

        s_accountToTokensDeposited[msg.sender][tokenAddress] -= amount;

        emit CollateralRedeemed(msg.sender, tokenAddress, amount);

        bool success = IERC20(tokenAddress).transfer(msg.sender, amount);
        if (!success) revert Lending__TransferFailed();
    }

    /**
     * @notice Allows users to borrow tokens using specific collateral
     * @param borrowToken The ERC20 token address to borrow
     * @param collateralToken The ERC20 token address to use as collateral
     * @param borrowAmount The amount of tokens to borrow
     * @param collateralAmount The amount of collateral to lock for the loan. it must be >= the minimum required collateral
     * @dev Ensures sufficient collateral value and protocol liquidity
     * @dev Uses nonReentrant to prevent reentrancy during token transfer
     * @dev Emits LoanCreated event upon successful borrow
     * @dev @param borrowToken and @param collateralToken must be different
     */
    function borrow(address borrowToken, address collateralToken, uint256 borrowAmount, uint256 collateralAmount)
        external
        nonReentrant
        isAllowedToken(borrowToken)
        isAllowedToken(collateralToken)
        moreThanZero(borrowAmount)
        moreThanZero(collateralAmount)
    {
        // check for same token
        if (borrowToken == collateralToken) {
            revert Lending__SameTokenNotAllowed();
        }

        // Check if protocol has enough tokens to lend
        uint256 protocolTokenBalance = IERC20(borrowToken).balanceOf(address(this));
        if (protocolTokenBalance < borrowAmount) {
            revert Lending__NotEnoughTokenInVaultToBorrow();
        }

        // Calculate minimum required collateral for this loan
        // loan of 1 eth ($2000) --> Requires ($2000 * 100) / 80 = $2500 of collateral (DAI) --> overcollateralized by 25%
        uint256 borrowValueInUsd = _getUSDValue(borrowToken, borrowAmount);
        uint256 minimumRequiredCollateralValueInUsd = (borrowValueInUsd * LIQUIDATION_PRECISION) / LIQUIDATION_THRESHOLD;
        uint256 minimumRequiredCollateralAmount =
            _getTokenAmountFromUsd(collateralToken, minimumRequiredCollateralValueInUsd);

        // Check if user's provided collateral meets minimum requirement
        if (collateralAmount < minimumRequiredCollateralAmount) {
            revert Lending__NotUpToMinimumCollateralRequiredForLoan(minimumRequiredCollateralAmount);
        }

        // Check if user has enough free collateral
        uint256 freeCollateral = s_accountToTokensDeposited[msg.sender][collateralToken];

        if (freeCollateral < collateralAmount) {
            revert Lending__InsufficientCollateralForLoan(freeCollateral);
        }

        // Create loan and lock collateral - we store the collateral amount provided by the user in the loan struct, so we can return it to the user upon repayment
        s_loans[msg.sender][borrowToken][collateralToken] = Loan({
            amount: borrowAmount,
            interest: 0,
            startTime: block.timestamp,
            status: LoanStatus.ACTIVE,
            collateralAmount: collateralAmount
        });

        // Update the user's available collateral balance
        s_accountToTokensDeposited[msg.sender][collateralToken] -= collateralAmount;

        // Check if the user's health factor is still above 1 after borrowing
        uint256 userHealthFactor = _calculateLoanHealthFactor(msg.sender, borrowToken, collateralToken);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert Lending__BreaksProtocolHealthFactor(userHealthFactor);
        }

        // Transfer borrowed tokens to user
        emit LoanCreated(msg.sender, borrowToken, collateralToken, borrowAmount, collateralAmount);
        bool success = IERC20(borrowToken).transfer(msg.sender, borrowAmount);
        if (!success) revert Lending__BorrowngTokenFailed();
    }

    /**
     * @notice Allows users to repay their specific loan
     * @param borrowToken The token address that was borrowed
     * @param collateralToken The token address used as collateral
     * @param amount The amount to repay (must be the full loan amount plus interest)
     * @dev Protocol only supports full loan repayment, no partial repayments
     * @dev Uses nonReentrant to prevent reentrancy during token transfer
     * @dev Emits LoanRepaid event upon successful repayment
     */
    function repay(address borrowToken, address collateralToken, uint256 amount)
        external
        nonReentrant
        isAllowedToken(borrowToken)
        isAllowedToken(collateralToken)
        moreThanZero(amount)
    {
        Loan storage loan = s_loans[msg.sender][borrowToken][collateralToken];

        if (loan.status != LoanStatus.ACTIVE || loan.amount == 0) {
            revert Lending__NoLoanFound();
        }

        uint256 interest = _loanInterest(loan);
        uint256 totalDue = loan.amount + interest;

        // Protocol only supports full loan repayment
        if (amount < totalDue) {
            revert Lending__InsufficientTokenBalanceToRepayLoan(amount, totalDue);
        }

        // Check if user has enough tokens to repay
        uint256 userBalance = IERC20(borrowToken).balanceOf(msg.sender);
        if (userBalance < totalDue) {
            revert Lending__InsufficientTokenBalanceToRepayLoan(userBalance, totalDue);
        }

        uint256 collateralToReturn = loan.collateralAmount;

        // Update loan status to repaid
        loan.status = LoanStatus.REPAID;
        loan.amount = 0;
        loan.interest = 0;
        loan.collateralAmount = 0;

        // unlock/return the collateral back to the user --> user redeem back his collateral
        s_accountToTokensDeposited[msg.sender][collateralToken] += collateralToReturn;

        emit LoanRepaid(msg.sender, borrowToken, collateralToken, totalDue);

        // User repays loan to protocol
        bool repayLoanSuccess = IERC20(borrowToken).transferFrom(msg.sender, address(this), totalDue);
        if (!repayLoanSuccess) revert Lending__LoanRepaymentFailed();
    }

    /**
     * @notice Allows liquidators to liquidate unhealthy positions
     * @param account The account to liquidate
     * @param borrowToken The token that was borrowed
     * @param collateralToken The token used as collateral
     * @dev Requires the loan's health factor to be below 1
     * @dev Uses nonReentrant to prevent reentrancy during token transfers
     * @dev Emits LoanLiquidated event upon successful liquidation
     */
    function liquidate(address account, address borrowToken, address collateralToken)
        external
        nonReentrant
        isAllowedToken(borrowToken)
        isAllowedToken(collateralToken)
    {
        Loan storage loan = s_loans[account][borrowToken][collateralToken];

        _validateLiquidation(account, borrowToken, collateralToken, loan);
        LiquidationDetails memory details = _calculateTotalLiquidation(loan, borrowToken, collateralToken);
        _executeLiquidation(account, borrowToken, collateralToken, loan, details);
    }

    /**
     * @notice Allows users to add more collateral to an existing loan so they can prevent liquidation
     * @param borrowToken The token that was borrowed
     * @param collateralToken The token used as collateral
     * @param additionalCollateral The amount of additional collateral to add
     * @dev Emits CollateralDeposited event upon successful deposit
     */
    function addCollateralToLoan(address borrowToken, address collateralToken, uint256 additionalCollateral)
        external
        nonReentrant
        isAllowedToken(collateralToken)
        moreThanZero(additionalCollateral)
    {
        Loan storage loan = s_loans[msg.sender][borrowToken][collateralToken];

        if (loan.status != LoanStatus.ACTIVE || loan.amount == 0) {
            revert Lending__NoLoanFound();
        }

        uint256 userBalance = s_accountToTokensDeposited[msg.sender][collateralToken];

        if (userBalance < additionalCollateral) {
            revert Lending__InsufficientTokenBalance(userBalance);
        }

        // Update users loan and collateral records
        loan.collateralAmount += additionalCollateral;
        s_accountToTokensDeposited[msg.sender][collateralToken] -= additionalCollateral;

        emit CollateralDeposited(msg.sender, collateralToken, additionalCollateral);
    }

    /**
     * @notice Allows users to add free excess collateral from an existing loan
     * @param borrowToken The token that was borrowed
     * @param collateralToken The token used as collateral
     * @param amount The amount of collateral to free
     * @dev Emits CollateralDeposited event upon successful deposit
     */
    function freeCollateralFromLoan(address borrowToken, address collateralToken, uint256 amount)
        external
        nonReentrant
        isAllowedToken(collateralToken)
        moreThanZero(amount)
    {
        Loan storage loan = s_loans[msg.sender][borrowToken][collateralToken];

        if (loan.status != LoanStatus.ACTIVE || loan.amount == 0) {
            revert Lending__NoLoanFound();
        }

        if (loan.collateralAmount < amount) {
            revert Lending__InsufficientCollateral(loan.collateralAmount, amount);
        }

        uint256 remainingCollateral = loan.collateralAmount - amount;

        // Calculate minimum required collateral for this loan
        uint256 loanValueInUsd = _getUSDValue(borrowToken, loan.amount);
        uint256 minimumRequiredCollateralValueInUsd = (loanValueInUsd * LIQUIDATION_PRECISION) / LIQUIDATION_THRESHOLD;
        uint256 minimumRequiredCollateralAmount =
            _getTokenAmountFromUsd(collateralToken, minimumRequiredCollateralValueInUsd);

        // Check if user's remaining collateral meets minimum requirement
        if (remainingCollateral < minimumRequiredCollateralAmount) {
            revert Lending__NotUpToMinimumCollateralRequiredForLoan(minimumRequiredCollateralAmount);
        }

        loan.collateralAmount -= amount;
        s_accountToTokensDeposited[msg.sender][collateralToken] += amount;

        emit CollateralFreed(msg.sender, collateralToken, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Validates if a loan can be liquidated
     */
    function _validateLiquidation(address account, address borrowToken, address collateralToken, Loan storage loan)
        private
        view
    {
        if (loan.status != LoanStatus.ACTIVE || loan.amount == 0) {
            revert Lending__NoLoanFound();
        }

        uint256 loanHealthFactor = _calculateLoanHealthFactor(account, borrowToken, collateralToken);
        if (loanHealthFactor >= MIN_HEALTH_FACTOR) {
            revert Lending__AccountHealthFactorGreaterThanOrEqualToMinimumRequired(loanHealthFactor);
        }
    }

    /**
     * @dev Calculates the total amounts involved in liquidation
     */
    function _calculateTotalLiquidation(
        Loan storage loan,
        address borrowToken,
        address collateralToken
    ) private view returns (LiquidationDetails memory details) {
        // Calculate total debt including interest
        uint256 interest = _loanInterest(loan);
        details.totalDebt = loan.amount + interest;
        details.totalCollateral = loan.collateralAmount;

        // Convert debt amount to collateral token equivalent
        uint256 debtInCollateral = _getTokenAmountFromUsd(
            collateralToken,
            _getUSDValue(borrowToken, details.totalDebt)
        );

        // Calculate bonus (10% of the debt in collateral terms)
        uint256 bonusAmount = (debtInCollateral * LIQUIDATION_REWARD) / LIQUIDATION_PRECISION;

        // Liquidator gets collateral worth their debt repayment plus bonus
        details.totalReward = debtInCollateral + bonusAmount;

        return details;
    }

    /**
     * @dev Executes the liquidation by handling transfers and state updates
     */
    function _executeLiquidation(
        address account,
        address borrowToken,
        address collateralToken,
        Loan storage loan,
        LiquidationDetails memory details
    ) private {
        // Verify loan has sufficient collateral -> this is the amount locked in the loan
        if (loan.collateralAmount < details.totalCollateral) {
            revert Lending__InsufficientCollateral(loan.collateralAmount, details.totalCollateral);
        }

        //ensure liquidator has enough tokens to repay the loan
        uint256 liquidatorBalance = IERC20(borrowToken).balanceOf(msg.sender);
        if (liquidatorBalance < details.totalDebt) {
            revert Lending__InsufficientTokenBalanceToRepayLoan(liquidatorBalance, details.totalDebt);
        }

        // Update loan status to liquidated
        loan.status = LoanStatus.LIQUIDATED;
        loan.amount = 0;
        loan.collateralAmount = 0;
        loan.interest = 0;

        emit LoanLiquidated(
            account, borrowToken, collateralToken, details.totalDebt, details.totalReward, msg.sender
        );

        // Transfer the borrowed tokens from liquidator to protocol
        bool repaySuccess = IERC20(borrowToken).transferFrom(msg.sender, address(this), details.totalDebt);
        if (!repaySuccess) revert Lending__LiquidationFailed();

        // Transfer the collateral to the liquidator (including bonus)
        bool success = IERC20(collateralToken).transfer(msg.sender, details.totalReward);
        if (!success) revert Lending__LiquidationFailed();
    }

    /**
     * @notice Gets the total amount of a specific collateral token locked in loans
     * @param user The user address to check
     * @param collateralToken The collateral token to check
     * @return Total amount of collateral locked in active loans
     */
    function _getLockedCollateral(address user, address collateralToken) private view returns (uint256) {
        uint256 lockedCollateral = 0;

        // Loop through all possible borrow tokens
        for (uint256 i = 0; i < s_allowedTokens.length; i++) {
            address borrowToken = s_allowedTokens[i];
            Loan storage loan = s_loans[user][borrowToken][collateralToken];

            // If loan is active, add its collateral to the total
            if (loan.status == LoanStatus.ACTIVE) {
                lockedCollateral += loan.collateralAmount;
            }
        }

        return lockedCollateral;
    }

    /**
     * @notice Calculates the health factor for a specific loan
     * @param user The user address
     * @param borrowToken The borrowed token
     * @param collateralToken The collateral token
     * @return loanHealthFactor The health factor of the specific loan
     */
    function _calculateLoanHealthFactor(address user, address borrowToken, address collateralToken)
        private
        view
        returns (uint256)
    {
        Loan storage loan = s_loans[user][borrowToken][collateralToken];

        if (loan.amount == 0 || loan.status != LoanStatus.ACTIVE) {
            return type(uint256).max; // Return maximum value if no active loan
        }

        uint256 interest = _loanInterest(loan);
        uint256 totalDebt = loan.amount + interest;
        uint256 debtValueInUsd = _getUSDValue(borrowToken, totalDebt);
        if (debtValueInUsd == 0) return type(uint256).max;

        uint256 loanCollateral = loan.collateralAmount;
        uint256 collateralValueInUsd = _getUSDValue(collateralToken, loanCollateral);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / debtValueInUsd;
    }

    /**
     * @notice Calculates the interest accrued on a loan
     * @param loan The loan to calculate interest for
     * @return interest The interest amount accrued
     */
    function _loanInterest(Loan storage loan) private view returns (uint256) {
        if (loan.amount == 0 || loan.status != LoanStatus.ACTIVE) return 0;

        uint256 timeElapsed = block.timestamp - loan.startTime;
        return (loan.amount * INTEREST_RATE * timeElapsed) / (SECONDS_PER_YEAR * INTEREST_PRECISION);
    }

    /**
     * @notice Converts a token amount to its USD value
     * @param tokenAddress The token address to convert
     * @param amount The amount of the token to convert
     * @return The USD value of the token amount in wei
     */
    function _getUSDValue(address tokenAddress, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[tokenAddress]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = 1000 USD
        // The returned value from Chainlink will be 1000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return (uint256(price) * amount * ADDITIONAL_FEED_PRECISION) / PRECISION;
    }

    //@note for handling multiple tokens with different decimals();
    // function _getUSDValue2(address tokenAddress, uint256 amount) private view returns (uint256) {
    //     AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[tokenAddress]);
    //     (, int256 price,,,) = priceFeed.latestRoundData();
    //     uint8 decimals = priceFeed.decimals();

    //     // Ensure proper type handling
    //     uint256 adjustedPrice = uint256(price); // Convert int256 to uint256
    //     uint256 scale = 10 ** uint256(decimals); // Calculate scaling factor

    //     // 1 ETH = 1000 USD
    //     // The returned value from Chainlink will be 1000 * 1e8
    //     // Most USD pairs have 8 decimals, so we will just pretend they all do
    //     // We want to have everything in terms of WEI, so we add 10 zeros at the end
    //     return (amount * adjustedPrice) / scale;
    // }

    /**
     * @notice Converts a USD amount to its token equivalent
     * @param token The token address to convert to
     * @param usdAmountInWei The USD amount in wei to convert
     * @return The token amount equivalent to the USD value
     */
    function _getTokenAmountFromUsd(address token, uint256 usdAmountInWei) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // Safe conversion:
        // 1. Multiply usdAmount (18 decimals) by PRECISION (1e18) = 36 decimals intermediate
        // 2. Divide by (price (8 decimals) * ADDITIONAL_FEED_PRECISION (1e10)) = 18 decimals
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL & PUBLIC VIEW & PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the allowed tokens in the protocol
     * @return An array of allowed token addresses
     */
    function getAllowedTokens() public view returns (address[] memory) {
        return s_allowedTokens;
    }

    /**
     * @notice Gets details of a specific loan
     * @param user The user address
     * @param borrowToken The borrowed token address
     * @param collateralToken The collateral token address
     * @return loanAmount The amount borrowed
     * @return collateralAmount The amount of collateral locked
     * @return interestDue The current interest due
     * @return status The loan status
     */
    function getLoanDetails(address user, address borrowToken, address collateralToken)
        public
        view
        returns (uint256 loanAmount, uint256 collateralAmount, uint256 interestDue, LoanStatus status)
    {
        Loan storage loan = s_loans[user][borrowToken][collateralToken];
        return (loan.amount, loan.collateralAmount, _loanInterest(loan), loan.status);
    }

    /**
     * @notice Gets the health factor for a specific loan
     * @param borrowToken The borrowed token address
     * @param collateralToken The collateral token address
     * @return The health factor of the specified loan
     */
    function getLoanHealthFactor(address borrowToken, address collateralToken) public view returns (uint256) {
        return _calculateLoanHealthFactor(msg.sender, borrowToken, collateralToken);
    }

    /**
     * @notice Gets the health factor for a specific loan
     * @param borrowToken The borrowed token address
     * @param collateralToken The collateral token address
     * @return The health factor of the specified loan
     */
    function getUserLoanHealthFactor(address user, address borrowToken, address collateralToken)
        public
        view
        returns (uint256)
    {
        return _calculateLoanHealthFactor(user, borrowToken, collateralToken);
    }

    /**
     * @notice Gets the free collateral amount for a user (not locked in loans)
     * @param collateralToken The collateral token to check
     * @return freeAmount The amount of free collateral
     */
    function getFreeCollateral(address collateralToken) public view returns (uint256 freeAmount) {
        uint256 lockedCollateral = _getLockedCollateral(msg.sender, collateralToken);
        uint256 totalDeposited = s_accountToTokensDeposited[msg.sender][collateralToken];
        return totalDeposited > lockedCollateral ? totalDeposited - lockedCollateral : 0;
    }

    /**
     * @notice Gets the USD value of a specific token amount
     * @param tokenAddress The token address to check
     * @param amount The amount of tokens to convert to USD
     * @return The USD value of the token amount
     */
    function getUSDValue(address tokenAddress, uint256 amount) public view returns (uint256) {
        return _getUSDValue(tokenAddress, amount);
    }

    /**
     * @notice Gets the USD value of a specific token amount
     * @param tokenAddress The token address to check
     * @return The USD value of the token amount
     */
    function getTokenAmountFromUsd(address tokenAddress, uint256 usdAmountInWei) public view returns (uint256) {
        return _getTokenAmountFromUsd(tokenAddress, usdAmountInWei);
    }

    /**
     * @notice Gets all loans for a user with a specific status
     * @param user The user address
     * @param status The loan status to filter by (ACTIVE, REPAID, LIQUIDATED)
     * @return borrowTokens Array of borrow token addresses
     * @return collateralTokens Array of collateral token addresses
     * @return amounts Array of loan amounts
     * @return collateralAmounts Array of collateral amounts
     */
    function getUserLoansWithStatus(address user, LoanStatus status)
        external
        view
        returns (
            address[] memory borrowTokens,
            address[] memory collateralTokens,
            uint256[] memory amounts,
            uint256[] memory collateralAmounts
        )
    {
        uint256 count = 0;
        // First count matching loans
        for (uint256 i = 0; i < s_allowedTokens.length; i++) {
            for (uint256 j = 0; j < s_allowedTokens.length; j++) {
                if (s_loans[user][s_allowedTokens[i]][s_allowedTokens[j]].status == status) {
                    count++;
                }
            }
        }

        // Initialize arrays with the correct size
        borrowTokens = new address[](count);
        collateralTokens = new address[](count);
        amounts = new uint256[](count);
        collateralAmounts = new uint256[](count);

        // Fill arrays with loan data
        uint256 index = 0;
        for (uint256 i = 0; i < s_allowedTokens.length; i++) {
            for (uint256 j = 0; j < s_allowedTokens.length; j++) {
                Loan storage loan = s_loans[user][s_allowedTokens[i]][s_allowedTokens[j]];
                if (loan.status == status) {
                    borrowTokens[index] = s_allowedTokens[i];
                    collateralTokens[index] = s_allowedTokens[j];
                    amounts[index] = loan.amount;
                    collateralAmounts[index] = loan.collateralAmount;
                    index++;
                }
            }
        }
        return (borrowTokens, collateralTokens, amounts, collateralAmounts);
    }

    /*//////////////////////////////////////////////////////////////
                            RECEIVE FUNCTION
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Allows the contract to receive ETH
     */

    //@note even if a user didn't deposit collateral with the `depositCollateral()`, call it on their behalf and keep track of all the funds that enters this protocol
    receive() external payable {}
}

//@note
// External vs Public Functions:
// External
// - External functions are more gas-efficient than public functions because they read parameters directly from calldata rather than copying them to memory
// - They can only be called from outside the contract, making them ideal for functions that should never be called internally. A good example is a liquidation function that should only be triggered by external users.

// Public
// - Public functions are more flexible but more expensive in terms of gas. They can be called both from outside the contract and from within other functions in the contract.
// - They're useful when you need a function to be accessible both internally and externally, like a deposit function that might be called by users directly or used as part of other contract operations.

// Private vs Internal Functions:
// Private
// - Private functions are the most restrictive - they can only be accessed within the same contract and are not visible to derived contracts.
// - They're perfect for sensitive calculations or logic that should never be exposed

// Internal
// - Internal functions are more flexible - they can be accessed within the same contract and by any derived contracts.

// - They're ideal for shared logic that might need to be reused or extended by child contracts, like balance update functions that might need to be customized in different implementations.
