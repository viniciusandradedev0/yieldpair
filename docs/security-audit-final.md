# YieldPair — Auditoria de Segurança Final (Sistema Integrado)

- **Data:** 2026-06-20
- **Escopo:** AMM (Pair/Factory/Router/AmmLibrary) + Oracle (MockOracle) + Lending (LendingPool) + TestToken + integração AMM↔Lending, revisão leve do `script/Deploy.s.sol`.
- **Metodologia:** skill `defi-security-checklist` (todas as 8 seções) + skill `lending-math`, aplicada ao sistema como um todo (não por fase isolada).
- **Commit auditado:** branch `desenvolvimento` (HEAD `70e3765`).
- **Re-auditoria focada (2026-06-20):** H-1 foi CORRIGIDO e re-verificado. Ver §3 (H-1 RESOLVIDO) e a nota de re-auditoria ao final do Sumário Executivo.
- **Alvo de deploy:** Sepolia testnet, projeto de portfólio single-owner (sem timelock/multisig).

---

## 1. Sumário Executivo

### Contagem por severidade

| Severidade | Qtd | Achados |
|-----------|-----|---------|
| Critical  | 0   | — |
| High      | 0   | — (H-1 RESOLVIDO em 2026-06-20 — ver §3) |
| Medium    | 3   | M-1 (`skim` pode quebrar contabilidade da integração), M-2 (Factory sem transfer/renounce de owner, sem 2-step), M-3 (`setLendingPool` pode brickar troca de pool via `CannotRecall`) |
| Low       | 4   | L-1 (`_ensureLiquidity` parcial deixa swap revertido mas estado já mutado em outros tokens), L-2 (reservas do oracle/markets dessincronizadas travam HF), L-3 (cast `uint112(excess/got)` sem checagem), L-4 (TWAP spot manipulável — fora de escopo lending mas exposto a consumidores) |
| Info      | 5   | I-1..I-5 (TestToken mint aberto, MockOracle single-owner, createPair permissionless, flash-swap não implementado, reserveFactor/reserves sem withdraw) |

### Veredito geral

**APTO para Sepolia testnet**, condicionado a:
- ~~documentar H-1 como limitação conhecida~~ — **H-1 RESOLVIDO em 2026-06-20**: o Pair agora lê o saldo supplied AO VIVO via `ILendingPool.supplyBalanceOf`, então o invariante `totalReserve == físico + supplied` volta a valer mesmo com `supplyIndex` crescendo (ver §3);
- reconhecer explicitamente as classes fora de escopo (abaixo).

Nenhum achado permite **sacar/emprestar mais do que o colateral/saldo do próprio usuário** dentro do `LendingPool` — os caminhos de `withdraw`, `borrow`, `burn` e `removeLiquidity` foram verificados e estão protegidos (ver Seção 4, cenários 1–7). Não há achado Critical. O H-1 (que era uma falha de **contabilidade da integração** — rendimento estranhado / possível reversão de swap, nunca roubo de fundos de usuários) foi **RESOLVIDO em 2026-06-20** (ver §3); não restam achados High.

### Fora de escopo (decisão consciente — testnet/portfólio)

- **Flash loans multi-protocolo** e manipulação de spot AMM por flash loan: o lending **não** lê spot do AMM; usa `MockOracle` (owner-only). Documentado no próprio código.
- **Governança / timelock / multisig:** projeto single-owner por design. Risco de chave de owner aceito.
- **MEV / front-running / sandwich:** mitigação via `amountOutMin`/`deadline` no Router é suficiente para o nível do projeto; proteção MEV avançada fora de escopo.
- **Auditoria mainnet-grade externa:** não aplicável a testnet de portfólio.
- **Tokens fee-on-transfer / rebasing / ERC777 com hooks:** explicitamente NÃO suportados (documentado em `IPair`). TestToken é ERC20 padrão sem hooks.

---

### Nota de re-auditoria focada — 2026-06-20

Re-auditoria direcionada à correção do H-1 (não uma re-auditoria completa). Resultado:

