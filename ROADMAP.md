# YieldPair — Roadmap & Status (documento de continuidade)

> Este arquivo permite retomar o projeto em **qualquer sessão/janela**. Se você
> abriu o `yieldpair` numa janela nova e o Claude não tem o histórico da conversa,
> **comece lendo este arquivo** — ele diz onde paramos e qual o próximo passo.

## Como continuar numa janela/sessão nova

1. Os **agentes e skills são user-level** (`~/.claude/agents`, `~/.claude/skills`)
   → estão disponíveis em qualquer projeto, inclusive aqui. Não precisa recriar.
2. **Foundry** já instalado (`forge --version` → 1.7.1, no PATH).
3. Para o frontend (Fase 4): Node 22+ via `source ~/.nvm/nvm.sh && nvm use v26.3.0`.
4. Leia a seção "Status atual" abaixo e execute o "Próximo passo".

## Agentes especialistas (invocar via Task / subagent)

| Agente | Quando usar |
|--------|-------------|
| `defi-architect` | Desenhar/validar mecânica antes de codar (read-only) |
| `solidity-engineer` | Escrever/refatorar contratos Solidity (Foundry) |
| `foundry-test-engineer` | Escrever testes unit/fuzz/invariant |
| `defi-security-auditor` | Revisar contratos antes de deploy (read-only) |
| `web3-frontend` | Construir o dapp (React/wagmi) — Fase 4 |

Skills de referência: `amm-math`, `defi-security-checklist`, `foundry-workflow`.

## Princípio de execução

**Passo a passo, um agente por vez, com checkpoint humano entre os passos.**
Nunca pular fase. Cada contrato: escrever → `forge build` → testar → auditar →
commitar. Projeto complexo: preferimos lento e correto a rápido e quebrado.

---

## Status atual

