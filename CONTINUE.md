# Continuar o YieldPair numa sessão nova

Abra o `yieldpair` no VSCode, inicie o Claude Code, e **cole o prompt abaixo**.

---

## 1. Verificações rápidas (opcional)

```bash
ls ~/.claude/agents/            # defi-architect, solidity-engineer, foundry-test-engineer,
                                # defi-security-auditor, web3-frontend
ls ~/.claude/skills/            # amm-math, defi-security-checklist, foundry-workflow, lending-math
forge --version                 # 1.7.x
cd ~/Projetos/yieldpair && git log --oneline -3 && git status --short
cd contracts && forge test --summary   # 42/42 devem passar
```

---

## 2. PROMPT para colar na sessão nova

```
Estou retomando o projeto YieldPair (DEX AMM + lending integrado, EulerSwap-style,
Foundry + React, testnet/portfólio). O contexto completo está em ROADMAP.md e no
plano /home/guest/.claude/plans/rippling-coalescing-kay.md.

Antes de começar, verifique o ambiente:
1. `forge --version` e `cd contracts && forge build` (deve passar).
2. `git log --oneline -5` e `git status` (branch `desenvolvimento`).
3. `forge test --summary` (42/42 devem passar: 8 fuzz + 3 invariant + 31 unit).

Estamos na Fase 2 (LendingPool), Passo 2.1 — `solidity-engineer`.

O design aprovado está em `docs/lending-design.md` (leia antes de implementar).
Skills disponíveis: `lending-math` (math de juros/HF/liquidação) e
`defi-security-checklist` (CEI, oracle, rounding).

Dispare o agente `solidity-engineer` para implementar (conforme docs/lending-design.md):
- `contracts/src/interfaces/IPriceOracle.sol`
- `contracts/src/interfaces/ILendingPool.sol`
- `contracts/src/oracle/MockOracle.sol`
- `contracts/src/lending/LendingPool.sol`

Checkpoint do agente: `forge build` verde + `forge fmt`. Sem testes ainda.

Depois (aguardar confirmação entre cada passo):
- Passo 2.2: `foundry-test-engineer` escreve testes (unit/fuzz/invariant do lending)
- Passo 2.3: `defi-security-auditor` audita os contratos do lending
- Passo 2.4: commit + push da Fase 2 (pedir confirmação antes do push)

NÃO avance para a Fase 3 sem confirmação. Priorize correção sobre velocidade.
```

---

## 3. Onde estamos

- ✅ Fase 1 completa: AMM (Pair, Factory, Router, AmmLibrary) — 42/42 testes, auditoria limpa, commitada.
  - Commit: `ef725d4` — feat(amm): conclui Fase 1 — invariant tests + auditoria
- ✅ Fase 2, Passo 2.0: design do LendingPool aprovado pelo `defi-architect` → `docs/lending-design.md`
  - Nova skill criada: `~/.claude/skills/lending-math/SKILL.md`
- 🔄 Fase 2, Passo 2.1: implementação do LendingPool ← **PRÓXIMO**

Status detalhado: **[ROADMAP.md](./ROADMAP.md)** e `docs/lending-design.md`.