- **H-1: RESOLVIDO na raiz.** Os campos de storage `supplied0`/`supplied1` foram eliminados de `Pair.sol`; introduziu-se `_suppliedBalance(token)` (`Pair.sol:629-632`) que lê AO VIVO `ILendingPool.supplyBalanceOf(address(this), token)`. Todas as antigas leituras passaram a usar esse helper; as mutações `supplied_i += excess` / `supplied_i -= got` / `supplied_i = 0` foram removidas (as de `reserve_i` físico foram mantidas). Sem cache estático, não há mais o que dessincronizar. **CONFIRMED.**
- **Reentrância / view confiável:** `supplyBalanceOf` → `_supplyBalanceOf` (`LendingPool.sol:553-559`) é `view` puro (`supplyShares * supplyIndex / WAD`), não chama oráculo nem muta estado → o STATICCALL no cálculo de k não reentra. `nonReentrant` mantido em `mint`/`swap`/`burn`/`skim`/`sync`. A leitura final de `_suppliedBalance` em `_finalizeSwap` ocorre DEPOIS de recall+transfer, refletindo estado coerente (físico+supplied conservado no `withdraw`); flash-swap continua não implementado, então não há ponto de read-only reentrancy para terceiros. **CONFIRMED seguro.**
- **k-check:** `supplyBalanceOf` arredonda DOWN (a favor do pool) e aparece simetricamente no snapshot e na medição final → não pode ACEITAR swap que decresça k; no máximo é mais estrito (seguro). Crescimento de `supplyIndex` entre snapshot e medição (via `accrueInterest` dentro do `withdraw`) só ADICIONA reserva ao pool (juro legítimo aos LPs), nunca decresce k. **CONFIRMED seguro.**
- **Oracle/DoS:** `supplyBalanceOf` NÃO lê preço → o DoS de oráculo (L-2) não atinge a leitura supplied do Pair. `getReserves()` passa a depender de `lendingPool.supplyBalanceOf` não reverter (I-6, informativo).
- **Regressão:** CEI, solvência do LendingPool, `totalReserve == físico + supplied` e k-não-decresce permanecem válidos; o invariante de integração agora vale TAMBÉM com juros reais (era o cerne do H-1). **Suite: 92 testes, 0 falhas** (`forge test --summary`), incluindo o novo `test/unit/IntegrationRealLendingPool.t.sol` (1/1) e os 2 invariantes de integração (12800 calls cada, 0 reverts).
- **Novos achados da correção:** nenhum Critical/High/Medium. Ampliação de L-3 (cast `uint112(supplyBalanceOf)` em `Pair.sol:631` agora sobre saldo acumulado, truncamento teórico acima de 2^112 — fora de escopo testnet) e I-6 (dependência de `getReserves()` em `supplyBalanceOf` não reverter).

---

## 2. Resposta direta aos 7 cenários (sim/não + linha)

### Cenário 1 — É possível sacar/emprestar MAIS do que o saldo/colateral do próprio usuário?

**NÃO** (em todos os caminhos verificados — CONFIRMED):

- **`LendingPool.withdraw`** — `LendingPool.sol:286` `if (amount > userBalance) revert InsufficientCash();` limita ao saldo do usuário; `LendingPool.sol:294` `if (shares > userShares) shares = userShares;` impede queimar mais shares do que possui; `LendingPool.sol:300` `if (balanceOf(this) < actualAmount) revert InsufficientCash()` garante caixa; `LendingPool.sol:310-312` checa HF se houver dívida. Multi-tx no mesmo bloco: cada `withdraw` recomputa `userBalance` a partir de `supplyShares` já decrementado em `:303`, então não há replay de saldo.
- **`LendingPool.borrow`** — `LendingPool.sol:340` checa caixa; `LendingPool.sol:363` `if (healthFactor(msg.sender) < WAD) revert Undercollateralized();` impede empréstimo acima do colateral. CEI: estado mutado antes do transfer (`:343-360`), HF antes do transfer (`:363`), transfer por último (`:366`).
- **`Pair.burn`** — `Pair.sol:263` `liquidity = balanceOf(address(this))` lê apenas o LP efetivamente transferido; `Pair.sol:268-269` rateia pro-rata por `totalSupply`, arredonda para baixo. Impossível sacar mais que a fração do supply.
- **`Router.removeLiquidity`** — `Router.sol:116` puxa o LP do `msg.sender` antes de `burn`; o burn opera sobre o LP recebido. Sem custódia residual (`Router` invariante).
- **Dust grind:** todas as divisões arredondam a favor do pool (debt ROUND UP `:456`, supply ROUND DOWN `:558`, seize ROUND UP `:601`). `supply` rejeita `shares == 0` (`:257`) e `withdraw` rejeita `amount == 0`. Não há caminho onde o arredondamento repetido credite valor ao usuário.

