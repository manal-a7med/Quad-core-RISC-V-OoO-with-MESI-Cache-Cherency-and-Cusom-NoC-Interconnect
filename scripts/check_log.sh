#!/bin/sh
# Fail if a simulation log reports any failed check.
# Accepts summary lines such as "0 FAILED"; anything else mentioning FAIL fails.
log="$1"
[ -s "$log" ] || { echo "check_log: $log is empty or missing"; exit 1; }
bad=$(grep -E 'FAIL|ERROR|Error' "$log" | grep -vE '(^|[^0-9])0 FAILED')
if [ -n "$bad" ]; then
  echo "check_log: failures in $log:"; echo "$bad"; exit 1
fi
echo "check_log: $log OK"
