# Auditoria de inconsistências entre PRs — janela 2026-07-08 ~16:47 → 2026-07-09 02:47 UTC

Análise de **~80 PRs mergeados na `main` nas últimas 10 horas** do sistema `autoducks`
(agentes multi-agente sobre GitHub Actions). Foco em **conflitos, gaps, redundâncias e
drift de convenção** *entre* os PRs — não em bugs isolados nem em documentação (fora de escopo
por pedido).

Como todos os PRs mergearam direto na `main` em minutos, as inconsistências **não aparecem
como conflito git**: manifestam-se como incoerência lógica no estado final da árvore. Método:
leitura do estado final + `gh pr diff` de cada PR, distribuído em 8 sub-agentes por
feature/costura, com verificação cruzada manual dos achados HIGH.

> **Nota tranquilizadora sobre o padrão "Feature-PR mergeia por último"**: os PRs `Feature #NNN`
> quase sempre mergearam **depois** de suas tasks/fixes (ex.: #575 do product às 02:39, muito
> depois dos fixes #669/#686/#695). Isso era um risco alto de sobrescrita — **foi checado e NÃO
> se materializou**: os squashes das features 575, 591, 602, 562 mantiveram as versões corrigidas
> da `main` (merges 3-way, os commits de merge não tocam os arquivos corrigidos). Bom sinal.
>
> As **12 cópias-espelho de workflow** (`.autoducks/runtimes/github-actions/*.yml` vs
> `.github/workflows/*.yml`) estão **byte-idênticas** — zero drift de espelho.

---

## Resumo por severidade

| # | Sev | Tipo | Área | Título curto |
|---|-----|------|------|--------------|
| H1 | 🔴 high | gap/conflict | resolver | Cancelamento do resolver reportado como *skip* verde (sem cancel-gate, sem `JOB_STATUS`) |
| H2 | 🔴 high | gap | resolver | Opt-outs `resolver.auto:false` e label `Resolve:off` são **código morto** |
| M1 | 🟠 med | drift | resolver | Resolver resolve o `FEATURE_NUM` **errado** (lógica inline invertida vs helper compartilhado) |
| M2 | 🟠 med | gap | max_turns | Rollout parcial: só `developer`/`fix` tratam `max_turns`; outros 5 agentes LLM rotulam como `scope-missing` |
| M3 | 🟠 med | drift | reviewer | *skip* e *cancel* limpam label/status só em `ISSUE_NUM` → segundo alvo do mirror fica preso (reabre bug #609) |
| M4 | 🟠 med | gap | hooks | Hooks de consumidor cobrem só **8 de 12** workflows (defer/product/resolver/rework de fora, todos LLM) |
| M5 | 🟠 med | drift/redund | skip | Mensagem de *skip* hardcoded do reviewer é reusada por 7 callers não-reviewer (param `reason` morto) |
| M6 | 🟠 med | gap | product | `product/post.sh` sem *cancel* nem *skip* gate |
| M7 | 🟠 med | gap | maestro | Fast-path single-task reabre o bug #674 (comentário "Running…" preso) |
| M8 | 🟠 med | drift | testes | `unit-notify-failure.sh` está **VERMELHO** na `main` (mas não está em CI) |
| L1 | 🟡 low | drift | resolver | `resolver` ausente de `status_comment::_label` → rótulo minúsculo |
| L2 | 🟡 low | gap | resolver | Label `auto-resolved` só em `setup.sh`, não em `progress_labels::ensure` → sucesso pode falhar no post |
| L3 | 🟡 low | gap | workflows | Guard de `concurrency` em `developer` mas não em `engineer`/`architect` |
| L4 | 🟡 low | redundancy | max_turns | Feature #687 reimplementou o hint que a task #697 já entregara |
| L5 | 🟡 low | redundancy | workflows | Referência morta a composite action em `autoducks-developer.yml` |
| L6 | 🟡 low | redundancy | product | Sequência de "fold duplicate" copiada entre `merge.sh` e `post.sh` |
| L7 | 🟡 low | gap | product | `workflow_dispatch mode=merge` é wiring morto (`merge.sh` nunca obtém alvo) |
| L8 | 🟡 low | drift | testes | 4 testes resetam um caminho de marker obsoleto (não-suffixado) |

**Epicentro:** os dois agentes mais novos — **`resolver` (#607)** e **`product` (#554)** — concentram
a maioria dos achados. São os menos rodados e não herdaram as convenções que os agentes antigos
já consolidaram (cancel/skip gates, resolução de feature-num, label ensure, `status_comment::_label`).

---

## Achados HIGH

### H1 — Cancelamento do resolver é reportado como *skip* verde (ou como falha de conflito)
- **Tipo:** gap / conflict
- **Arquivos:** `.autoducks/agents/resolver/post.sh:1-26` · `.github/workflows/autoducks-resolver.yml:124-158` · `.autoducks/providers/llm/claude/action.yml:126-130`
- **PRs:** #643 (cancel wired nos "seis não-reviewer") · #644 (reviewer) — **resolver ficou de fora de ambos**; agente novo do #626/#607
- **Evidência (verificado manualmente):** `resolver/post.sh` faz `source` de `notify-failure.sh` e `notify-skip.sh`, **mas não de `handle-cancellation.sh`**, e não chama `cancellation::handle`. O primeiro gate é `if [[ "${LLM_SKIPPED:-}" == "true" ]]` (linha 25). O workflow passa `LLM_SKIPPED` mas **não passa `JOB_STATUS`** (é o único agente LLM com `JOB_STATUS=0`). Além disso o provider (`action.yml:127`) seta `SKIPPED="true"` sempre que `outcome != "failure"` e não há execution file — o que **inclui o caso `cancelled`**. Nos 7 agentes com cancel-gate, `cancellation::handle` roda *antes* do skip-gate e faz `exit 0`, então "cancel vence"; o resolver não tem esse gate.
- **Impacto:** um run de resolver **cancelado** (ex.: superado pelo próprio grupo de `concurrency`) cai no skip-guard, posta o comentário **com texto do reviewer** ("Auto-review skipped… rode `/review` manualmente") numa issue de resolução de conflito, e sai **verde** → o orquestrador trata a resolução abortada como skip limpo e **pode avançar a wave**. Se o execution file existir, vira o outro extremo: `STATUS != resolved` → posta **falha de merge-conflito** espúria. Nos dois casos o cancel é classificado errado. *(Achado convergente: reportado independentemente por 2 sub-agentes.)*

### H2 — Opt-outs do auto-resolver (`resolver.auto:false`, label `Resolve:off`) são código morto
- **Tipo:** gap
- **Arquivos:** `.autoducks/agents/resolver/pre.sh:82-95` · `.github/workflows/autoducks-resolver.yml:124-128`
- **PRs:** #626/#607 · #631/#620 · #627/#617
- **Evidência (verificado manualmente):** o pre.sh gasta todo opt-out atrás de `IS_AUTOMATIC`:
  ```bash
  82  IS_AUTOMATIC=false
  83  if [[ "${EVENT_NAME:-}" == "pull_request" && "${ACTION:-}" == "synchronize" ]]; then
  84    IS_AUTOMATIC=true
  87  if [[ "$IS_AUTOMATIC" == "true" ]]; then
  88    RESOLVER_AUTO=$(jq -r '.resolver.auto // true' ...)   # desliga
  93    OPT_OUT_LABEL=$(jq ... .resolver.opt_out_label ...)   # label Resolve:off
  ```
  Mas o step **Pre-execution** do workflow só injeta `ISSUE_NUM, IS_PR, REPO, COMMENT_ID` (linhas 125-128). **`EVENT_NAME` e `ACTION` não são passados** (`EVENT_NAME` vai só para o step *Authorize*; `ACTION` não existe no workflow). O trigger real inclui `pull_request: [synchronize]`, então o auto-path acontece de fato — mas com `IS_AUTOMATIC` **sempre `false`**.
- **Impacto:** as **duas** formas documentadas de desligar o resolver autônomo (`resolver.auto: false` e o label `Resolve:off` num PR) **não fazem nada**. O resolver empurra merge-commits em branches de PR automaticamente, sem escape. É gap original (não regressão do squash 626).

---

## Achados MEDIUM

### M1 — Resolver resolve o `FEATURE_NUM` errado (lógica inline invertida vs o helper compartilhado)
- **Tipo:** drift
- **Arquivos:** `.autoducks/agents/resolver/pre.sh:148` vs `.autoducks/core/orchestration/branch-prefix.sh:51-61`
- **PRs:** #626/#607 vs #637/#634 e #645/#635
- **Evidência:** o resolver faz `FEATURE_NUM=$(grep -oiP '\bcloses\s+#\K[0-9]+' <<< "$PR_BODY" | head -1 ...)`. O helper compartilhado `resolve_feature_num_from_pr` (que defer/rework/reviewer adotaram no #635) faz o **inverso**: nome do branch primeiro e, no fallback, o **último** `Closes` (`tail -1`), com comentário explícito "prefer the LAST ref, since Maestro appends `Closes #<feature>` after every `Closes #<task>`". O resolver faz `source` do `branch-prefix.sh` (o helper está disponível) mas **não o usa**.
- **Impacto:** o resolver dispara em PRs finais de pipeline (`feature/N-…`), cujo body é `Closes #task1 … Closes #taskN Closes #feature`. `head -1` pega a **primeira task**, não a feature. A LLM recebe `design-plan.md`/`task-criteria.md` da issue errada e o `post.sh` posta o resumo (`its::comment_issue "$FEATURE_NUM"`) numa **issue de task** em vez da feature. O merge funciona; contexto e relatório vão para o lugar errado.

### M2 — `max_turns` é rollout parcial: só `developer`/`fix`; outros 5 agentes rotulam corte de turnos como `scope-missing`
- **Tipo:** gap
- **Arquivos:** `developer/post.sh:49-58`, `fix/post.sh:48-53` (tratam) vs `architect/post.sh:39`, `engineer/post.sh:53`, `reviewer/post.sh:53`, `rework/post.sh:62`, `defer/post.sh:43` (todos `scope-missing`)
- **PRs:** #659/#651 · #605 · #687
- **Evidência (verificado manualmente):** só `developer` e `fix` têm `if [[ "${LLM_ERROR_SUBTYPE:-}" == "error_max_turns" ]]` e setam `AUTODUCKS_FAIL_CATEGORY="max_turns"`. `LLM_ERROR_SUBTYPE` só é encaminhado nesses dois workflows. Os outros 5 agentes LLM, ao não produzir output (o que é exatamente o que um corte por `max_turns` causa), setam `AUTODUCKS_FAIL_CATEGORY="scope-missing"`.
- **Impacto:** quando architect/engineer/reviewer/rework/defer batem no `error_max_turns`, o usuário recebe "did not produce the expected …, re-run `/architect`" (scope-missing) em vez do hint `/run turns=<n>` + preservação de trabalho parcial — **exatamente a classe de "silent max_turns" que o #605 queria matar**, ainda viva para 5 dos 7 agentes LLM. Pode ser escopo intencional (só developer/fix têm branch de trabalho a preservar), mas é uma decisão de rollout que ficou implícita.

### M3 — Reviewer: caminhos de *skip* e *cancel* limpam label/status só em `ISSUE_NUM`, deixando o 2º alvo do mirror preso
- **Tipo:** drift (reabre o bug #609 nos paths de skip/cancel)
- **Arquivos:** `.autoducks/agents/reviewer/pre.sh:38-40` (skip) · `.autoducks/agents/reviewer/post.sh:35` + `.autoducks/core/feedback/handle-cancellation.sh:17-31` (cancel)
- **PRs:** #609/#612/#613 (pinta ambos issue+PR) vs #536/#513 (`skip_review`) e #615/#644 (cancel)
- **Evidência:** o mirror é pintado nos **dois** alvos (`pre.sh:102-106`, loop sobre `REVIEW_TARGETS`), mas:
  - `skip_review` (pre.sh:38-40) só desfaz `ISSUE_NUM`: `status_comment::finish "$ISSUE_NUM"` + `progress_labels::abort "$ISSUE_NUM" "Review:reviewing"`. É chamado em diff vazio (pre.sh:168) e PR não-`OPEN` (pre.sh:171), **depois** do 2º alvo já ter sido pintado.
  - `cancellation::handle "$ISSUE_NUM" ...` (post.sh:35) só toca o `issue_id` único; o helper nunca recebe o set `REVIEW_TARGETS`.
- **Impacto:** nos casos comuns de re-run (diff vazio, `/review` em PR já mergeado/fechado, ou cancelamento manual) o **segundo alvo** do mirror (a issue-feature quando disparado do PR, ou o PR quando disparado da issue) fica com `Review:reviewing` **preso para sempre** e o status congelado em "running…". O check-run é concluído (merge não trava), mas o estado exibido fica errado — o sintoma #609 que o mirror existia para eliminar.

### M4 — Hooks de consumidor cobrem só 8 de 12 workflows; os 4 excluídos são todos agentes LLM
- **Tipo:** gap
- **Arquivos:** `autoducks-defer.yml`, `-product.yml`, `-resolver.yml`, `-rework.yml` (ambas as cópias) — sem hook steps
- **PRs:** #566 · #577/#592
- **Evidência:** o #577 adicionou hook steps (`AUTODUCKS_STAGE: pre|post`) a 8 workflows (architect, engineer, developer, reviewer, fix, close, revert, maestro). Grep pelo contrato de hook retorna 0 em defer/product/resolver/rework. Mas o glob `autoducks-*.yml` que o install espelha casa **12** arquivos. Ironia: 3 dos incluídos (close, revert, maestro) **não** invocam LLM, enquanto os 4 excluídos **todos** invocam — incluindo `product`, o agente de entrada idea→issues. A premissa "8 workflows" do design subcontou o conjunto real (12).
- **Impacto:** consumidores não conseguem injetar setup/teardown (browser install, seed de DB, notificações custom) em torno de defer, product, resolver ou rework.

### M5 — Mensagem de *skip* hardcoded do reviewer é reusada por 7 callers não-reviewer (param `reason` morto)
- **Tipo:** drift / redundancy
- **Arquivos:** `.autoducks/core/feedback/notify-skip.sh:3-13`; callers `architect/post.sh:31`, `engineer:35`, `defer:29`, `rework:41`, `developer:42`, `fix:39`, `resolver:26`
- **PRs:** #678 (helper) · #680 · #681
- **Evidência:** `notify_skip()` aceita `reason="${2:-}"` mas **nunca o usa**; o corpo é string fixa: "ℹ️ **Auto-review skipped.** … run `/review` manually … the auto-review will work again once the workflow changes land…". Todos os callers não-reviewer chamam `notify_skip "$ISSUE_NUM"` sem reason.
- **Impacto:** quando um run de developer/fix/architect/engineer/defer/rework/resolver é *validation-skipped*, o usuário recebe "run `/review` manually" — agente errado, remediação errada. O parâmetro `reason` que corrigiria isso está morto.

### M6 — `product/post.sh` não tem *cancel* nem *skip* gate apesar de invocar a LLM
- **Tipo:** gap
- **Arquivos:** `.autoducks/agents/product/post.sh:1-8` · `.github/workflows/autoducks-product.yml:146,156`
- **PRs:** #643/#644 (escopo cancel) · #679-#681 (escopo skip) — product ficou de fora de todos
- **Evidência:** o product yml roda o provider (linha 146) e o post.sh roda em `if: always()`, mas o post.sh só faz `source` de `notify-failure.sh` (sem notify-skip, sem handle-cancellation) e o yml não passa `JOB_STATUS` nem `LLM_SKIPPED`.
- **Impacto:** um triage **cancelado** cai no caminho normal de reconcile/`narrate_fail` e é reportado como **falha de triage**. Menor que o resolver (product é sweep não-bloqueante, rodando em issues/schedule e não em PRs que editam workflow, então o skip é pouco aplicável); o cancel-gate ausente é o gap real.

### M7 — Fast-path single-task do Maestro reabre o bug #674 (comentário "Running…" preso)
- **Tipo:** gap (regride #674/#668)
- **Arquivos:** `.autoducks/agents/maestro/run.sh:128-138`
- **PRs:** #594/602 regride #674/675 e #668/670
- **Evidência:** `report()` (que resolve o comentário de status transiente) está atrás de `prevent_duplicate_dispatch` **sem branch `else`**:
  ```bash
  if prevent_duplicate_dispatch "$FEATURE" "$FEATURE_BRANCH"; then
    git::dispatch_workflow ...
    report "**Single-task plan** — dispatched the Developer..."
  fi          # <- sem else; report() nunca roda no caminho duplicado
  ```
  Num `/execute` re-rodado enquanto o PR de task do developer (base = feature branch) ainda está aberto-não-mergeado, `FEATURE_DONE==false` **e** `prevent_duplicate_dispatch` retorna 1 → o "Running…" iniciado em `run.sh:32` nunca vira ✅/⚠️. A Phase 8 (multi-wave) é segura porque `report "$SUMMARY"` (run.sh:346) roda incondicionalmente; a assimetria é o bug.
- **Impacto:** exatamente o sintoma que o #674 fechou — comentário de status do bot preso em "Running…" para sempre — reaberto no caminho single-task.

### M8 — `unit-notify-failure.sh` está VERMELHO na `main`
- **Tipo:** drift (PR posterior contradiz teste travado por PR anterior)
- **Arquivos:** `test/unit-notify-failure.sh:152` vs `.autoducks/core/feedback/notify-failure.sh:73-76`
- **PRs:** teste do #491/#455; refactor do #647/#615 quebrou a assertion sem atualizá-la
- **Evidência (verificado manualmente):** `bash test/unit-notify-failure.sh` → **Pass: 33 / Fail: 1**. O teste espera `re-run '/architect' or '/engineer'` para scope-missing, mas com `AUTODUCKS_AGENT` unset o `case` cai no `*)` → `retry="re-run $(autoducks_command_for fix)"`.
- **Impacto:** a suíte falha na `main`. Em produção todo setter de `scope-missing` tem um branch por-agente nomeado, então o default `*) /fix` é inalcançável em runtime — é defeito de **teste stale**, não de comportamento. ⚠️ **Porém**: estes unit tests **não estão wired em nenhum workflow de CI**, então nada trava por causa disso (o que é, em si, uma observação sistêmica — ver abaixo).

---

## Achados LOW

### L1 — `resolver` ausente de `status_comment::_label` → rótulo minúsculo
- **Tipo:** drift · **Arquivo:** `.autoducks/core/feedback/status-comment.sh:27-42` · **PRs:** #638/#636, #626/#607
- O `case` mapeia architect…reviewer, rework, defer, merge para labels capitalizados, mas não tem arm `resolver)` → cai no `*)` → `resolver` minúsculo. Cosmético.

### L2 — Label `auto-resolved` só em `setup.sh`, não em `progress_labels::ensure`
- **Tipo:** gap · **Arquivos:** `resolver/post.sh:60`, `progress-labels.sh:6-32`, `scripts/setup.sh:83` · **PRs:** #624/#618
- `post.sh` faz `its::add_label "$PR_NUM" "auto-resolved"` (`gh` erra se o label não existe). Os `Resolve:*` estão no `progress_labels::ensure` idempotente; `auto-resolved` está **só** no setup.sh. Em repo onde o setup não rodou/o label foi apagado, uma resolução **bem-sucedida** falha no post.sh **depois** do merge-commit já ter sido empurrado — run verde vira vermelho.

### L3 — Guard de `concurrency` em `developer` mas não em `engineer`/`architect`
- **Tipo:** gap · **Arquivos:** `autoducks-developer.yml:44-46` vs `-engineer.yml`, `-architect.yml` (sem bloco) · **PRs:** guard do developer + #695/#608/#626
- Os três compartilham a mesma superfície de dispatch duplo (`issue_comment` + `workflow_dispatch` com `issue_number`), mas só o developer ganhou o backstop de serialização por-issue no nível do workflow. Pode ser deliberado (developer é dispatchado por 2 caminhos do maestro), por isso LOW — mas é assimetria.

### L4 — Feature #687 reimplementou o hint que a task #697 já entregara
- **Tipo:** redundancy · **Arquivo:** `notify-failure.sh:20-26` e `:85` · **PRs:** #697/701 depois #687/703
- `git blame` mostra que todas as linhas do `_max_turns_retry_budget` e do hint `/execute turns=` pertencem ao commit **posterior** (#703), i.e. o #703 reescreveu o mesmo que o #701 já fizera. Sem regressão (doubling/cap/fallback batem com os testes); só esforço duplicado.

### L5 — Referência morta a composite action em `autoducks-developer.yml`
- **Tipo:** redundancy · **Arquivo:** `.github/workflows/autoducks-developer.yml` (~linha 152)
- Step `uses: ./.github/actions/autoducks/developer-post` guardado por `hashFiles(...) != ''`, mas o dir `.github/actions/autoducks` **não existe** → guard sempre falso, step nunca roda. O post real é o `run: bash .autoducks/agents/developer/post.sh` adjacente. Sem efeito hoje; se o dir fosse criado, post.sh rodaria 2×.

### L6 — Sequência de "fold duplicate" copiada entre `merge.sh` e `post.sh`
- **Tipo:** redundancy · **Arquivos:** `product/merge.sh:78-89`, `product/post.sh:250-266` · **PRs:** #575/#585/#586
- Ambos inlinam o mesmo fold de 4 passos (create label Duplicate → add_label → close_issue not_planned → link_sub_issue → comentário). Ambos gated em `delivery_phase::started`, consistentes hoje. Risco só de drift futuro se o protocolo mudar num lado só.

### L7 — `workflow_dispatch mode=merge` é wiring morto (`merge.sh` nunca obtém alvo)
- **Tipo:** gap · **Arquivos:** `autoducks-product.yml:8-15,76-81,159-178`, `product/merge.sh:27-37` · **PRs:** #575/#585/#574
- O `authorize.sh` honra `mode=merge` via dispatch, mas `merge.sh` deriva o alvo **só do corpo do comentário** (`grep '/merge #N'`). Num `workflow_dispatch` não há comentário → `TARGET` vazio → "❌ No target issue found"; `exit 0`. O caminho `/merge #N` por comentário funciona; só o entrypoint de dispatch que o authorize sanciona é inalcançável.

### L8 — 4 testes resetam um caminho de marker obsoleto
- **Tipo:** drift · **Arquivos:** `test/unit-architect-guard.sh:47`, `unit-engineer-dor.sh:113`, `unit-developer-idempotency.sh:177`, `unit-verb-idempotency.sh:203` · **PRs:** #598/#610, #674
- Produção agora escreve `/tmp/autoducks-status-comment-id.${issue}` (per-target), mas estes 4 ainda fazem `rm -f /tmp/autoducks-status-comment-id` (sem sufixo) — caminho que nada mais escreve. Latente (mascarado pelo self-clear do `status_comment::start`).

---

## Observações sistêmicas

1. **`resolver` e `product` são os pontos fracos.** Como agentes mais novos (#607, #554), não herdaram
   convenções que os antigos consolidaram: cancel-gate, skip-message correto, resolução de feature-num,
   `progress_labels::ensure` de todos os labels, `status_comment::_label`. Achados H1, H2, M1, M6, L1, L2, L7
   concentram-se neles. Recomendação: um "checklist de conformidade de agente" aplicado ao criar agente novo
   evitaria toda essa classe.

2. **Os unit tests não estão em CI.** M8 (teste vermelho na main) só é detectável rodando localmente. Vários
   PRs desta janela adicionaram/atualizaram testes (#543, #581, #582, #580, #614, #655, #700…) que **não
   gateiam merge**. Isso explica como um teste pôde ficar vermelho e como os gaps de rollout parcial (M2, M4, M6)
   passaram — nada os obrigava a serem uniformes.

3. **O provider conflata `cancelled` com `skipped`** (`claude/action.yml:127`: `SKIPPED=true` sempre que
   `outcome != failure` e sem execution file). A única coisa que separa cancel de skip nos agentes é a
   **ordem dos gates** (cancel antes de skip). Essa ordem é *load-bearing* e não está protegida por teste —
   é o que torna H1 (resolver sem cancel-gate) perigoso e não só cosmético.

4. **Rollouts "N de M" implícitos.** Vários PRs entregaram um comportamento para um subconjunto de agentes
   ("seis não-reviewer", "os 8 workflows", "developer & fix") sem registrar por que os demais ficaram de fora.
   Onde a exclusão é intencional (JOB_STATUS nos 7 LLM, MAX_TURNS em developer/fix) está coerente; onde é
   acidental (hooks 8/12, cancel/skip no resolver/product, max_turns em 5 agentes) virou gap. A checagem "todos
   ou nenhum, e se for subconjunto, por quê?" pegaria isso.

---

### Cobertura da auditoria

8 sub-agentes cobriram: (A) drift de espelho dos 12 workflows, (B) plumbing de falha/marker/max_turns,
(C) coerência do reviewer, (D) resolver + rework/defer, (E) product/triage, (F) customização/hooks/install,
(G) gating de skip/cancel em post.sh, (H) maestro/orquestrador/status-comment. Achados HIGH e os MED
verificáveis (M2, M8) re-verificados manualmente. **Documentação (`*.md`) fora de escopo** por pedido —
alguns achados podem ter contraparte de doc a atualizar (ex.: opt-outs do resolver documentados mas mortos).
