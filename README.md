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
| 2 | **LendingPool** Aave-style: supply/borrow/withdraw/repay, juros por índice, health factor, liquidação | ✅ completa |
| 3 | **Integração**: a reserva ociosa do `Pair` é emprestada no `LendingPool` (yield aos LPs) | ✅ completa |
| 4 | **Frontend** (React + wagmi) + deploy na Sepolia | 🔄 deploy na Sepolia ✅ feito (7/7 contratos verificados) · frontend ⬜ pendente |

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

### Fase 3 — Integração AMM↔Lending
| Contrato / Arquivo | Descrição |
|--------------------|-----------|
| `Pair` (modificado) | Ganha `lendingPool` + `bufferBps`; contabilidade muda para `totalReserve = físico + supplied`; implementa `_sweepExcess` e `_ensureLiquidity` |
| `test/mocks/MockLendingPool.sol` | Mock 1:1 (sem juros) com flag `freeze` para simular alta utilização em testes |
| `test/unit/Integration.t.sol` | 12 testes de integração Pair↔LendingPool |
| `test/invariant/Integration.t.sol` | Invariantes de totalReserve sob sequências aleatórias de operações |

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
forge test   # 92 testes: unit + fuzz + invariant (Fases 1–3)
forge fmt --check
```

## Deploy (Sepolia)

Sistema completo deployado e verificado na Sepolia testnet (chainId `11155111`) via
`contracts/script/Deploy.s.sol`. Endereços também salvos em `deployments/sepolia.json`.

| Contrato | Endereço | Etherscan |
|----------|----------|-----------|
| Deployer | `0xec91D2A97dD70fb2ff9C651775a1bfe6639D9411` | [link](https://sepolia.etherscan.io/address/0xec91D2A97dD70fb2ff9C651775a1bfe6639D9411) |
| mUSDC (`TestToken`) | `0x4CF16121615C0F4bBC94De15A9CcbaaBC9f623F4` | [link](https://sepolia.etherscan.io/address/0x4CF16121615C0F4bBC94De15A9CcbaaBC9f623F4) |
| mWETH (`TestToken`) | `0xBE1A157e0dDEfA130E183bEFc6aE81BcCd1a9112` | [link](https://sepolia.etherscan.io/address/0xBE1A157e0dDEfA130E183bEFc6aE81BcCd1a9112) |
| `Factory` | `0x803B5d9EbA385383025ad07856B059201F202Fd0` | [link](https://sepolia.etherscan.io/address/0x803B5d9EbA385383025ad07856B059201F202Fd0) |
| `Router` | `0x14E0ceAFd363e63CEEA412D1C47d57A0F8A963d6` | [link](https://sepolia.etherscan.io/address/0x14E0ceAFd363e63CEEA412D1C47d57A0F8A963d6) |
| `Pair` (mUSDC/mWETH) | `0xd3e6b9784A0edCE80451979dCF1457ABBd1B33b2` | [link](https://sepolia.etherscan.io/address/0xd3e6b9784A0edCE80451979dCF1457ABBd1B33b2) |
| `MockOracle` | `0xEf52E7129593C1b4531479780B8892C102526B60` | [link](https://sepolia.etherscan.io/address/0xEf52E7129593C1b4531479780B8892C102526B60) |
| `LendingPool` | `0x14Bcb5Ebc00b4D023FB71B4BA60413FbcB24d31c` | [link](https://sepolia.etherscan.io/address/0x14Bcb5Ebc00b4D023FB71B4BA60413FbcB24d31c) |

Todos os 7 contratos foram **verificados com sucesso no Etherscan** (source + ABI públicos).
O script de deploy também seedou um cenário de demonstração: liquidez inicial de
3.000.000 mUSDC + 1.000 mWETH no par, e uma posição de empréstimo aberta (10 mWETH de
colateral, 9.000 mUSDC emprestados, health factor ≈ **2.5**) — confirmada on-chain via
`cast call` (`getReserves`, `suppliedReserves`, `healthFactor`).

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

### Integração AMM↔Lending (Fase 3)

#### Contabilidade: coordenada `totalReserve`

O `Pair` passa a usar uma contabilidade de **reserva total**:

```
totalReserve_i  =  balanceOf(pair)_i  +  supplied_i
```

Onde `supplied_i` é o principal depositado no `LendingPool` para o token `i`. A invariante é mantida em todo caminho de execução (mint, swap, burn, sweep, recall).

O `getReserves()` retorna `totalReserve`, então o k-check e o TWAP continuam operando sobre a liquidez completa do par — não apenas sobre o saldo físico.

#### Trade-off: buffer de liquidez vs yield

O parâmetro `bufferBps` (em basis points, configurável pela Factory) controla a fração mínima de `totalReserve` que o `Pair` mantém disponível fisicamente:

```
targetLiquid_i  =  ceil(totalReserve_i × bufferBps / 10_000)
```

| `bufferBps` | Fração líquida | Implicação |
|-------------|---------------|------------|
| `1_000` (10%) | 10% retido no pool | Mais capital no lending → mais yield; risco de falha em swaps grandes |
| `5_000` (50%) | 50% retido | Equilíbrio moderado |
| `10_000` (100%) | 100% retido | Comportamento idêntico ao AMM puro (zero yield extra) |

**Quanto menor o buffer, maior o rendimento potencial** — mas swaps que precisem de mais do que o buffer encontrarão o lending em alta utilização e poderão falhar graciosamente (ver abaixo).

#### `_sweepExcess` — depositando liquidez ociosa

Após cada `mint` ou `swap`, qualquer saldo físico acima de `targetLiquid_i` é depositado no `LendingPool`:

```
excess_i  =  balanceOf(pair)_i  −  targetLiquid_i   (se positivo)
```

O estado (`reserve_i -= excess`, `supplied_i += excess`) é atualizado **após** o `supply` externo retornar, dentro do contexto protegido pelo `nonReentrant` da função chamadora.

#### `_ensureLiquidity` — resgatando liquidez antes de pagar

Antes de transferir tokens para o destinatário de um `swap` ou `burn`, o `Pair` verifica se o saldo físico cobre o valor de saída. Se não cobrir, tenta sacar o déficit do `LendingPool`:

```solidity
uint256 got = balanceOf(pair)_after − balanceOf(pair)_before;
```

O delta é medido fisicamente (não confiando no valor nominal solicitado), pois pools baseados em shares podem entregar `actualAmount ≤ requested` por arredondamento de índice.

#### Comportamento em alta utilização (falha graciosa)

Se o lending pool estiver com utilização muito alta e não conseguir honrar o saque:

- **`swap`** — reverte com `InsufficientLiquidity`. O pool **não trava**: o caller simplesmente tenta mais tarde ou reduz o tamanho do swap.
- **`burn`** — reverte com `LendingWithdrawFailed`. Os LP tokens do usuário continuam intactos.
- **`setLendingPool`** — reverte com `CannotRecall` se não conseguir resgatar todo o principal antes de trocar de pool.

O pool nunca entra em estado inconsistente: a invariante `totalReserve == físico + supplied` é preservada mesmo nos reverts.

#### Segurança: delta-measurement vs nominal

O `LendingPool` real usa shares com acréscimo de juros (`supplyIndex`). O `withdraw(token, amount)` entrega `floor(shares × supplyIndex / WAD) ≤ amount`. Sem a medição por delta, o `supplied_i` poderia ficar com saldo fictício (divergindo da realidade). O padrão adotado:

```solidity
uint256 before = IERC20(token).balanceOf(address(this));
ILendingPool(pool).withdraw(token, needed);
uint256 got = IERC20(token).balanceOf(address(this)) - before;
// usa `got`, não `needed`
```

Isso torna o `Pair` robusto a qualquer implementação de lending pool, independente do modelo de arredondamento.

#### Achado de auditoria H-1 (encontrado e corrigido)

A auditoria final encontrou um **High**: o `Pair` rastreava `supplied0/1` como um cache
estático do principal varrido para o `LendingPool`, mas o pool credita shares que crescem
via `supplyIndex` (juros) — então o cache divergia do saldo real, causando yield que nunca
chegava aos LPs e risco de revert em saques grandes. Fix: eliminado o cache estático,
substituído por uma leitura **ao vivo** via `_suppliedBalance(token)` →
`ILendingPool.supplyBalanceOf(address(this), token)`, validada por um teste dedicado contra
um `LendingPool` real (com juros de verdade, não o mock 1:1). Detalhes completos —
mecanismo, exploit passo a passo e verificação — em `docs/security-audit-final.md`.

---

Construído como continuação dos estudos de web3 (o projeto anterior foi um
[livro de visitas on-chain](https://github.com/viniciusandradedev0/web3-guestbook)).
