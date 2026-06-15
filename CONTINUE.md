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
Foundry + React, testnet/portfólio). O contexto completo está em ROADMAP.md na raiz
do repositório.

Antes de começar, verifique o ambiente e me reporte:
1. `ls ~/.claude/agents` e `ls ~/.claude/skills` — confirme que os 5 agentes
   (defi-architect, solidity-engineer, foundry-test-engineer, defi-security-auditor,
   web3-frontend) e as 3 skills (amm-math, defi-security-checklist, foundry-workflow)
   estão disponíveis.
2. `forge --version` (deve ser 1.7.x) e `cd contracts && forge build` (deve passar).
3. `git log --oneline -3` e `git status`.

Depois, leia ROADMAP.md e continue a partir do "Próximo passo" (Fase 1 — AMM),
indo PASSO A PASSO, um agente por vez, com checkpoint entre cada passo:

- Passo 1.1 — invoque o agente `solidity-engineer` para criar TestToken,
  interfaces e AmmLibrary. Pare em `forge build` verde e me mostre o resultado.
- NÃO avance para o passo seguinte sem eu confirmar.

Use as skills amm-math (fórmulas) e foundry-workflow (comandos) como referência,
e defi-security-checklist na auditoria. É um projeto complexo: priorize correção
sobre velocidade, e não pule fases.
```

---

## 3. Onde estamos

- ✅ Setup completo (agents, skills, scaffold, repo no GitHub, CI).
- ⏭️ **Próximo passo: Fase 1 — AMM, Passo 1.1** (ver ROADMAP.md).

Status detalhado e o plano por agente: **[ROADMAP.md](./ROADMAP.md)**.
