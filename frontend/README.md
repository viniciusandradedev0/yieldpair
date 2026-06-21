# YieldPair — Frontend

Dapp da Fase 4 do YieldPair: Swap, Liquidez, Lending e Painel de saúde/yield,
falando diretamente com os contratos deployados na **Sepolia testnet**.

> ⚠️ Apenas testnet. Não auditado. Não use em mainnet / com fundos reais.

## Stack

| Camada | Lib | Versão |
|--------|-----|--------|
| Build | Vite | 5.4 |
| UI | React | 18.3 |
| Linguagem | TypeScript | 5.6 |
| Chain interaction | wagmi | 2.19 |
| | viem | 2.x |
| Wallet | RainbowKit | 2.2 |
| Estilo | Tailwind CSS | 4.1 |
| Testes (lógica pura) | Vitest | 3.2 |

React 18 (não 19) foi escolhido deliberadamente — ver "Decisões" abaixo.

## Setup

```bash
npm install
npm run gen:abis   # gera src/abis/*.ts e src/config/deployments.sepolia.ts
npm run build
npm run lint
npm run test
```

Para desenvolvimento local:

```bash
cp .env.example .env.local
# preencha VITE_WALLETCONNECT_PROJECT_ID (https://cloud.reown.com, grátis)
npm run dev
```

## Scripts

| Script | O que faz |
|--------|-----------|
| `npm run dev` | Vite dev server com HMR |
| `npm run build` | `tsc -b` (type-check) + `vite build` |
| `npm run lint` | ESLint |
| `npm run test` | Vitest (roda uma vez) |
| `npm run test:watch` | Vitest em modo watch |
| `npm run gen:abis` | Gera ABIs + endereços de deploy (ver abaixo) |

## `gen:abis` — de onde vêm ABIs e endereços

`scripts/gen-abis.mjs` é Node puro (zero deps) e:

1. Lê `../contracts/out/<Nome>.sol/<Nome>.json` (artifacts do `forge build`)
   para `Pair`, `Router`, `Factory`, `LendingPool`, `MockOracle`, `TestToken`,
   extrai só o campo `.abi` e escreve `src/abis/<Nome>.ts` como
   `export const <Nome>Abi = [...] as const;` — o `as const` é o que permite
   ao wagmi/viem inferir tipos de argumentos/retorno de cada função do ABI.
2. Gera `src/abis/index.ts` (barrel export).
3. Lê `../deployments/sepolia.json` e gera `src/config/deployments.sepolia.ts`
   no mesmo padrão (`as const`).

Os arquivos gerados são **committados** (não fazem parte do `.gitignore`),
porque `contracts/out/` é gitignored no repo raiz — sem isso, um build do
frontend isolado (ex.: Vercel apontando só para `frontend/`) não teria como
regenerá-los. Para resincronizar após mudanças nos contratos: rode
`forge build` em `contracts/`, depois `npm run gen:abis` aqui.

`src/config/contracts.ts` consome `deployments.sepolia.ts` e tipa os
endereços como `` `0x${string}` `` para o wagmi/viem.

## Variáveis de ambiente

| Variável | Obrigatória? | Descrição |
|----------|--------------|-----------|
| `VITE_WALLETCONNECT_PROJECT_ID` | Não (mas recomendada) | Project id do WalletConnect/Reown Cloud. Vazio não quebra o build — só desativa o connector WalletConnect (QR/mobile); MetaMask/injected continuam funcionando. Valor real é definido na Vercel no Passo 4.4. |
| `VITE_SEPOLIA_RPC_URL` | Não | RPC custom (Alchemy/Infura). Sem ela, usa o RPC público padrão do viem/wagmi para Sepolia. |

Nunca commitar `.env`/`.env.local` — apenas `.env.example` (sem segredos) vai
para o git.

## Estrutura

```
src/
  abis/             # gerado por gen:abis — ABIs tipados (as const)
  components/       # 1 componente por tela/peça de UI
  config/           # chains, wagmi config, endereços de contrato
  hooks/            # 1 hook por ação on-chain (useContractAction, useErc20, useChainGuard)
  lib/              # lógica pura testável (errors.ts, format.ts, swap.ts) + *.test.ts
  App.tsx           # layout + abas (Swap / Liquidez / Lending / Painel)
  providers.tsx     # WagmiProvider + QueryClientProvider + RainbowKitProvider
scripts/
  gen-abis.mjs      # gerador de ABIs/endereços (Node puro)
```

## Telas

- **Swap** — `swapExactTokensForTokens` com slippage configurável (0.1% /
  0.5% / 1%), `amountOutMin` derivado de `getAmountsOut`, deadline de 20 min,
  e impacto de preço estimado contra as reservas atuais do par.
- **Liquidez** — `addLiquidity` / `removeLiquidity` via Router, com o fluxo
  de aprovação ERC20 (approve → ação) explícito sempre que a allowance for
  insuficiente.
- **Lending** — `supply` / `withdraw` / `borrow` / `repay`, mostrando
  `supplyBalanceOf`, `debtOf`, `utilization` e a APR de empréstimo estimada
  por token.
- **Painel** — Health Factor (`healthFactor`, escala 1e18; trata
  `type(uint256).max` como "sem dívida"/∞ saudável; verde ≥1.5, amarelo
  1.0–1.5, vermelho <1.0) + yield estimado para suppliers
  (`utilization × borrowRatePerSecond`, anualizado) + `suppliedReserves` do
  `Pair` (liquidez ociosa rendendo no LendingPool).

Todas as telas têm um faucet embutido (`TestToken.mint`) para pegar mUSDC e
mWETH de teste.

## UX de transação

Todo write segue o ciclo **aguardando carteira → confirmando → sucesso/erro**
(`useWriteContract` + `useWaitForTransactionReceipt` — só considera a tx
concluída no receipt, nunca no envio), com link para o Etherscan Sepolia.
Erros do viem (`BaseError.shortMessage`) são mapeados para mensagens
amigáveis em `src/lib/errors.ts` (testado em `errors.test.ts`, sem mock de
wagmi/viem).

Há detecção de rede errada (`useChainGuard` + `useSwitchChain`) com um banner
fixo no topo quando a carteira não está na Sepolia.

## Decisões de design

- **React 18, não 19** — Node disponível no ambiente de build era 18.20.4;
  `create-vite` mais recente e `vitest`/`@tailwindcss/oxide` mais recentes
  exigem Node ≥20. Para manter tudo no Node 18 sem downgrades forçados em
  cascata, fixamos `tailwindcss`/`@tailwindcss/vite` em `4.1.18` (última 4.x
  com `engines: node >= 10`) e `vitest` em `3.x` (suporta Node 18; `4.x`
  exige ≥20). RainbowKit 2.2 funciona com React 18 ou 19 — não houve
  incompatibilidade real, a escolha foi puramente pela versão de Node
  disponível. Em um ambiente com Node 20+, é seguro migrar para React 19 e
  para as versões mais recentes dessas libs.
- **ABIs/endereços gerados, não commitados à mão** — `gen:abis` é a única
  fonte de verdade; nunca editar `src/abis/*.ts` ou
  `src/config/deployments.sepolia.ts` manualmente.
- **Lógica pura isolada em `src/lib/`** — `errors.ts`, `format.ts`, `swap.ts`
  não importam wagmi/viem em runtime (`errors.ts` usa apenas o tipo
  `BaseError` do viem para `instanceof`), então os testes não precisam de
  mocks de carteira/provider.
