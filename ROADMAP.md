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
- [ ] **Fase 1 — AMM** ← **AQUI**
- [ ] Fase 2 — LendingPool
- [ ] Fase 3 — Integração (idle-reserve sweeping)
- [ ] Fase 4 — Frontend + deploy Sepolia

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

**Passo 1.4 — `foundry-test-engineer`: testes**
- Unit: mint/burn/swap, fee, MINIMUM_LIQUIDITY, deadline/slippage do Router.
- Fuzz: `getAmountOut` nunca > reserva; LP round-trip não extrai mais do que pôs.
- Invariant: `k` não decresce após swaps.
- Checkpoint: `forge test` 100% verde.

**Passo 1.5 — `defi-security-auditor`: auditoria da Fase 1**
- Rodar o `defi-security-checklist` contra os contratos.
- Corrigir findings (volta ao `solidity-engineer` se preciso).
- Checkpoint: sem findings High/Critical em aberto.

**Passo 1.6 — commit + push da Fase 1.**

---

## Fase 2 — LendingPool (resumo; detalhar ao chegar)
`supply/withdraw/borrow/repay/accrueInterest/liquidate`, juros por índice
acumulado, `healthFactor`, `IPriceOracle` + `MockOracle`. Mesma cadência de
agentes (engineer → test → auditor). Oráculo: **nunca** spot do AMM (documentar).

## Fase 3 — Integração (resumo)
`Pair` com `lendingPool` + `bufferBps`; `totalReserve = saldo + supplied`;
`_sweepExcess`/`_ensureLiquidity`. Invariantes de integração + trade-off de
liquidez documentado no README.

## Fase 4 — Frontend + deploy (resumo)
`web3-frontend`: scaffold Vite+wagmi+RainbowKit+Tailwind, UI de swap/liquidez/
lending, painel de health factor e yield. Deploy via `script/Deploy.s.sol` na
Sepolia; sync de ABIs/endereços; publicar na Vercel.

---

## Fora de escopo (declarado)
Flash loans, governança, fees de protocolo, multi-hop complexo, auditoria de
mainnet. **Testnet only, não auditado.**
