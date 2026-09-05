#!/usr/bin/env bash
# org.sh — a live "organization self-forms to deliver a goal" run, so you can
# WATCH the budget conservation work on real models.
#
# `team` gives the goal to a Captain, which decomposes it, fans out workers
# (each carved from the root budget via `budget split`), runs a mandatory
# adversarial critic, and synthesizes. This driver just picks the model + goal,
# runs it, and dumps the budget tree so you can see how the root grant was
# subdivided and spent across the org.
#
# Needs the agent/budget/team feats installed (make feats) and either an
# OpenRouter key (~/.zish/openrouter.key) or ZISH_AGENT_BACKEND=ollama.
# SPENDS REAL TOKENS on a hosted model. Cheap flash models cost ~fractions of a cent.
#
# Usage:  ./benchmark/org.sh [model] [budget] "[goal]"
#   ./benchmark/org.sh deepseek/deepseek-v4-flash-0731 8 "Design a minimal rate limiter"
#   ZISH_AGENT_BACKEND=ollama ./benchmark/org.sh qwen3:1.7b 8 "..."
set -u

MODEL="${1:-deepseek/deepseek-v4-flash-0731}"
BUDGET="${2:-8}"
GOAL="${3:-Design a minimal token-bucket rate limiter: list the key design decisions and one gotcha to avoid.}"

FEATS="${ZISH_FEAT_PATH:-$HOME/.zish/feats}"
TEAM="$FEATS/standard/team/bin/team"
BUDGET_BIN="$FEATS/standard/budget/bin/budget"
[ -x "$TEAM" ] || { echo "team feat not installed ($TEAM) — run 'make feats'"; exit 1; }

# isolate this run's ledger so the tree dump is clean
RUN_DIR=$(mktemp -d /tmp/org-run-XXXXXX)
export ZISH_BUDGET_DIR="$RUN_DIR/budget"
mkdir -p "$ZISH_BUDGET_DIR"
export ZISH_AGENT_MODEL="$MODEL"

echo "== org run =="
echo "  model : $MODEL   backend: ${ZISH_AGENT_BACKEND:-openrouter}"
echo "  budget: $BUDGET credits"
echo "  goal  : $GOAL"
echo "-------------------------------------------------------------------"
"$TEAM" run "$BUDGET" "$GOAL"
rc=$?
echo "-------------------------------------------------------------------"
# the stderr line from `team` already printed the conservation summary; now the
# full subdivision, straight from the ledger:
root=$(ls "$ZISH_BUDGET_DIR" 2>/dev/null | head -1)
# team ids look like team-<pid>-w<i>; the root is team-<pid>
root=$(grep -oE 'team-[0-9]+' "$ZISH_BUDGET_DIR"/* 2>/dev/null | grep -oE 'team-[0-9]+$' | sort -u | head -1)
if [ -n "$root" ] && [ -x "$BUDGET_BIN" ]; then
  echo "budget subdivision (root $root):"
  "$BUDGET_BIN" tree "$root" 2>/dev/null || cat "$ZISH_BUDGET_DIR"/* 2>/dev/null
fi
rm -rf "$RUN_DIR"
exit $rc