### Cenário 2 — Drenar Pair ou LendingPool além da contabilidade?

- **Doação direta de tokens para inflar reserves/shares:** **NÃO** no Pair (CONFIRMED). `mint`/`burn`/`swap` usam `reserve0/reserve1` armazenados, não `balanceOf` cru para o denominador de share; `MINIMUM_LIQUIDITY` é travado em `DEAD` no primeiro mint (`Pair.sol:221`), eliminando inflação de primeiro-depositante. Doação só vira "presente" aos LPs (resgatável por `skim`, `Pair.sol:380`).
  - **No LendingPool:** **NÃO** para inflar share — primeiro depósito ancora `shares == amount` (`:251`) e `supplyIndex` em WAD; `supply` rejeita `shares==0` (`:257`). Doação direta de token ao pool aumenta `cash` e **reduz** `util` (favorece o pool), não credita shares a ninguém.
- **Flash loan dentro do mesmo tx:** flash-swap NÃO implementado (`Pair.sol:338`, `data` ignorado); LendingPool não tem flashLoan. Sem vetor.
- **Reentrância cross-contract Pair↔LendingPool:** **NÃO** (CONFIRMED). `mint`/`swap`/`burn` têm `nonReentrant` (`Pair.sol:209,314,258`); `supply`/`withdraw`/`borrow`/`repay`/`liquidate` têm `nonReentrant` (`LendingPool.sol:237,277,329,375,412`). Mesmo que `_sweepExcess`/`_ensureLiquidity` mutem estado após a chamada externa, o guard impede reentrada. **Nota 2026-06-20:** o STATICCALL a `supplyBalanceOf` introduzido pela correção do H-1 é `view` puro (não lê oráculo, não muta) e não abre vetor de reentrância; ver Nota de re-auditoria no §1. H-1 RESOLVIDO.
- **Manipulação do MockOracle por não-owner:** **NÃO** — `setPrice` é `onlyOwner` (`MockOracle.sol:32`).

### Cenário 3 — healthFactor pode parecer saudável sem ser?

**NÃO via doação/timing** (CONFIRMED):
- HF lê preço de oracle externo (`LendingPool.sol:496`), não spot AMM → imune a flash loan de preço.
- `accrueInterest` é chamado FIRST em todo caminho mutante (`:239,279,331,377,414-415`), e `healthFactor` usa `debtOf` que arredonda a dívida para CIMA (`:456`) e colateral para BAIXO (`:501-503`). Ordem conservadora.
- Doação de token ao pool **não** afeta HF: HF usa `supplyShares * supplyIndex` (`:558`), não `balanceOf`. Doação não cria shares.
- **Ressalva (SUSPECTED, baixo):** se o owner não setar preço de um market listado, `healthFactor` reverte (`:496`, comentário `:482-483`) — isso **trava** `withdraw`/`borrow`/`liquidate` de qualquer usuário com posição (DoS), não infla HF. Ver L-2.

### Cenário 4 — Liquidator pode lucrar de forma não intencional?

**NÃO** (CONFIRMED):
- Self-liquidation bloqueada: `LendingPool.sol:418` `if (borrower == msg.sender) revert SelfLiquidation();`
- Liquidar posição saudável bloqueado: `LendingPool.sol:419` `if (healthFactor(borrower) >= WAD) revert HealthyPosition();`
- `seizeAmount > colateral disponível` impossível: `_computeSeize` capa em `borrowerCollateral` (`LendingPool.sol:591`) e `_applySeize` capa em `borrowerShares` (`LendingPool.sol:605`).
- Close factor: `LendingPool.sol:425` limita `repayAmount` a 50% da dívida.
- Anti-death-spiral: `listMarket` exige `collateralFactor * 1.08 < WAD` (`LendingPool.sol:149`), garantindo que cada liquidação melhora (não piora) o HF.

### Cenário 5 — Acesso administrativo (pior caso)

