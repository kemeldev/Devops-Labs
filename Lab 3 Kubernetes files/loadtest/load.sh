#!/usr/bin/env bash
# Sends requests in parallel for a fixed number of seconds.
# Records one HTTP status code per line, per worker, then combines them.
#
# usage: ./load.sh <seconds> <concurrency> <url> <label>

set -u # unset variables as errors. If you try to use a variable that has not been defined, the script exits with an error instead of continuing silently.
SECS="${1:-60}"  #if not provided the - represents the defaults
CONC="${2:-4}"
URL="${3:?need a url}"
LABEL="${4:-run}"

DIR="$HOME/lab3/loadtest/results"
mkdir -p "$DIR"
rm -f "$DIR/${LABEL}"*.raw

END=$(( $(date +%s) + SECS ))
echo "Sending requests to $URL"
echo "Duration ${SECS}s, concurrency ${CONC}, label '${LABEL}'"

for i in $(seq 1 "$CONC"); do
  (
    while [ "$(date +%s)" -lt "$END" ]; do
      curl -s -o /dev/null -m 3 -w '%{http_code}\n' "$URL" 2>/dev/null || echo "000"
    done
  ) > "$DIR/${LABEL}.${i}.raw" &
done
wait

cat "$DIR/${LABEL}."*.raw > "$DIR/${LABEL}.txt"
rm -f "$DIR/${LABEL}."*.raw
echo "Finished. Results in $DIR/${LABEL}.txt"
