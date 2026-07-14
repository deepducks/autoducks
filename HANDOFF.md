# Handoff — Git Submodules em branches específicas (checkout/push recursivo no GitHub Actions)

> Doc de handoff entre sessões. Escopo: como fazer checkout e push recursivo de submodules
> apontando para branches específicas em GitHub Actions, e por que a resolução do vínculo
> parent→submodule é por **SHA**, não por branch. Conclusões validadas empiricamente (scripts no fim).

## Perguntas originais

1. No GitHub Actions dá pra fazer checkout recursivo de submodules em **branches específicas**?
2. Se durante a action eu altero esses submodules, dá pra **"pushar recursivamente para essas branches"**?
3. Então basicamente são checkouts e pushes a mais, como "repos dentro de repos"?
4. Se eu pusho pra uma branch do submodule e atualizo o parent com o ponteiro (HEAD SHA), na próxima action isso quebra — a menos que eu especifique a branch também?

## TL;DR

- Submodule é um **repo Git independente**; o parent guarda apenas um **gitlink = SHA fixo**, nunca a branch.
- Checkout em branch específica **é possível, mas não sai de graça** pelo `actions/checkout`: ele deixa o submodule no SHA fixado, em **detached HEAD**, e faz fetch raso (só a ref default).
- Push recursivo **existe** (`--recurse-submodules=on-demand`) mas tem gotchas sérios; em CI o caminho robusto é `git submodule foreach ... git push origin HEAD:<branch>`.
- **Resposta à pergunta 4: não quebra e não precisa especificar branch.** O ponteiro resolve por SHA. O que quebra é o SHA ficar **inalcançável** no remote (branch deletada/force-push + gc).

---

## 1. Checkout recursivo em branches específicas

`actions/checkout` com `submodules: recursive` roda o equivalente a `git submodule update --init --recursive`:
deixa cada submodule **no commit fixado, em detached HEAD**, com fetch raso — as outras branches do submodule
nem aparecem localmente. Para ficar numa branch de fato, precisa de passos extras:

```yaml
- uses: actions/checkout@v4
  with:
    submodules: recursive
    token: ${{ secrets.PAT }}    # PAT/GitHub App se submodules forem repos privados separados
    fetch-depth: 0               # evita "Needed a single revision" quando usar --remote

- name: Colocar submodules nas branches
  run: |
    git submodule foreach '
      git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
      git fetch origin
      git checkout minha-branch
    '
```

Alternativa declarativa: `branch = <nome>` por submodule no `.gitmodules` + `git submodule update --remote`.
**Armadilha:** `--remote` **ignora o SHA fixado** e pula pro topo da branch — o pin vira decorativo.
Em pipeline determinística, isso normalmente é indesejado.

## 2. Push recursivo para as branches

Mecanismo nativo: `git push --recurse-submodules=on-demand` empurra os submodules antes do parent. Dois gotchas:

- **(a) Detached HEAD:** o `on-demand` não sabe pra qual branch empurrar se o submodule está detached. Precisa ter feito checkout numa branch local antes.
- **(b) Nomes divergentes:** confirmado até v2.51.2 — se a branch do parent e a do submodule têm nomes diferentes, quebra com `src refspec '...' must name a ref`. Ele assume nomes iguais.

Caminho robusto em CI (blinda dos dois):

```yaml
- name: Commit + push recursivo
  run: |
    git submodule foreach '
      if ! git diff --quiet; then
        git add -A
        git commit -m "ci: update"
        git push origin HEAD:minha-branch   # HEAD:<branch> ignora detached e nome divergente
      fi
    '
    git add -A
    git commit -m "ci: bump submodules"
    git push origin HEAD:branch-do-super
```

**Ordem obrigatória:** push nos submodules **primeiro**, depois commit+push do parent. Senão o parent
aponta para um SHA que ninguém consegue buscar (`fatal: reference is not a tree` no clone).

## 3. Auth (gotcha silencioso)

O `GITHUB_TOKEN` default só tem acesso ao repo **atual**. Se os submodules são repos separados, o **push
neles falha** com esse token. Precisa de **PAT** ou **GitHub App token** com escopo nesses repos, e configurar
a credencial de push por submodule. O `token:` do checkout resolve o pull, não necessariamente o push.

## 4. Resolução por SHA, não por branch (o ponto contraintuitivo)

O parent guarda `submodule.<nome>.path` e `submodule.<nome>.url` — **nenhum `branch=`** por padrão.
Na action seguinte, `submodule update` faz fetch e dá checkout **no SHA exato**, em detached HEAD, sem
consultar em que branch o commit está. Branch é rótulo humano; o Git resolve por objeto.