Dentro do esperado para single-owner de portfólio (CONFIRMED), com ressalvas:
- **`Factory.owner`** (`Factory.sol:16,33`): pode chamar `setPairLendingPool` (`:69`) → aponta o Pair para um LendingPool arbitrário/malicioso. Pior caso: um pool malicioso poderia se recusar a devolver fundos ou consumi-los. Mitigação parcial: `setLendingPool` faz `_recallAll` do pool ANTIGO antes de trocar (`Pair.sol:162`). **Não há transferOwnership nem renounce** (M-2) e owner não é OZ Ownable.
- **`MockOracle.owner`** (`MockOracle.sol:32`): `setPrice` arbitrário. Pior caso: setar preço de colateral muito alto (criar bad debt) ou muito baixo (forçar liquidações). Esperado e documentado como testnet-only (`MockOracle.sol:9-13`).
- **`LendingPool.owner`** (`LendingPool.sol:131,147`): só `listMarket`. Não pode mexer em fundos de usuários, sacar reserves, nem mudar `collateralFactor` depois (não há setter). `listMarket` malicioso só adiciona markets; não afeta markets existentes. Reservas (`totalReserves`) acumulam mas **não há função para o owner sacá-las** (I-5) — conservador.

### Cenário 6 — Overflow/underflow uint112 e índices/shares

- **uint112 reserves do Pair:** checado em `_update` (`Pair.sol:434`) `if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert Overflow();`. CONFIRMED protegido para reserve físico.
  - **L-3 (SUSPECTED):** `_sweepExcess` (`Pair.sol:531,534`) e `_ensureLiquidity` (`Pair.sol:563-567`) fazem `uint112(excess)`/`uint112(got)` sem checagem isolada. `excess`/`got` derivam de balances ≤ uint112, então cabem; mas `supplied0 += uint112(excess)` poderia em teoria estourar uint112 se `reserve0 + supplied0` (o total) exceder uint112 — porém o total nunca é checado isoladamente, só o físico em `_update`. Em valores extremos (perto de 2^112) o `supplied0 += ` poderia reverter. Impacto: DoS, não roubo.
- **Índices/shares do LendingPool:** `borrowIndex`/`supplyIndex` são uint256, crescem multiplicativamente. Em horizontes/utilização extremos `m.supplyIndex += (m.supplyIndex * toSuppliers) / m.totalSupplied` (`:215`) e `borrowIndex += borrowIndex * interestFactor / WAD` (`:210`) podem em teoria estourar uint256 só com índices astronômicos (séculos a 100% util). Não explorável na prática. `accrueInterest` usa checked math (reverte em vez de corromper). CONFIRMED sem underflow; overflow só em cenário irreal → DoS.

### Cenário 7 — Reentrância: nonReentrant em tudo que move valor + CEI nos caminhos de erro

**SIM, coberto** (CONFIRMED):
- Todas as funções que movem valor têm `nonReentrant`: ver Cenário 2.
- CEI nos caminhos de revert: em `LendingPool`, o HF check (`:311,363`) ocorre ANTES do transfer; reverte sem ter transferido. `_applyRepay`/`_applySeize` mutam estado antes do `safeTransferFrom` final.
- **Ressalva (L-1):** em `Pair.swap`, se `amount0Out > 0` e `amount1Out > 0` e o segundo `_ensureLiquidity` falhar, o primeiro `safeTransfer` (`Pair.sol:331`) já ocorreu antes do revert do segundo (`:334`). Como toda a tx reverte, o transfer é desfeito — não há perda. CONFIRMED seguro (revert atômico), mas a ordem transfer-antes-de-checar-o-segundo-token é frágil estilisticamente.

---

## 3. Achados detalhados

### H-1 [RESOLVIDO 2026-06-20] — Integração Pair↔LendingPool: `supplied_i` rastreava PRINCIPAL, mas o pool credita SHARES com juros → rendimento estranhado / possível reversão de saque

