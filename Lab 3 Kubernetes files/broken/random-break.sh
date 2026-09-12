#!/usr/bin/env bash
# Applies one random failure. Does not tell you which.
# Restore with: ~/lab3/broken/restore.sh
set -euo pipefail
B="$HOME/lab3/broken"
FAILURES=(
  "01-image-tag.yaml"
  "02-crashloop.yaml"
  "02b-liveness.yaml"
  "03-oomkilled.yaml"
  "04-unschedulable.yaml"
  "05-missing-secret-key.yaml"
  "06-bad-selector.yaml"
  "07-bad-targetport.yaml"
  "08-bad-readiness.yaml"
  "10-compound-a.yaml"
)
PICK="${FAILURES[$RANDOM % ${#FAILURES[@]}]}"
kubectl apply -f "$B/$PICK" >/dev/null
echo "$PICK" > "$B/.last"
echo "A failure has been applied. Diagnose it."
echo "Reveal the answer with: cat $B/.last"
