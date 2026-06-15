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
| 1 | **AMM** Uniswap V2-style: `Factory` / `Pair` (`x*y=k`) / `Router` + tokens de teste | 🚧 em construção |
| 2 | **LendingPool** Aave-style: supply/borrow/withdraw/repay, juros por índice, health factor, liquidação | ⬜ |
| 3 | **Integração**: a reserva ociosa do `Pair` é emprestada no `LendingPool` (yield aos LPs) | ⬜ |
| 4 | **Frontend** (React + wagmi) + deploy na Sepolia | ⬜ |

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
forge test            # unit + fuzz + invariant
forge fmt --check
```

## Decisões de design e segurança

Conforme o projeto avança, esta seção vai documentar as escolhas (modelo de juros,
mecanismo de integração, oráculo) e os **vetores de ataque considerados** — em
especial por que o lending **não** usa o preço spot do AMM como oráculo
(manipulável por flash loan / swap grande). Documentar os trade-offs faz parte do
objetivo de portfólio.

---

Construído como continuação dos estudos de web3 (o projeto anterior foi um
[livro de visitas on-chain](https://github.com/viniciusandradedev0/web3-guestbook)).
