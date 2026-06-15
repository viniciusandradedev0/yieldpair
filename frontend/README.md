# YieldPair — Frontend

O dapp (React 19 + Vite + TypeScript + wagmi + viem + RainbowKit + Tailwind 4)
será criado na **Fase 4**, depois que os contratos (AMM → LendingPool →
integração) estiverem prontos e testados.

Planejado:
- Swap (exact-in / exact-out) com slippage e deadline
- Add / remove liquidez
- Supply / borrow / repay no LendingPool
- Painel de **health factor** e do **yield acumulado** dos LPs

Os ABIs serão sincronizados de `../contracts/out/` e os endereços de
`../deployments/sepolia.json`.
