# YieldPair — LendingPool Design (Fase 2, Passo 2.0)

Produzido pelo agente `defi-architect`. Aprovado — pode ser implementado diretamente pelo `solidity-engineer`.

---

## Decisões

### (a) Arquitetura → LendingPool multi-ativo único

Um contrato `LendingPool` com `mapping(address token => Market)`. Cross-asset HF em um único contrato; sem Comptroller separado. Mais simples de auditar e testar.

### (b) Modelo de juros — linear por segundo, escala 1e18

```
SECONDS_PER_YEAR       = 31_536_000
BASE_RATE_PER_SECOND   = 634_195_840     // floor(0.02e18 / 31_536_000)
SLOPE_PER_SECOND       = 6_341_958_400   // floor(0.20e18 / 31_536_000)
RESERVE_FACTOR         = 0.10e18

utilization = totalBorrows * 1e18 / (cash + totalBorrows)  // cash = balanceOf
borrowRatePerSecond = BASE_RATE_PER_SECOND + SLOPE_PER_SECOND * utilization / 1e18
```

**accrueInterest(token):**
```
dt = block.timestamp - market.lastAccrual
if (dt == 0) return

interestFactor = borrowRatePerSecond * dt          // escala 1e18
accruedBorrow  = totalBorrows * interestFactor / 1e18   // ROUND DOWN
reserve        = accruedBorrow * RESERVE_FACTOR / 1e18  // ROUND DOWN
toSuppliers    = accruedBorrow - reserve

borrowIndex   += borrowIndex * interestFactor / 1e18    // ROUND DOWN
totalBorrows  += accruedBorrow
totalReserves += reserve
totalSupplied += toSuppliers
lastAccrual    = block.timestamp
```

Juro linear (`r*dt`), não compounding por-segundo — escolha consciente para testnet.

### (c) healthFactor

```
collateralValue = Σ_i  collateral[user][token_i] * price_i / 1e18 * cf_i / 1e18  // ROUND DOWN
debtValue       = Σ_j  debtOf(user, token_j)     * price_j / 1e18                // debtOf round UP

healthFactor = debtValue == 0 ? type(uint256).max
             : collateralValue * 1e18 / debtValue
```

- `price` vem do oracle: 1e18 == $1.00.
- `HF >= 1e18` → saudável; `HF < 1e18` → liquidável.
- `HF == 1e18` exato → SAUDÁVEL (não é liquidável, não trava).

### (d) Liquidação

```
CLOSE_FACTOR       = 0.50e18
LIQUIDATION_BONUS  = 1.08e18
COLLATERAL_FACTOR  = 0.75e18   // padrão por ativo

maxRepay     = debtOf(user, debtToken) * CLOSE_FACTOR / 1e18       // ROUND DOWN
seizeValue   = repayAmount * price_debt / 1e18 * LIQUIDATION_BONUS / 1e18
seizeAmount  = seizeValue * 1e18 / price_collateral                 // ROUND DOWN
seizeAmount  = min(seizeAmount, collateral[borrower][collToken])
```

Guards: `HF < 1e18`, `repayAmount <= maxRepay`, `liquidator != borrower`, `bonus * cf < 1e18` (pré-condição de parametrização — 1.08 * 0.75 = 0.81 < 1).

### (e) Oráculo

```solidity
interface IPriceOracle {
    function getPrice(address token) external view returns (uint256); // 1e18 == $1
}
```

`MockOracle`: `setPrice(token, price)` onlyOwner. Reverte `PriceNotSet` se price == 0. NUNCA ler spot do AMM (manipulável via flash-loan em um único tx).

---

## Assinaturas-alvo

### IPriceOracle.sol
```solidity
interface IPriceOracle {
    function getPrice(address token) external view returns (uint256 price);
}
```

### MockOracle.sol
- Herda `Ownable(msg.sender)`, implementa `IPriceOracle`
- `mapping(address => uint256) private prices`
- `event PriceSet(address indexed token, uint256 price)`
- `error PriceNotSet(address token)`
- `function setPrice(address token, uint256 price) external onlyOwner`
- `function getPrice(address token) external view returns (uint256)`