**O que de fato precisa ser verdade:** o commit tem que estar **alcançável no remote do submodule**.
Se a branch que sustentava o SHA é deletada/force-pushada e o gc roda, o commit vira órfão e o próximo
clone morre com `not our ref ... Direct fetching of that commit failed` — mesmo com o ponteiro do parent intacto.

O papel da branch é **indireto**: manter o commit vivo (protegido de gc). O vínculo parent→submodule nunca foi pela branch.

### Dois eixos que costumam ser confundidos

| Objetivo | Precisa da branch? | O que realmente importa |
|---|---|---|
| Resolver o ponteiro (checkout na próxima action) | Não | SHA alcançável no remote |
| Continuar commitando no submodule | Sim | sair do detached HEAD para uma branch local |
| Manter o SHA vivo a longo prazo | Sim (indireto) | branch/tag segurando o commit contra gc |

---

## Gotchas consolidados

| # | Gotcha | Efeito | Mitigação |
|---|---|---|---|
| 1 | Checkout deixa detached HEAD no SHA fixado | Não dá pra commitar/pushar direto | `git submodule foreach ... git checkout <branch>` |
| 2 | Fetch raso só traz a ref default | Outras branches ausentes | `fetch-depth: 0` + refspec `+refs/heads/*:refs/remotes/origin/*` |
| 3 | `--remote` ignora o pin | Submodule anda sozinho pro topo da branch | Não usar `--remote` em pipeline determinística |
| 4 | `on-demand` + nomes de branch divergentes | `src refspec must name a ref` | `git push origin HEAD:<branch>` explícito |
| 5 | `GITHUB_TOKEN` só acessa o repo atual | Push no submodule falha | PAT / GitHub App token com escopo |
| 6 | Ordem push errada (parent antes do submodule) | `reference is not a tree` no clone | Submodules primeiro, parent depois |
| 7 | Force-push/delete da branch + gc | SHA fixado vira órfão → `not our ref` | Nunca destruir a branch/tag que sustenta um SHA já fixado |

## Relevância p/ Monoswarm

A armadilha real num monorepo com N submodules e branches por-projeto **não** é "esquecer de especificar a
branch". É: **(a)** ordem de push determinística (submodule → parent), e **(b)** retenção — não force-pushar/
deletar a branch que sustenta um SHA já fixado no parent. Ambos foram os erros que apareceram nos testes abaixo.

---

## Script de reprodução (offline, remotes via `file://`)

Roda os dois experimentos: (A) ponteiro resolve por SHA sem branch; (B) órfão quebra o clone.

```bash
#!/usr/bin/env bash
set -e
rm -rf /tmp/submod-test && mkdir -p /tmp/submod-test && cd /tmp/submod-test
git config --global user.email t@t.com; git config --global user.name t
git config --global protocol.file.allow always
git config --global init.defaultBranch main

git init -q --bare sub.git
git init -q --bare parent.git

# submodule: main + branch feature
git clone -q sub.git sub && cd sub
echo v1 > f.txt && git add . && git commit -qm "main c1" && git push -q origin main
git checkout -q -b feature
echo v2 > f.txt && git add . && git commit -qm "feature c1" && git push -q origin feature
FEATURE_SHA=$(git rev-parse HEAD); cd ..

# parent aponta pro SHA da feature (NUNCA grava o nome da branch)
git clone -q parent.git parent && cd parent
git submodule add -q ../sub.git sub
git -C sub fetch -q origin feature
git -C sub checkout -q "$FEATURE_SHA"          # detached no SHA
git add sub && git commit -qm "pin sub -> feature sha" && git push -q origin main
cd ..
git -C parent config -f .gitmodules --list | grep sub   # sem branch=

# (A) próxima action: clone fresco, sem citar 'feature' em lugar nenhum
git clone -q --recurse-submodules parent.git fresh
test "$(git -C fresh/sub rev-parse HEAD)" = "$FEATURE_SHA" && echo "A: resolveu por SHA, OK"

# (B) órfão: deleta a branch + gc, o SHA fica inalcançável
git -C sub push -q origin --delete feature
( cd sub.git && git gc -q --prune=now )
rm -rf fresh2
git clone -q --recurse-submodules parent.git fresh2 || echo "B: FALHOU (not our ref) — ponteiro intacto, alvo sumiu"
```

Saídas observadas: (A) `SIM` — HEAD do submodule == SHA fixado, em `HEAD detached`.
(B) `fatal: remote error: upload-pack: not our ref <sha>` / `Direct fetching of that commit failed`.