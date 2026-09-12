#!/usr/bin/env bash
# usage: ./report.sh <label>
set -u
LABEL="${1:?need a label}"
F="$HOME/lab3/loadtest/results/${LABEL}.txt"
[ -f "$F" ] || { echo "No results file: $F"; exit 1; }

TOTAL=$(wc -l < "$F")
OK=$(grep -c '^200$' "$F" || true)
BAD=$(( TOTAL - OK ))
if [ "$TOTAL" -gt 0 ]; then
  PCT=$(python3 -c "print(f'{$BAD/$TOTAL*100:.2f}')")
else
  PCT="0.00"
fi

echo "=============================="
echo " label    : $LABEL"
echo " total    : $TOTAL"
echo " HTTP 200 : $OK"
echo " failed   : $BAD  (${PCT}%)"
echo "=============================="
echo "breakdown by status code:"
sort "$F" | uniq -c | sort -rn | sed 's/^/  /'