### ILendingPool.sol
```solidity
interface ILendingPool {
    event MarketListed(address indexed token, uint256 collateralFactor);
    event Supply(address indexed user, address indexed token, uint256 amount, uint256 sharesMinted);
    event Withdraw(address indexed user, address indexed token, uint256 amount, uint256 sharesBurned);
    event Borrow(address indexed user, address indexed token, uint256 amount);
    event Repay(address indexed payer, address indexed user, address indexed token, uint256 amount);
    event Liquidate(address indexed liquidator, address indexed borrower,
        address debtToken, address collateralToken, uint256 repayAmount, uint256 seizeAmount);
    event AccrueInterest(address indexed token, uint256 borrowIndex, uint256 totalBorrows);

    function listMarket(address token, uint256 collateralFactor) external; // onlyOwner
    function supply(address token, uint256 amount) external;
    function withdraw(address token, uint256 amount) external;
    function borrow(address token, uint256 amount) external;
    function repay(address token, uint256 amount, address onBehalfOf) external;
    function liquidate(address borrower, address debtToken, address collateralToken,
        uint256 repayAmount) external returns (uint256 seizeAmount);

    function accrueInterest(address token) external;
    function healthFactor(address user) external view returns (uint256);
    function debtOf(address user, address token) external view returns (uint256);
    function supplyBalanceOf(address user, address token) external view returns (uint256);
    function utilization(address token) external view returns (uint256);
    function borrowRatePerSecond(address token) external view returns (uint256);
}
```

### LendingPool.sol — estado interno

```solidity
uint256 internal constant WAD                 = 1e18;
uint256 internal constant SECONDS_PER_YEAR    = 31_536_000;
uint256 internal constant BASE_RATE_PER_SECOND = 634_195_840;
uint256 internal constant SLOPE_PER_SECOND    = 6_341_958_400;
uint256 internal constant RESERVE_FACTOR      = 0.10e18;
uint256 internal constant CLOSE_FACTOR        = 0.50e18;
uint256 internal constant LIQUIDATION_BONUS   = 1.08e18;

struct Market {
    bool    listed;
    uint256 collateralFactor;   // 1e18 scale
    uint256 totalBorrows;
    uint256 totalSupplied;
    uint256 totalReserves;
    uint256 borrowIndex;        // começa em 1e18
    uint256 supplyIndex;        // começa em 1e18
    uint256 totalSupplyShares;
    uint256 lastAccrual;
}

mapping(address token => Market) internal markets;
address[] internal marketsList;

mapping(address user => mapping(address token => uint256)) internal supplyShares;
mapping(address user => mapping(address token => uint256)) internal borrowPrincipal;
mapping(address user => mapping(address token => uint256)) internal borrowIndexSnapshot;

IPriceOracle public immutable oracle;

// Errors
error MarketNotListed(address token);
error MarketAlreadyListed(address token);
error ZeroAmount();
error InsufficientCash();
error Undercollateralized();
error HealthyPosition();
error SelfLiquidation();
error RepayExceedsCloseFactor();
error InvalidCollateralFactor();
```

**Rounding:**
- `debtOf`: `Math.mulDiv(principal, currentIndex, snapshot, Math.Rounding.Ceil)` — UP
- `supplyBalanceOf`: `shares * supplyIndex / 1e18` — DOWN
- `seizeAmount`: DOWN
- `maxRepay`: DOWN

**CEI obrigatório em toda função core:** `accrueInterest` → validações → atualiza state → HF check → safeTransfer(From) por último.

---

## Invariantes para os testes (Passo 2.2)

1. **Solvência (master):** `balanceOf(pool) + totalBorrows >= totalSupplied` para todo mercado
2. **borrowIndex monotônico:** nunca decresce; supplyIndex idem
3. **HF após borrow/withdraw:** `healthFactor(user) >= 1e18` imediatamente após
4. **Liquidação melhora saúde:** `HF_after >= HF_before`
5. **Liquidação só em insolvência:** `liquidate` com `HF >= 1e18` reverte `HealthyPosition`
6. **No self-liquidation:** `liquidate(borrower = msg.sender)` sempre reverte
7. **totalReserves não-decrescente**
8. **lastAccrual monotônico** e `<= block.timestamp`
9. **debtOf consistente:** `Σ debtOf(user, token) <= totalBorrows + ε` (round-up por usuário)
10. **Oracle price > 0** para todo mercado listado

---

## Riscos principais (dev solo)

1. Esquecer `accrueInterest` antes de validar HF — erro nº1.
2. Direção de arredondamento invertida — usar `Math.mulDiv` com `Rounding` explícito.
3. Preços de unidades diferentes (tokens não-18 decimais) — premissa: só 18 decimais.
4. Reentrância cross-function em `liquidate` (dois tokens, dois transfers) — CEI estrito.
5. Divisão por zero em utilization/index — guards explícitos.
6. `borrow`/`withdraw` sem checar `cash` — reverter `InsufficientCash` antes.

---

## Fora de escopo

Flash loans, governança, TWAP real do AMM como oráculo, kink model, tokens não-18-decimais,
fee-on-transfer/rebase/ERC777, withdraw de totalReserves, bad-debt socialization, integração
AMM↔Lending automática (Fase 3), auditoria mainnet-grade.