- [x] **Setup**: 5 agents + 3 skills (user-level); monorepo Foundry + frontend;
      repo no GitHub (https://github.com/viniciusandradedev0/yieldpair);
      submódulos forge-std + OpenZeppelin; CI (forge fmt/build/test).
- [x] **Fase 1 — AMM**: completa (TestToken, IPair/IFactory/IRouter, AmmLibrary, Pair,
      Factory, Router). Testada e auditada.
- [x] **Fase 2 — LendingPool**: completa (MockOracle, LendingPool: supply/borrow/
      withdraw/repay/liquidate). Testada e auditada.
- [x] **Fase 3 — Integração Pair↔LendingPool**: completa (idle-reserve sweeping via
      `_sweepExcess`/`_ensureLiquidity`, `totalReserve = físico + supplied`). Testada
      e auditada.
- [x] **Auditoria final do sistema integrado**: executada em 2026-06-20
      (`docs/security-audit-final.md`). Achado **H-1 (High)** — `Pair` cacheava
      `supplied0/1` como principal estático, divergindo do saldo real do LendingPool
      conforme `supplyIndex` cresce com juros (yield estranhado / risco de revert em
      saques grandes) — foi **encontrado e CORRIGIDO** (commit `ab3ea59`): leitura
      ao vivo via `_suppliedBalance(token)` → `ILendingPool.supplyBalanceOf`, validada
      por `test/unit/IntegrationRealLendingPool.t.sol` contra um LendingPool real (não
      mock). Re-auditoria: 0 Critical, 0 High; restam apenas Low/Info residuais.
- [x] **Suite de testes**: **92/92 passando, 11 suites, 0 falhas** (`forge test`).
- 🔄 **Fase 4 — Deploy + Frontend**:
  - [x] Passo 4.1 — script de deploy (`contracts/script/Deploy.s.sol`), testado em
        dry-run e em broadcast real.
  - [x] Passo 4.2 — **deploy real na Sepolia, concluído**: os 7 contratos (mUSDC,
        mWETH, Factory, Router, Pair, MockOracle, LendingPool) deployados e
        **verificados no Etherscan**; endereços em `deployments/sepolia.json`; cenário
        demo seedado (liquidez + posição de empréstimo com HF=2.5), confirmado
        on-chain via `cast call`. Ver tabela de endereços no `README.md`.
  - [x] Passo 4.3 — **scaffold do frontend concluído** (`web3-frontend`): dapp Vite +
        React + TypeScript + wagmi v2 + viem + RainbowKit + Tailwind em `frontend/`;
        telas Swap / Liquidez / Lending / Painel (Health Factor + yield + `suppliedReserves`);
        ABIs gerados de `contracts/out/` via `npm run gen:abis`, endereços de
        `deployments/sepolia.json`. `npm run build` + `npm run lint` verdes (37/37 testes
        de lógica pura no Vitest).
  - [ ] Passo 4.4 — deploy do frontend (Vercel) + commit/push final ⏳ **PENDENTE ← AQUI**.

---

## Fase 1 — AMM (Uniswap V2-style): passo a passo por agente

> Skills de apoio: `amm-math` (fórmulas), `foundry-workflow` (comandos),
> `defi-security-checklist` (revisão).

**Passo 1.1 — `solidity-engineer`: tokens + interfaces + biblioteca**
- `src/tokens/TestToken.sol` (ERC20 OZ, `mint` aberto p/ testnet).
- `src/interfaces/{IPair,IFactory,IRouter}.sol`.
- `src/amm/libraries/AmmLibrary.sol` (`quote`, `getAmountOut`, `getAmountIn`, `sqrt`).
- Checkpoint: `forge build` verde.

**Passo 1.2 — `solidity-engineer`: o pool `Pair`**
- `src/amm/Pair.sol` = pool `x*y=k` **e** LP token (herda OZ ERC20).
  `mint`/`burn`/`swap` sobre saldo recebido; `MINIMUM_LIQUIDITY=1000` queimado no
  1º mint; fee 0.30% via k-check; `nonReentrant`; acumuladores TWAP.
- Checkpoint: `forge build` verde.

**Passo 1.3 — `solidity-engineer`: `Factory` + `Router`**
- `src/amm/Factory.sol` (`createPair`, `getPair`).
- `src/amm/Router.sol` (`addLiquidity`, `removeLiquidity`,
  `swapExactTokensForTokens`; deadline + slippage min).
- Checkpoint: `forge build` verde + `forge fmt`.

**Passo 1.4 — `foundry-test-engineer`: testes** ✅ **CONCLUÍDO**
- Unit: mint/burn/swap, fee, MINIMUM_LIQUIDITY, deadline/slippage do Router. ✅
  (`test/unit/{Pair,Factory,Router}.t.sol` — 39 testes passando)
- Fuzz: `getAmountOut` nunca > reserva; round-trip `getAmountIn∘getAmountOut` atinge
  o alvo. ✅ (`test/fuzz/AmmLibrary.t.sol` — 8 testes, 256 runs)
- Invariant: k nunca decresce; `totalSupply >= MINIMUM_LIQUIDITY`; solvência
  (balances ≥ reserves). ✅ (`test/invariant/Amm.t.sol` — 3 invariants, 256 runs,
  12.800 calls cada; handler em `test/invariant/handlers/AmmHandler.sol`)
- **Bugfix**: `Pair.mint` chamava `_mint(address(0), MINIMUM_LIQUIDITY)` — OZ v5
  reverte para `address(0)`. Corrigido: queima para `address(0xdEaD)` (DEAD).
- Cobertura (forge coverage): Factory 100% | Pair 82% | Router 88% | AmmLibrary 80%
- Checkpoint: `forge test` 42/42 verde + `forge coverage` executado. ✅

**Passo 1.5 — `defi-security-auditor`: auditoria da Fase 1** ✅ **CONCLUÍDO**
- Checklist executado contra todos os contratos AMM (Pair, Factory, Router, AmmLibrary).
- Resultado: 0 Critical, 0 High. 2 Low (sem perda de fundos), 10 Informational.
- Itens Low/Info aplicados: NatSpec IFactory corrigido (CREATE não CREATE2); premissa
  "no fee-on-transfer tokens" documentada no IPair; `amountOutMin == 0` rejeitado no
  Router para erro imediato; `AmmHandler.swap` atualizado para `amountOutMin = 1`.
- Checkpoint: sem findings High/Critical em aberto. ✅

**Passo 1.6 — commit + push da Fase 1.** ✅ **CONCLUÍDO**

---

## Fase 2 — LendingPool

**Passo 2.0 — `defi-architect`: validar mecânica** ✅ **CONCLUÍDO**
Design completo em `docs/lending-design.md`. Decisões: multi-ativo único, juros
linear por segundo (base 2%+slope 20%), HF 1e18-scaled, closeFactor 50%,
liquidationBonus 1.08, MockOracle (1e18=$1), 10 invariantes para os testes.

**Passo 2.1 — `solidity-engineer`: oráculo + LendingPool** ✅ **CONCLUÍDO**
Implementado conforme `docs/lending-design.md`:
- `src/interfaces/IPriceOracle.sol`
- `src/interfaces/ILendingPool.sol`
- `src/oracle/MockOracle.sol`
- `src/lending/LendingPool.sol`
Checkpoint: `forge build` verde + `forge fmt`. ✅

**Passo 2.2 — `foundry-test-engineer`: testes do lending** ✅ **CONCLUÍDO**
**Passo 2.3 — `defi-security-auditor`: auditoria do lending** ✅ **CONCLUÍDO**
**Passo 2.4 — commit + push da Fase 2** ✅ **CONCLUÍDO**

---

## Fase 3 — Integração ✅ **CONCLUÍDA**
`Pair` com `lendingPool` + `bufferBps`; `totalReserve = saldo + supplied`;
`_sweepExcess`/`_ensureLiquidity`. Invariantes de integração + trade-off de
liquidez documentado no README. Testada (unit + invariant) e auditada junto com
o sistema completo (ver `docs/security-audit-final.md`).

---

## Auditoria final do sistema integrado ✅ **CONCLUÍDA (com correção de High)**

Executada em 2026-06-20 sobre o sistema completo (AMM + Oracle + Lending +
integração + revisão leve do script de deploy). Relatório completo em
`docs/security-audit-final.md`.

- **H-1 (High) — encontrado e CORRIGIDO**: `Pair.sol` guardava `supplied0`/`supplied1`
  como cache estático do principal varrido para o `LendingPool`. Como o `LendingPool`
  credita `supplyShares` que crescem via `supplyIndex` (juros), o saldo real divergia
  do cache estático, causando (a) yield que nunca chegava aos LPs, (b) risco de
  underflow/revert em `_ensureLiquidity` em saques grandes, (c) yield órfão em
  `_recallAll`. **Fix** (commit `ab3ea59`): eliminado o cache estático, substituído por
  leitura ao vivo via `_suppliedBalance(token)` → `ILendingPool.supplyBalanceOf(address(this), token)`.
  Validado por um teste novo dedicado contra um `LendingPool` **real** (com juros de
  verdade, não o mock 1:1): `test/unit/IntegrationRealLendingPool.t.sol`.
- **Re-auditoria pós-fix**: 0 Critical, 0 High. Restam apenas achados Low/Info
  residuais (ex.: L-3, truncamento teórico de `uint112` acima de ~5.19e15 tokens —
  fora de escopo prático para testnet/demo) e Medium operacionais já conhecidos
  (M-2 Factory sem 2-step ownership, M-3 `setLendingPool` pode travar sob alta
  utilização). Nenhum acima de Medium.
- **Suite**: 92 testes, 0 falhas (`forge test --summary`).

---

## Fase 4 — Deploy + Frontend

**Passo 4.1 — script de deploy** ✅ **CONCLUÍDO**
- `contracts/script/Deploy.s.sol`: deploya TestToken×2, Factory, Router, Pair,
  MockOracle, LendingPool; wiring completo (`setPairLendingPool`, `listMarket`,
  `setPrice`); seed de liquidez inicial e de uma posição de empréstimo demo.
- Testado em dry-run (`forge script ... `, sem `--broadcast`) e em broadcast real.

**Passo 4.2 — deploy real na Sepolia** ✅ **CONCLUÍDO (2026-06-20)**
- Todos os 7 contratos deployados e **verificados no Etherscan** (chainId `11155111`):
  Deployer, mUSDC (`TestToken`), mWETH (`TestToken`), `Factory`, `Router`,
  `Pair` (mUSDC/mWETH), `MockOracle`, `LendingPool`.
- Endereços salvos em `deployments/sepolia.json`; tabela completa com links para o
  Etherscan está em `README.md` (seção "Deploy (Sepolia)").
- Cenário demo seedado: 3.000.000 mUSDC + 1.000 mWETH de liquidez inicial no par;
  posição de empréstimo aberta (10 mWETH de colateral, 9.000 mUSDC emprestados,
  health factor ≈ 2.5). Confirmado on-chain via `cast call` (`getReserves`,
  `suppliedReserves`, `healthFactor` todos batendo com o esperado).
- Artefatos do deploy (`contracts/script/`, `contracts/.env.example`,
  `contracts/foundry.toml`, `deployments/sepolia.json`, `contracts/broadcast/`)
  commitados e pushed em `c53cfd5`. O fix do H-1 já havia sido commitado/pushed
  separadamente (`ab3ea59`).

**Passo 4.3 — `web3-frontend`: scaffold do dapp** ✅ **CONCLUÍDO**
- Dapp em `frontend/`: Vite + React 18 + TypeScript + wagmi v2 + viem + RainbowKit 2.2
  + Tailwind 4, configurado para a Sepolia (chainId 11155111).
- ABIs gerados de `contracts/out/<Nome>.sol/<Nome>.json` via `npm run gen:abis`
  (`scripts/gen-abis.mjs`, sem deps) → `src/abis/`; endereços lidos de
  `deployments/sepolia.json` → `src/config/deployments.sepolia.ts`. Não há ABI/endereço
  redigitado à mão.
- Telas: **Swap** (slippage + deadline + price impact), **Liquidez** (add/remove +
  approvals), **Lending** (supply/withdraw/borrow/repay + `utilization`), **Painel**
  (Health Factor com cores, yield estimado, `suppliedReserves` do Pair). Faucet
  (`TestToken.mint`), UX de tx (pending/success/error + link Etherscan), banner de rede
  errada.
- Checkpoint: `npm run gen:abis` + `npm run build` + `npm run lint` verdes; 37/37 testes
  de lógica pura no Vitest (`errors`/`format`/`swap`, sem mock de wagmi). Roda contra os
  contratos já deployados na Sepolia (não precisa de novo deploy).
- `VITE_WALLETCONNECT_PROJECT_ID` fica vazio no `.env.example` (placeholder); o valor real
  é definido na Vercel no Passo 4.4. Sem ele, MetaMask/injected funcionam; só o connector
  WalletConnect (QR/mobile) fica inativo.

**Passo 4.4 — deploy do frontend (Vercel) + commit/push final** ⏳ **PENDENTE ← AQUI**
- Publicar o frontend na Vercel (framework Vite, build `npm run build`, output `dist`,
  root `frontend/`); definir `VITE_WALLETCONNECT_PROJECT_ID` (e RPC opcional) no painel.
- Atualizar o `README.md` com o link do dapp publicado.

---

## Fora de escopo (declarado)
Flash loans, governança, fees de protocolo, multi-hop complexo, auditoria de
mainnet. **Testnet only, não auditado.**
