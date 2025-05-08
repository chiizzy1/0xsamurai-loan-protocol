# Lending/Borrowing Protocol Analysis

## 1. Core Metrics & Formulas

### **Health Factor (HF)**

Indicates the safety of a user's loan position.  
**Formula:**  
`HF = (Collateral Value (in $) / Debt Value (in $)) × Liquidation Threshold`

- If `HF > 1`, the loan is safe.
- If `HF ≤ 1`, liquidation occurs.

- e.g user deposits ETH worth $200 and borrows $100 in USDC at a liquidation threshold of 85%
  `HF = (200 / 100) × 0.85 = 1.7`

Safe position (HF > 1)

**Question: How does a position backed by Stablecoin HF ≤ 1**

Even with stablecoin collateral, HF can drop below 1 through:

1. **Stablecoin Depegging**

   - Temporary loss of peg (e.g., USDC to $0.88)
   - Example: $1000 USDC collateral depegs to $880
   - $850 debt → HF = (880/850) × 0.9 = 0.93

2. **Interest Accumulation**

   - Growing debt from unpaid interest
   - Example: $1000 USDC collateral, $900 debt at 10% APR
   - After 1 year: $990 debt → HF = (1000/990) × 0.9 = 0.91

3. **Protocol-specific Risks**

   - Smart contract bugs
   - Oracle failures
   - Protocol insolvency
   - Can affect stablecoin positions

4. **Cross-collateral Effects**
   - Protocol-wide issues from other undercollateralized positions
   - Bad debt coverage requirements
   - Can impact stablecoin positions

---

### **Collateral-to-Debt Ratio (CDR)**

Measures the ratio of collateral to borrowed debt.  
**Formula:**  
`CDR = Collateral Value / Debt Value`

- Protocols usually require `CDR > 1`.

---

### **Loan-to-Value (LTV)**

Defines the maximum borrowing power based on collateral.  
**Formula:**  
`LTV = Borrow Amount / Collateral Value`

- Example: If `LTV = 70%`, $1,000 in collateral allows borrowing $700.

---

### **Utilization Ratio (UR)**

Indicates the percentage of borrowed funds compared to total liquidity.  
**Formula:**  
`UR = Total Borrowed / Total Liquidity`

- Due to over-collateralization requirements, practical UR rarely exceeds 60%
- High UR (above 50%) can increase interest rates to incentivize repayment
- Typical UR ranges in major protocols: 30-60%

**Protocol Risks & Safety Measures**

Even with over-collateralization, several scenarios can endanger protocol stability:

1. **Market Risks**

   - Rapid collateral price drops (50%+ in hours)
   - Simultaneous undercollateralization of many positions
   - Liquidators overwhelmed by volume
   - Example: LUNA/UST collapse (2022)

2. **Technical Risks**

   - Oracle manipulation or failures
   - False price feeds enabling excessive borrowing
   - Example: bZx flash loan attack (2020)

3. **Protocol Design Risks**

   - Borrowing against protocol's own token
   - Death spiral from token price drops
   - Example: Venus Protocol XVS issues

4. **Liquidity Risks**

   - Mass withdrawals by liquidity providers
   - Borrowers unable to repay
   - Liquidators unable to execute
   - Example: 2020 "Black Thursday" crash

5. **Smart Contract Risks**
   - Bypassed collateral requirements
   - Excessive borrowing without proper checks
   - Various protocol hacks

**Safety Measures Implemented:**

- Liquidation thresholds
- Reserve factors
- Emergency pauses
- Multiple oracle sources
- Circuit breakers
- Insurance funds
- Protocol-specific risk parameters

---

### **Interest/Borrowing Rate**

Dynamic rate based on `UR`.

- Uses models like **kinked curves** (e.g., Compound/Aave).
- **Formula (basic):**  
  `Rate = BaseRate + UR × Slope`

The kinked curve model typically has two slopes:

1. **Normal Slope:** Lower interest rates when utilization is below optimal (usually around 80-90%)
2. **Emergency Slope:** Sharply increasing rates when utilization exceeds optimal to incentivize repayments

**Example:**

- Base Rate = 0.5%
- Normal Slope = 0.2
- Emergency Slope = 0.8
- Optimal Utilization = 90%

For UR = 70%:
`Rate = 0.5% + (0.7 × 0.2) = 0.5% + 0.14 = 0.64%`

For UR = 95%:
`Rate = 0.5% + (0.9 × 0.2) + ((0.95 - 0.9) × 0.8) = 0.5% + 0.18 + 0.04 = 0.72%`

This model helps maintain protocol stability by:

- Offering competitive rates during normal conditions
- Rapidly increasing rates to prevent liquidity crunches
- Incentivizing borrowers to repay when utilization is high

---

### **Liquidation Price**

The price at which collateral is liquidated.  
**Formula:**  
`Liquidation Price = Debt / (Collateral Amount × Liquidation Threshold)`

**Example:**

- User deposits 10 ETH (current price: $2,000/ETH)
- Total collateral value: $20,000
- Borrows $10,000 USDC
- Liquidation threshold: 85%

Calculation:

```
Liquidation Price = 10,000 / (10 × 0.85)
                 = 10,000 / 8.5
                 = 1,176.47 USD/ETH
```

This means:

- If ETH price drops below $1,176.47, position becomes undercollateralized
- Current price buffer: $2,000 - $1,176.47 = $823.53 (41.18% drop allowed)
- At liquidation price:
  - Collateral value = 10 ETH × $1,176.47 = $11,764.70
  - Maximum allowed debt = $11,764.70 × 0.85 = $10,000
  - Exactly matches current debt, triggering liquidation