> **STATUS: RESOLVIDO em 2026-06-20.** A correção eliminou os campos de storage `supplied0`/`supplied1` e introduziu o helper privado `_suppliedBalance(token)` (`Pair.sol:629-632`), que lê o saldo AO VIVO via `ILendingPool.supplyBalanceOf(address(this), token)` — refletindo principal + juros acumulados sem cache estático. As mutações `supplied_i += excess` (`_sweepExcess`), `supplied_i -= got` (`_ensureLiquidity`) e `supplied_i = 0` (`_recallAll`) foram removidas; as mutações de `reserve_i` físico foram mantidas. `_recallAll` (`Pair.sol:594-595,602`) agora saca o saldo vivo (`s0 = _suppliedBalance(token0)`) e exige `got0 >= s0`, recuperando também o juro (não mais órfão). O `MockLendingPool.supplyBalanceOf` foi corrigido de `return 0` para `return deposited[token]` (`test/mocks/MockLendingPool.sol:103-105`). **Verificação:** novo teste de regressão `test/unit/IntegrationRealLendingPool.t.sol` (`test_realLendingPool_yieldReachesPairAndSurvivesRecall`) wira o Pair a um `LendingPool` REAL com juros, cria utilização via borrower terceiro, avança 180 dias, e prova: (Assert 1) o saldo vivo do Pair cresce; (Assert 2/3) `getReserves()`/`suppliedReserves()` refletem o crescimento; (Assert 4) um `burn` de 99% que precisa recall ALÉM do principal varrido NÃO reverte — o modo de falha exato do H-1 — e entrega o juro ao LP; (Assert 5) `_recallAll` recupera principal+juro integral. Suite completa: **92 testes, 0 falhas**. As linhas ofensoras abaixo (`Pair.sol:531`, `:566`) não existem mais no código corrigido.

- **Arquivos:** `Pair.sol:111-115` (`supplied0/supplied1`), `Pair.sol:526-535` (`_sweepExcess`), `Pair.sol:559-571` (`_ensureLiquidity`), `Pair.sol:582-615` (`_recallAll`); contra `LendingPool.sol:553-558` (`_supplyBalanceOf` = shares * supplyIndex).
- **Severidade:** High (contabilidade/integração). Não é roubo de fundos de usuário.
- **CONFIRMED** (mecanismo) / o gatilho exato depende de `supplyIndex > WAD`, i.e. de juros acumulados — os testes de integração usam `MockLendingPool` que **não acumula juros** (`test/mocks/MockLendingPool.sol:28`), então este caminho nunca foi exercido contra o pool real.
- **Mecanismo:** O Pair guarda `supplied0/1` como **principal de tokens depositados**, não como shares. O `LendingPool` credita ao Pair `supplyShares[pair][token]` e, conforme `accrueInterest` roda, `supplyIndex` cresce, de modo que o saldo real do Pair no pool (`shares * supplyIndex / WAD`) fica **maior** que `supplied_i`.
  - Linha ofensora (recall): `Pair.sol:566` `supplied0 -= uint112(got);`
  - Linha ofensora (sweep): `Pair.sol:531` `supplied0 += uint112(excess);`
- **Exploit/consequência concreta (passo a passo):**
  1. Pair faz sweep de 100 token0 → `supplied0 = 100`, `supplyShares[pair] = 100`, `supplyIndex = 1e18`.
  2. Outro usuário toma emprestado; tempo passa; `accrueInterest` cresce `supplyIndex` para `1.05e18`. Saldo real do Pair no pool = 105 token0.
  3. Um swap precisa de 100 token0 físicos. `_ensureLiquidity` chama `withdraw(token0, 100)`; `got = 100`; `supplied0 = 100 - 100 = 0`.
  4. O Pair ainda possui **5 token0 de rendimento** no pool (`supplyShares[pair] > 0`), porém `supplied0 == 0` e `getReserves()` não o contabiliza → **5 token0 ficam estranhados** fora do `k` do AMM (LPs não os recebem nunca; só seriam recuperáveis por um `setLendingPool(0)` que faria `_recallAll`, mas `_recallAll` saca `supplied_i` = 0, deixando os 5 presos).
  5. **Pior variante (DoS):** se um saque precisar de `needed > supplied_i` enquanto o saldo real ≥ needed, a linha `supplied0 -= uint112(got)` faz `got` (até `needed`) exceder `supplied0` → **underflow → revert** → `_ensureLiquidity` cai no `catch`/reverte e o **swap/burn falha** (`InsufficientLiquidity`/`LendingWithdrawFailed`), apesar de existir liquidez suficiente no pool. Funds não perdidos, mas o Pair pode ficar temporariamente travado para saídas grandes.
