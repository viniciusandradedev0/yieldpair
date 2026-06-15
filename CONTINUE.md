# Continuar o YieldPair numa sessão nova

Abra o `yieldpair` no VSCode, inicie o Claude Code, e **cole o prompt abaixo**.
Antes (opcional), rode as verificações para confirmar que o ambiente está pronto.

---

## 1. Verificações rápidas (opcional — o prompt também pede isso)

```bash
ls ~/.claude/agents/            # deve listar: defi-architect, solidity-engineer,
                                # foundry-test-engineer, defi-security-auditor, web3-frontend
ls ~/.claude/skills/            # deve listar: amm-math, defi-security-checklist, foundry-workflow
forge --version                 # Foundry instalado (1.7.x)
cd ~/Projetos/yieldpair && git log --oneline -3 && git status --short
```

Tudo isso deve passar. Os agentes/skills são **user-level**, então funcionam em
qualquer janela sem reconfigurar.

---

## 2. PROMPT para colar na sessão nova (copie tudo abaixo)

```
Estou retomando o projeto YieldPair (DEX AMM + lending integrado, EulerSwap-style,
Foundry + React, testnet/portfólio). O contexto completo está em ROADMAP.md e no
plano /home/guest/.claude/plans/rippling-coalescing-kay.md.

Antes de começar, verifique o ambiente e me reporte:
1. `forge --version` e `cd contracts && forge build` (deve passar).
2. `git log --oneline -5` e `git status` (branch `desenvolvimento`).
3. `forge test --summary` (39/39 devem passar nos unit/fuzz já existentes).

Estamos na Fase 1 (AMM), Passo 1.4 (testes), EM ANDAMENTO — ver "Status atual" e a
seção do Passo 1.4 em ROADMAP.md para detalhes do que já foi feito (unit + fuzz
prontos, bugfix do MINIMUM_LIQUIDITY/address(0) já aplicado em Pair.sol).

Falta SOMENTE:
- Continuar o agente `foundry-test-engineer` (agentId a6b7cb100d85787c2, ou um novo se
  o anterior não estiver mais disponível) para criar `test/invariant/Amm.t.sol`
  (StdInvariant usando o handler já escrito em
  `test/invariant/handlers/AmmHandler.sol`), rodar `forge test -vv` 100% verde e
  `forge coverage` para tokens/ e amm/.
- Depois: Passo 1.5 — `defi-security-auditor` audita os contratos do AMM
  (checklist defi-security-checklist).
- Depois: Passo 1.6 — commit + push final da Fase 1 (pedir confirmação antes do push).

NÃO avance para a Fase 2 sem eu confirmar. Priorize correção sobre velocidade.
```

---

## 3. Onde estamos

- ✅ Setup completo (agents, skills, scaffold, repo no GitHub, CI).
- ✅ Fase 1, Passos 1.1–1.3: TestToken, interfaces (IPair/IFactory/IRouter),
  AmmLibrary, Pair, Factory, Router — `forge build` verde, comitados em
  `desenvolvimento`.
- 🔄 Fase 1, Passo 1.4 (testes): unit (31) + fuzz (8) passando (39/39). Falta o
  invariant test (`test/invariant/Amm.t.sol`, handler já escrito) + `forge coverage`.
- ⏭️ Depois: Passo 1.5 (auditoria) → Passo 1.6 (commit/push final da Fase 1).

Status detalhado e o plano por agente: **[ROADMAP.md](./ROADMAP.md)** e
`/home/guest/.claude/plans/rippling-coalescing-kay.md`.
