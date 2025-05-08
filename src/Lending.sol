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
 * @dev Implements token-specific collateralization where loans are backed by specific collateral tokens
 * @dev Uses ReentrancyGuard to prevent reentrancy attacks during token transfers
 * @dev Uses Ownable to manage protocol administration
 */
contract Lending is ReentrancyGuard, Ownable {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    error Lending__TokenAddressesArrayAndPriceFeedAddressesArrayMustBeSameLength();
    error Lending__NeedsMoreThanZero();
    error Lending__UnsupportedToken(address tokenAddress);
    error Lending__DepositFailed();
    error Lending__InsufficientTokenBalance(uint256 userBalance);
    error Lending__BreaksProtocolHealthFactor(uint256 userHealthFactor);
    error Lending__TransferFailed();
    error Lending__NotEnoughTokenInVaultToBorrow();
    error Lending__BorrowngTokenFailed();
    error Lending__LoanRepaymentFailed();
    error Lending__InsufficientTokenBalanceToRepayLoan(uint256 userBalance, uint256 totalDue);
    error Lending__AccountHealthFactorGreaterThanOne(uint256 userHealthFactor);
    error Lending__InsufficientCollateral(uint256 available, uint256 required);
    error Lending__NoLoanFound();
    error Lending__InsufficientCollateralForLoan();
    error Lending__SameTokenNotAllowed();

    /*//////////////////////////////////////////////////////////////
                                STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    // At 80% Loan to Value Ratio, the loan can be liquidated
    uint256 public constant LIQUIDATION_THRESHOLD = 80;
    // 5% Liquidation Reward
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 public constant MIN_HEALTH_FACTOR = 1;
    uint256 public constant INTEREST_RATE = 2;
    uint256 public constant LIQUIDATION_REWARD = 5;
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
        // For example ETH / USD or MKR / USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
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
        // Calculate how much collateral is locked in loans
        uint256 lockedCollateral = _getLockedCollateral(msg.sender, tokenAddress);

        // Calculate free collateral
        uint256 totalDeposited = s_accountToTokensDeposited[msg.sender][tokenAddress];
        uint256 freeCollateral = totalDeposited - lockedCollateral;

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
     * @dev Ensures sufficient collateral value and protocol liquidity
     * @dev Uses nonReentrant to prevent reentrancy during token transfer
     * @dev Emits LoanCreated event upon successful borrow
     * @dev @param borrowToken and @param collateralToken must be different
     */
    function borrow(address borrowToken, address collateralToken, uint256 borrowAmount)
        external
        nonReentrant
        isAllowedToken(borrowToken)
        isAllowedToken(collateralToken)
        moreThanZero(borrowAmount)
    {
        // Add check for same token
        if (borrowToken == collateralToken) {
            revert Lending__SameTokenNotAllowed();
        }

        // Check if protocol has enough tokens to lend
        uint256 protocolTokenBalance = IERC20(borrowToken).balanceOf(address(this));
        if (protocolTokenBalance < borrowAmount) {
            revert Lending__NotEnoughTokenInVaultToBorrow();
        }

        // Calculate how much collateral is needed for this loan
        uint256 borrowValueInUsd = _getUSDValue(borrowToken, borrowAmount);
        uint256 requiredCollateralValueInUsd = (borrowValueInUsd * 100) / LIQUIDATION_THRESHOLD;
        uint256 requiredCollateralAmount = _getTokenAmountFromUsd(collateralToken, requiredCollateralValueInUsd);

        // Check if user has enough free collateral
        uint256 lockedCollateral = _getLockedCollateral(msg.sender, collateralToken);
        uint256 totalDeposited = s_accountToTokensDeposited[msg.sender][collateralToken];
        uint256 freeCollateral = totalDeposited - lockedCollateral;

        if (freeCollateral < requiredCollateralAmount) {
            revert Lending__InsufficientCollateralForLoan();
        }

        // Create loan and lock collateral
        s_loans[msg.sender][borrowToken][collateralToken] = Loan({
            amount: borrowAmount,
            interest: 0,
            startTime: block.timestamp,
            status: LoanStatus.ACTIVE,
            collateralAmount: requiredCollateralAmount
        });

        // Transfer borrowed tokens to user
        emit LoanCreated(msg.sender, borrowToken, collateralToken, borrowAmount, requiredCollateralAmount);
        bool success = IERC20(borrowToken).transfer(msg.sender, borrowAmount);
        if (!success) revert Lending__BorrowngTokenFailed();
    }

    /**
     * @notice Allows users to repay their specific loan
     * @param borrowToken The token address that was borrowed
     * @param collateralToken The token address used as collateral
     * @param amount The amount to repay (must be at least the full loan amount plus interest)
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

        // Update loan status
        loan.amount = 0;
        loan.interest = 0;
        loan.collateralAmount = 0;
        loan.status = LoanStatus.REPAID;

        emit LoanRepaid(msg.sender, borrowToken, collateralToken, totalDue);

        bool success = IERC20(borrowToken).transferFrom(msg.sender, address(this), totalDue);
        if (!success) revert Lending__LoanRepaymentFailed();
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

        if (loan.status != LoanStatus.ACTIVE || loan.amount == 0) {
            revert Lending__NoLoanFound();
        }

        // Check if loan is unhealthy
        uint256 loanHealthFactor = _calculateLoanHealthFactor(account, borrowToken, collateralToken);
        if (loanHealthFactor > MIN_HEALTH_FACTOR) {
            revert Lending__AccountHealthFactorGreaterThanOne(loanHealthFactor);
        }

        uint256 interest = _loanInterest(loan);
        uint256 totalDue = loan.amount + interest;
        uint256 collateralToSeize = loan.collateralAmount;

        // Calculate liquidation bonus
        uint256 liquidationReward = (totalDue * LIQUIDATION_REWARD) / 100;
        uint256 rewardInCollateralToken =
            _getTokenAmountFromUsd(collateralToken, _getUSDValue(borrowToken, liquidationReward));

        // Total collateral to seize including reward
        uint256 totalCollateralToSeize = collateralToSeize + rewardInCollateralToken;

        // Ensure user has enough collateral
        uint256 userCollateral = s_accountToTokensDeposited[account][collateralToken];
        if (userCollateral < totalCollateralToSeize) {
            revert Lending__InsufficientCollateral(userCollateral, totalCollateralToSeize);
        }

        // Check if liquidator has enough tokens to repay
        uint256 liquidatorBalance = IERC20(borrowToken).balanceOf(msg.sender);
        if (liquidatorBalance < totalDue) {
            revert Lending__InsufficientTokenBalanceToRepayLoan(liquidatorBalance, totalDue);
        }

        // Update loan status
        loan.amount = 0;
        loan.interest = 0;
        loan.collateralAmount = 0;
        loan.status = LoanStatus.LIQUIDATED;

        // Update user's collateral balance
        s_accountToTokensDeposited[account][collateralToken] -= totalCollateralToSeize;

        emit LoanLiquidated(account, borrowToken, collateralToken, totalDue, totalCollateralToSeize, msg.sender);

        // Transfer debt tokens from liquidator to protocol
        bool debtTransferSuccess = IERC20(borrowToken).transferFrom(msg.sender, address(this), totalDue);
        if (!debtTransferSuccess) revert Lending__TransferFailed();

        // Transfer collateral to liquidator
        bool collateralTransferSuccess = IERC20(collateralToken).transfer(msg.sender, totalCollateralToSeize);
        if (!collateralTransferSuccess) revert Lending__TransferFailed();
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
            return 100e8; // Return a high health factor if no active loan
        }

        uint256 interest = _loanInterest(loan);
        uint256 totalDebt = loan.amount + interest;
        uint256 debtValueInUsd = _getUSDValue(borrowToken, totalDebt);

        uint256 collateralValueInUsd = _getUSDValue(collateralToken, loan.collateralAmount);
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
        return (loan.amount * INTEREST_RATE * timeElapsed) / (SECONDS_PER_YEAR * 100);
    }

    /**
     * @notice Converts a token amount to its USD value
     * @param tokenAddress The token address to convert
     * @param amount The amount of the token to convert
     * @return The USD value of the token amount
     */
    function _getUSDValue(address tokenAddress, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[tokenAddress]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

       //@note for handling multiple tokens with different decimals();
    // function _getUSDValue(address tokenAddress, uint256 amount) private view returns (uint256) {
    //     AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[tokenAddress]);
    //     (, int256 price,,,) = priceFeed.latestRoundData();
    //     uint8 decimals = dataFeed.decimals();

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
    function _getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
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