- **Impacto:** rendimento das reservas ociosas é silenciosamente estranhado (LPs nunca o veem — contradiz o propósito "idle-liquidity yield"); e/ou saques grandes revertem. O invariante de integração `totalReserve == físico + supplied` (testado em `Integration.t.sol:101`) **só vale porque o mock não rende**; com o pool real ele falha.
- **Fix sugerido:** rastrear **shares** em vez de principal. Guardar `suppliedShares0/1` = `supplyShares[pair][token]` e, ao recall, sacar pela conversão `shares→tokens` atual; ou, mais simples para portfólio, ao recall ler `LendingPool.supplyBalanceOf(pair, token)` e ajustar `supplied_i` para o saldo real pós-saque (`supplied_i = supplyBalanceOf(pair, token)` após o withdraw) em vez de `supplied_i -= got`. Idem em `_recallAll`: sacar `supplyBalanceOf(pair, token)` (saldo real) e não `s_i` (principal). Alternativa de portfólio: usar `reserveFactor`/`bufferBps` mas **desabilitar a contagem de rendimento** documentando que o Pair só recupera principal (status quo do mock) — porém isso exige que o `supplyIndex` jamais cresça, o que não é garantível se houver tomadores.

---

### M-1 — `Pair.skim` pode ser usado após um recall parcial para extrair tokens que pertencem à contabilidade `supplied`

- **Arquivo:** `Pair.sol:380-391` (`skim`), em conjunto com `Pair.sol:559-571`.
- **Severidade:** Medium. **SUSPECTED** (dependia de H-1 produzir divergência físico vs. reserve). **Nota 2026-06-20:** com H-1 RESOLVIDO (Pair lê saldo supplied ao vivo, sem cache estático que possa divergir do físico), a janela que dava origem a este achado está fechada na raiz; permanece apenas o ponto de estilo de que `skim` envia `balanceOf - reserve0` físico, que sob tokens well-behaved é só doação recuperável.
- **Mecanismo:** `skim` envia `balanceOf - reserve0` (físico em excesso do reserve físico). Em condições normais isso é só doação. Porém, se `_ensureLiquidity` recall trouxe mais tokens físicos do que o necessário (ex.: `withdraw` share-based devolve um pouco a mais, ou a divergência de H-1), `reserve0` foi atualizado em `_update` para o balance físico esperado, e qualquer físico extra acima de `reserve0` vira "skimmable" para qualquer chamador — potencialmente drenando rendimento recuperado que deveria pertencer aos LPs.
- **Exploit concreto:** após um burn que recall 105 mas só precisava de 100 e `_update` gravou reserve=algo, um terceiro chama `skim(attacker)` e leva o excesso físico. Requer a janela criada por H-1.
- **Fix:** corrigir H-1 (contabilizar shares) elimina a janela. Adicionalmente, `skim` poderia ser restrito ou reconciliar contra `supplied_i`.

---

### M-2 — `Factory.owner` não é transferível nem renunciável; não usa OZ Ownable (sem 2-step)

- **Arquivo:** `Factory.sol:16` `address public owner;`, `:33` `owner = msg.sender;`, `:37-40` modifier custom.
- **Severidade:** Medium (operacional). **CONFIRMED**.
- **Mecanismo:** Não há `transferOwnership`/`renounceOwnership`. Se a chave do deployer for comprometida ou perdida, `setPairLendingPool` fica permanentemente sob aquela chave (ou perdido). Diferente de `MockOracle`/`LendingPool`, que usam OZ `Ownable` (com transfer).
- **Pior caso:** owner comprometido aponta todos os Pairs para um LendingPool malicioso via `setPairLendingPool` (`:69`). O `_recallAll` do pool antigo (`Pair.sol:162`) mitiga perda dos fundos já supridos, mas fundos futuros iriam ao pool malicioso.
- **Fix:** herdar de OZ `Ownable2Step`. Para portfólio single-owner é aceitável documentar o risco, mas a inconsistência com os outros contratos é um code smell.

---

### M-3 — `setLendingPool`/troca de pool pode ficar bloqueada para sempre se o pool antigo não puder devolver o principal (`CannotRecall`)

- **Arquivo:** `Pair.sol:582-615` (`_recallAll`), em especial `:594,607` `if (got0 < s0) revert CannotRecall();`
- **Severidade:** Medium. **CONFIRMED** (mecanismo).
- **Mecanismo:** Para trocar/desligar o lending pool, `_recallAll` exige sacar o principal **integral** do pool. Se o pool antigo estiver com utilização alta (tomadores não pagaram), `withdraw` reverte (`LendingPool.sol:300 InsufficientCash`), e `_recallAll` reverte com `CannotRecall`. Resultado: o Pair fica **preso** ao pool antigo até que a utilização caia — não dá para migrar nem desligar a integração numa emergência.
- **Exploit/consequência:** um tomador mantém utilização ~100% do token suprido pelo Pair; o owner não consegue executar `setPairLendingPool(pair, newPool, ...)` nem desligar (`pool=0`). DoS de governança da integração.
- **Fix:** permitir recall parcial em `setLendingPool` (sacar o que der, manter `supplied_i` residual contabilizado e migrar a posição), ou um caminho de "force detach" que aceita shortfall e o registra. Para testnet, documentar como limitação aceitável.

