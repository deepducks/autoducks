#!/usr/bin/env bash
# Unit tests for the triage sweep's backlog filter.
#
# Pipeline-created tasks are not backlog. The Engineer files them with the
# `Task` label and native type, but the sweep's `already_classified` predicate
# only accepts feature/bug, so every task looked untriaged and got classified.
# Caught on a live staging run: a task was filed at 20:28:13 and the sweep added
# `Priority:Low` and `Feature` to it 48s later, leaving an issue that was both
# Task and Feature. On any repo with the schedule on, that happens to every task
# the Engineer creates.
#
# Run: bash test/unit-product-skips-tasks.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# The real filter, lifted from product/pre.sh so the test exercises production
# code rather than a restatement of it.
FILTER=$(sed -n "/^  RAW_ISSUES=\$(echo \"\$RAW_ISSUES\" | jq -c '/,/^  )]')\$/p" \
  "$REPO_ROOT/.autoducks/agents/product/pre.sh" \
  | sed -e "1s/.*jq -c '//" -e "\$s/')\$//")

if [[ -z "$FILTER" ]]; then
  echo "  ❌ could not extract the sweep filter from product/pre.sh"
  exit 1
fi

apply() { jq -c "$FILTER"; }

BACKLOG='[
  {"number": 1, "type": "Feature", "labels": ["Feature"],            "title": "a real feature"},
  {"number": 2, "type": "",        "labels": [],                     "title": "an untriaged request"},
  {"number": 3, "type": "Task",    "labels": ["Task"],               "title": "engineer-created task"},
  {"number": 4, "type": "",        "labels": ["Task"],               "title": "task by label only"},
  {"number": 5, "type": "Task",    "labels": [],                     "title": "task by native type only"},
  {"number": 6, "type": "Bug",     "labels": ["Bug"],                "title": "a bug report"},
  {"number": 7, "type": "",        "labels": ["task"],               "title": "lowercase task label"}
]'

kept=$(echo "$BACKLOG" | apply | jq -r '[.[].number] | join(",")')

echo "── sweep backlog filter ──"

for n in 3 4 5 7; do
  case ",$kept," in
    *",$n,"*) fail "issue #$n (a task) reached triage — the sweep would re-classify it" ;;
    *) pass "issue #$n (a task) excluded from the sweep" ;;
  esac
done

for n in 1 2 6; do
  case ",$kept," in
    *",$n,"*) pass "issue #$n still reaches triage" ;;
    *) fail "issue #$n was dropped — the filter is eating real backlog" ;;
  esac
done

# The regression in one line: without the filter, everything reaches triage.
unfiltered=$(echo "$BACKLOG" | jq -r 'length')
kept_count=$(echo "$BACKLOG" | apply | jq -r 'length')
if [[ "$kept_count" -lt "$unfiltered" ]]; then
  pass "filter is load-bearing ($kept_count of $unfiltered issues kept)"
else
  fail "filter dropped nothing — it is not doing anything"
fi

# Empty/missing fields must not throw: `its::list_issues` output has been seen
# without a `type` key at all, and a filter that errors takes the whole sweep
# down with it.
if echo '[{"number": 9, "title": "no type or labels keys"}]' | apply >/dev/null 2>&1; then
  pass "tolerates issues with no type/labels keys"
else
  fail "filter throws on an issue missing type/labels — would abort the sweep"
fi

echo ""
echo "═══ product-skips-tasks: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]]