---

## 2. Key Concepts

### **Collateral Types**

Assets accepted as collateral in lending protocols, each with different risk profiles and parameters:

1. **Major Cryptocurrencies**

   - Examples: ETH, BTC, WETH, WBTC
   - Higher liquidation thresholds (75-85%)
   - Lower interest rates
   - Risk: Moderate volatility
   - Example: Aave accepts ETH with 82.5% LTV ( With $1000 ETH, you can borrow $825 )

2. **Stablecoins**

   - Examples: USDC, DAI, USDT
   - Highest liquidation thresholds (85-90%)
   - Lowest interest rates
   - Risk: Low volatility, but protocol/issuer risk
   - Example: Compound accepts USDC with 90% LTV

3. **Liquid Staking Tokens**

   - Examples: stETH, rETH, cbETH
   - Medium liquidation thresholds (70-80%)
   - Slightly higher interest rates
   - Risk: Price deviation from underlying asset
   - Example: Aave accepts stETH with 80% LTV

4. **Protocol Tokens**
   - Examples: AAVE, COMP, MKR
   - Lowest liquidation thresholds (40-60%)
   - Highest interest rates
   - Risk: High volatility, protocol risk
   - Example: Aave accepts AAVE with 50% LTV ( With $1000 AAVE, you can only borrow $500 )

**Risk Factors Considered:**

- Volatility: Higher volatility → Lower LTV
- Liquidity: Lower liquidity → Lower LTV
- Market Cap: Smaller cap → Lower LTV
- Oracle Reliability: Less reliable → Lower LTV
- Protocol Integration: Newer integration → Lower LTV

**Dynamic Adjustments:**

- Protocols can adjust parameters based on:
  - Market conditions
  - Asset performance
  - Protocol risk assessment
  - Governance votes

### **Interest Rate Models**

- **Stable Rates:** Fixed over time (predictable).
- **Variable Rates:** Adjust based on market demand (dynamic).

### **Liquidation Mechanism**

- If `HF ≤ 1`, collateral is sold to repay debt.
- **Liquidation Incentives:** A bonus for liquidators to cover bad debt.

**Case Study: Aave's Liquidation System:**

1. **Liquidation Bonus**

   - Liquidators receive a bonus on the collateral they purchase
   - Example: 5% bonus means liquidator gets $105 worth of collateral for $100 of debt
   - Current Aave v3 bonuses:
     - Most assets: 5%
     - Stablecoins: 2%
     - High-risk assets: up to 15%

2. **Liquidation Process**

   - When HF ≤ 1, anyone can trigger liquidation
   - Liquidator repays part or all of the debt
   - Receives equivalent collateral + bonus
   - Example:
     - User position: 10 ETH ($20,000) collateral, $10,000 debt
     - HF drops below 1
     - Liquidator repays $5,000 debt
     - Receives: 2.5 ETH + 5% bonus = 2.625 ETH

3. **Partial vs Full Liquidation**

   - Aave allows partial liquidations (unlike some protocols)
   - Liquidators can choose how much debt to repay
   - Helps prevent large price impacts
   - Multiple liquidators can participate

4. **Health Factor Recovery**

   - After liquidation, HF should improve
   - If HF still ≤ 1, more liquidation can occur
   - Process continues until HF > 1 or all collateral is liquidated

5. **Risk Management**
   - Bonus size based on asset risk
   - Higher risk = higher bonus needed
   - Prevents bad debt accumulation
   - Incentivizes quick liquidation

### **Reserve Factor**

- A percentage of interest paid goes to the protocol treasury for safety.

### **Flash Loans**

- Loans without collateral, repaid within a single transaction.
- Useful for arbitrage, liquidations, or refinancing.

---

## 3. Examples to Simplify

### **Example 1: Calculating Health Factor**

- **Collateral:** 2 ETH, price = $1,500/ETH.
- **Debt:** 1,000 DAI.
- **Liquidation Threshold:** 80%.
  HF = (2 × 1,500) / 1,000 × 0.8 = 2.4

Safe position (`HF > 1`).

---

### **Example 2: Loan-to-Value (LTV)**

- **Collateral:** $10,000 worth of ETH.
- **Max LTV:** 75%.
  Max Borrow = 10,000 × 0.75 = 7,500

---

## 4. Comparison Across Protocols

- **Aave:** Implements flash loans and variable/stable interest rates.
- **Compound:** Uses a kinked interest rate model and focuses on efficiency.
- **MakerDAO:** Introduced DAI and over-collateralized loans.
- **Venus (BSC):** Focuses on multi-chain support and stablecoins.

---

## 5. Vulnerabilities

### **Key Risks**

1. **Oracle Manipulation:**
   - Fake price feeds to exploit collateral values.
2. **Over-Collateralization Assumptions:**
   - Highly volatile assets can drop in value too quickly for liquidation.
3. **Interest Rate Spirals:**
   - Extreme `UR` causing borrowing costs to skyrocket.
4. **Liquidation Inefficiency:**
   - Poor execution may leave bad debt.

### **Case Studies**

- **Compound Exploit:** Manipulated token price feed to borrow excessive funds.
- **Aave's Safety Module:** Designed to cover deficits in extreme scenarios.

---

## 6. How to Approach Analysis

1. **Understand Key Formulas:**
   - Break them down and validate with simple examples.
2. **Explore Real-World Data:**
   - Analyze liquidation events and metrics like `UR` trends.
3. **Compare Protocols:**
   - Highlight unique features or trade-offs.
4. **Think Like an Attacker:**
   - Investigate where price feeds, thresholds, or incentives could be abused.

---