---

### L-1 — `swap` transfere o primeiro token antes de validar liquidez do segundo

- **Arquivo:** `Pair.sol:329-336`.
- **Severidade:** Low. **CONFIRMED seguro** (revert atômico), reportado por fragilidade de estilo.
- **Mecanismo:** Para um swap com ambos outputs > 0, `safeTransfer(token0)` (`:331`) acontece antes de `_ensureLiquidity(token1)` (`:334`). Se o token1 não puder ser provido, a tx inteira reverte, desfazendo o transfer do token0. Sem perda. Recomenda-se validar ambos `_ensureLiquidity` antes de qualquer `safeTransfer`.

---

### L-2 — HF reverte se algum market listado estiver sem preço no oracle → DoS de withdraw/borrow/liquidate

- **Arquivo:** `LendingPool.sol:496` `uint256 price = oracle.getPrice(token); // reverts PriceNotSet`, dentro do loop sobre TODOS os markets (`:491-511`).
- **Severidade:** Low. **CONFIRMED**.
- **Mecanismo:** `healthFactor` itera todos os markets listados. Se o owner listar um market e esquecer de setar o preço (ou setar 0, que delista no `MockOracle.sol:41`), **qualquer** usuário com dívida não consegue `withdraw`/`borrow`, e nenhuma posição pode ser liquidada (todas revertem em `:496`/`:581`). Não é roubo, mas trava o protocolo.
- **Fix:** `listMarket` exigir que o oracle já tenha preço; ou `healthFactor` pular markets onde o usuário não tem saldo nem dívida (evita ler preço de markets irrelevantes). A doc já avisa (`:482-483`), mas é um pé-na-armadilha operacional.

---

### L-3 — Casts `uint112(excess)`/`uint112(got)` e somas `supplied_i +=` sem checar overflow do total

- **Arquivo:** `Pair.sol:531,534` e `:563-567`.
- **Severidade:** Low. **SUSPECTED**.
- **Mecanismo:** `_update` checa só o reserve **físico** ≤ uint112 (`:434`), mas o total econômico `reserve_i + supplied_i` pode somar acima de uint112 sem checagem dedicada; `supplied0 += uint112(excess)` em valores próximos a 2^112 reverteria (checked add em uint112). Impacto: DoS em valores extremos, não roubo. TestToken permite mint arbitrário (I-1), então o cenário é alcançável em teoria num teste, mas irreal em demo.
- **Fix:** checar `reserve_i + supplied_i <= type(uint112).max` ao somar, ou documentar o teto econômico do pool.
- **Nota 2026-06-20 (correção do H-1):** o cast `uint112(...)` migrou para `_suppliedBalance` (`Pair.sol:631` `uint112(ILendingPool(lendingPool).supplyBalanceOf(...))`), agora operando sobre o saldo supplied ACUMULADO (principal + juros), não mais sobre deltas físicos limitados por `_update`. Truncamento silencioso acima de `type(uint112).max` (~5.19e15 tokens a 18 decimais) — irreal em testnet/demo, **SUSPECTED fora de escopo prático**. Mesma categoria/severidade (Low).

---

### L-4 — TWAP/`getReserves` exposto a consumidores externos é spot manipulável

- **Arquivo:** `Pair.sol:175-183`, `:447-449`.
- **Severidade:** Low (informativo p/ integradores). **CONFIRMED**.
- **Mecanismo:** `getReserves` retorna reserve total instantâneo; `price{0,1}CumulativeLast` permite TWAP, mas um consumidor que leia spot via `getReserves` está sujeito a manipulação por swap grande. O **LendingPool deste projeto não usa isso** (usa MockOracle), então não há impacto interno. Reportado para qualquer integrador futuro.
- **Fix:** nenhum necessário no escopo; documentar que consumidores devem usar a acumulação TWAP, nunca `getReserves` spot, para decisões de preço.

---

### Info

