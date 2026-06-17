# YieldPair

> Um DEX AMM cuja liquidez ociosa é emprestada num pool de lending e rende yield
> aos provedores de liquidez — inspirado no [EulerSwap](https://www.euler.finance/).

Projeto educacional / de portfólio para demonstrar domínio de **DeFi**: matemática
de AMM (`x*y=k`), mecânica de lending (juros, health factor, liquidação),
integração entre os dois, e **segurança** (checks-effects-interactions, reentrancy
guards, oráculo resistente a manipulação, testes fuzz/invariant).

⚠️ **Apenas testnet (Sepolia). Não auditado. Não use em mainnet / com fundos reais.**

---

## A ideia em uma frase

Num AMM tradicional, a liquidez fica parada no pool entre swaps. No YieldPair, essa
liquidez ociosa é depositada num **LendingPool** e emprestada a tomadores — então os
LPs ganham as taxas de swap **e** os juros do lending. É o conceito do EulerSwap,
implementado do zero para fins de estudo.

## Arquitetura (faseada)

| Fase | Entrega | Status |
|------|---------|--------|
| 1 | **AMM** Uniswap V2-style: `Factory` / `Pair` (`x*y=k`) / `Router` + tokens de teste | ✅ completa |
| 2 | **LendingPool** Aave-style: supply/borrow/withdraw/repay, juros por índice, health factor, liquidação | 🔄 em andamento |
| 3 | **Integração**: a reserva ociosa do `Pair` é emprestada no `LendingPool` (yield aos LPs) | ⬜ |
| 4 | **Frontend** (React + wagmi) + deploy na Sepolia | ⬜ |

## Contratos implementados

### Fase 1 — AMM
| Contrato | Descrição |
|----------|-----------|
| `TestToken` | ERC20 de testnet com mint aberto |
| `AmmLibrary` | Biblioteca pura: quote, getAmountOut/In, sqrt |
| `Pair` | Pool x*y=k + LP token; fee 0.30%; CEI + nonReentrant |
| `Factory` | Cria e registra pares; getPair simétrico |
| `Router` | addLiquidity / removeLiquidity / swapExactTokensForTokens |

### Fase 2 — LendingPool
| Contrato | Descrição |
|----------|-----------|
| `MockOracle` | Oráculo owner-controlled (testnet); nunca usa spot do AMM |
| `LendingPool` | supply / borrow / withdraw / repay / liquidate; juros por borrowIndex acumulado; healthFactor multi-ativo 1e18-scaled; closeFactor 50%, liquidationBonus 1.08× |

## Stack

| Camada | Tecnologia |
|--------|-----------|
| Contratos | Solidity 0.8.24, **Foundry** (forge/cast/anvil), OpenZeppelin |
| Testes | Foundry unit + fuzz + invariant |
| Frontend | React 19, Vite, TypeScript, wagmi, viem, RainbowKit, Tailwind 4 |
| Rede | Sepolia testnet |

## Estrutura do repositório (monorepo)

```
contracts/   # projeto Foundry (src, test, script, lib)
frontend/    # dapp Vite + React
deployments/ # endereços por rede
```

## Rodando os contratos

```bash
cd contracts
forge build
forge test   # 77 testes: 54 unit + 11 fuzz + 12 invariant (3 suites cada fase)
forge fmt --check
```

## Decisões de design e segurança

### AMM (Fase 1)
- **Factory usa `new Pair()` (CREATE), não CREATE2** — elimina a dependência de init-code-hash; `AmmLibrary` lê pares via `factory.getPair()`.
- **Fee 0.30% via k-check único** — sem dedução prévia; verificado como `(b0·1000 − in0·3)·(b1·1000 − in1·3) ≥ r0·r1·1_000_000`.
- **`MINIMUM_LIQUIDITY` queimado para `address(0xdEaD)`** — OZ v5 reverte mint para `address(0)`; burned shares protegem contra o ataque de inflação de LP.

### LendingPool (Fase 2)
- **Juros por índice acumulado** — `borrowIndex` cresce globalmente; cada usuário armazena o snapshot no momento do empréstimo. Zero loops sobre holders.
- **Oráculo nunca lê spot do AMM** — preço spot é manipulável por flash loan num único bloco. O `MockOracle` aceita apenas preços setados pelo owner; em produção seria substituído por TWAP ou Chainlink.
- **Arredondamento sempre contra o usuário** — `debtOf` arredonda UP (usuário deve mais), `supplyBalanceOf` DOWN (usuário recebe menos), `seizeAmount` DOWN (liquidador recebe menos → borrower não é sobre-penalizado).
- **CEI estrito em todas as funções core** — `accrueInterest` primeiro, depois validações, mutações de state, HF check, e só então o transfer externo.
- **`healthFactor == 1e18` é saudável** — posição exatamente no limite não é liquidável e não trava.

---

Construído como continuação dos estudos de web3 (o projeto anterior foi um
[livro de visitas on-chain](https://github.com/viniciusandradedev0/web3-guestbook)).
