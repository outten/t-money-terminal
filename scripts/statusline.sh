#!/usr/bin/env bash
# Claude Code status line script.
# Receives the session JSON object via stdin; prints one line to stdout.
#
# Fields used:
#   .model.display_name                 – current model name (e.g. "Opus 4.7 1M")
#   .context_window.total_input_tokens  – cumulative input tokens this session
#   .context_window.total_output_tokens – cumulative output tokens this session
#
# Cost is estimated client-side because the status-line JSON doesn't carry
# a running dollar total. Rates below match published per-model standard
# pricing as of mid-2026. CAVEATS:
#   - 1M-context tier (input > 200K tokens) has premium pricing roughly 2×
#     the base rate; not modelled here. Expect a modest undercount on
#     long-context Opus sessions.
#   - Cache reads ($0.30/M) and cache writes ($3.75/M for Opus equivalent)
#     are lumped into total_input_tokens by the harness, so they're priced
#     at the input rate — also a modest undercount on cache-heavy sessions.
#   - For the actual billed amount, run `/cost` in Claude Code.

input=$(cat)

model=$(echo "$input"    | jq -r '.model.display_name // "unknown"')
in_tok=$(echo "$input"   | jq -r '.context_window.total_input_tokens  // 0')
out_tok=$(echo "$input"  | jq -r '.context_window.total_output_tokens // 0')

# ---- pick rates by model family ----
# USD per 1 000 000 tokens. Default is Opus rates (highest of the three)
# so unknown models err on the side of overcounting, not undercounting.
case "$(echo "$model" | tr '[:upper:]' '[:lower:]')" in
  *opus*)   INPUT_CPM=15.00;  OUTPUT_CPM=75.00 ;;
  *sonnet*) INPUT_CPM=3.00;   OUTPUT_CPM=15.00 ;;
  *haiku*)  INPUT_CPM=0.80;   OUTPUT_CPM=4.00  ;;
  *)        INPUT_CPM=15.00;  OUTPUT_CPM=75.00 ;;
esac

# ---- format token counts as e.g. "12.3k" or "1.2M" ----
fmt_tok() {
  local n=$1
  if   [ "$n" -ge 1000000 ]; then
    printf "%.1fM" "$(echo "scale=4; $n/1000000" | bc)"
  elif [ "$n" -ge 1000 ]; then
    printf "%.1fk" "$(echo "scale=4; $n/1000" | bc)"
  else
    printf "%d" "$n"
  fi
}

in_fmt=$(fmt_tok "$in_tok")
out_fmt=$(fmt_tok "$out_tok")

# ---- estimate cost ----
cost=$(echo "scale=6; ($in_tok * $INPUT_CPM + $out_tok * $OUTPUT_CPM) / 1000000" | bc)
cost_fmt=$(printf "\$%.2f" "$cost")

printf "%s  |  %s in / %s out  |  %s\n" "$model" "$in_fmt" "$out_fmt" "$cost_fmt"