- **I-1 — `TestToken.mint` aberto a qualquer um** (`TestToken.sol:30`): intencional p/ faucet de testnet, documentado. Não usar fora de testnet.
- **I-2 — `MockOracle` single-owner sem TWAP** (`MockOracle.sol:9-13`): intencional/documentado; nunca em produção.
- **I-3 — `Factory.createPair` permissionless** (`Factory.sol:46`): padrão Uniswap V2; benigno. `setPairLendingPool` continua owner-only.
- **I-4 — Flash-swap não implementado** (`Pair.sol:338`): `data` aceito mas ignorado; elimina toda uma classe de reentrância de flash-swap. Bom.
- **I-5 — Reservas do protocolo (`totalReserves`) acumulam sem função de saque** (`LendingPool.sol:79,219`): conservador (owner não pode extrair), mas o valor fica preso. Aceitável p/ portfólio.
- **I-6 — `getReserves()` e mutators agora dependem de `lendingPool.supplyBalanceOf` não reverter** (`Pair.sol:629-632`, introduzido na correção do H-1): com `lendingPool != 0` apontando para contrato inválido, `getReserves()` (view pública) reverte. Mitigado pelo wiring que lista os markets antes de habilitar a integração; com `lendingPool == 0` retorna 0 sem chamada. Custo de gas O(1) adicional por operação. Informativo.

---

## 4. Checklist defi-security (resumo por seção)

1. **Reentrância:** OK — `nonReentrant` em todas as funções de valor; CEI respeitado; sem ERC777/hooks (tokens well-behaved). Ressalva L-1 (estilo).
2. **Oracle:** OK — lending usa MockOracle owner-only, nunca spot AMM. L-2 (DoS por preço faltante).
3. **Arredondamento:** OK — todas as divisões a favor do pool; `shares==0`/`amount==0` rejeitados; sem dust grind.
4. **First-depositor/LP inflation:** OK — `MINIMUM_LIQUIDITY` travado em `DEAD` (Pair); LendingPool ancora `shares==amount` e rejeita `shares==0`.
5. **Liquidação:** OK — sem self-liq, sem liquidar saudável, seize capado, close factor 50%, cf*bonus<1 anti-spiral.
6. **Access control/init:** OK com ressalvas — `initialize` factory-only e one-shot (`Pair.sol:145-147`); M-2 (Factory sem 2-step). Sem delegatecall/upgrade.
7. **Accounting/solvency:** OK no LendingPool isolado (invariante `cash+borrows>=supplied` mantido; juros via índice, sem loop sobre holders; eventos em toda mutação). **H-1 RESOLVIDO (2026-06-20):** o invariante de **integração** `totalReserve == físico + supplied` agora vale TAMBÉM com juros reais, pois o Pair lê o saldo supplied ao vivo (`Pair.sol:629-632`).
8. **Integração AMM↔Lending:** **H-1 RESOLVIDO (2026-06-20)** — o invariante `totalReserve == físico + supplied` agora vale com juros (leitura ao vivo); M-1 fechado na raiz pela mesma correção. Resta **M-3** (recall integral exigido em `setLendingPool` pode travar a troca de pool sob alta utilização).

---

## 5. Recomendações priorizadas

1. ~~**H-1:** mudar a contabilidade do Pair de principal para shares~~ — **CONCLUÍDO em 2026-06-20**: o Pair lê o saldo supplied ao vivo via `supplyBalanceOf` (`Pair.sol:629-632`); a tese "idle yield" funciona com o pool real (verificado por `IntegrationRealLendingPool.t.sol`).
2. **M-3:** permitir detach/migração com recall parcial.
3. ~~**M-1:** corrigir H-1 fecha a janela~~ — janela FECHADA em 2026-06-20 com a correção do H-1; opcionalmente endurecer `skim` (não bloqueante).
4. **M-2:** migrar `Factory` para `Ownable2Step` por consistência.
5. **L-2:** validar preço no `listMarket` ou pular markets irrelevantes no `healthFactor`.

Para um deploy de **demonstração** em Sepolia, o sistema é seguro contra roubo de fundos de usuários e contra os 7 cenários levantados pelo dono. **H-1 foi RESOLVIDO em 2026-06-20** (leitura ao vivo de `supplyBalanceOf`, verificada por `test/unit/IntegrationRealLendingPool.t.sol`); não restam achados High. A suite completa passa com **92 testes, 0 falhas**.
