#!/bin/bash
# Run the audit and the word search against a fake home folder with known
# traces, and check that nothing in it changed: a fingerprint of every file
# before, and again after.
#   ./test.sh
set -euo pipefail
cd "$(dirname "$0")"
HOME_DIR=$(mktemp -d)/home
trap 'rm -rf "$(dirname "$HOME_DIR")"' EXIT
fixture/make-home.sh "$HOME_DIR"

snapshot() { (cd "$HOME_DIR" && find . -type f -exec shasum -a 256 {} + | sort); }
before=$(snapshot)
HOME="$HOME_DIR" ./mac-trace-audit.sh -nolinks > /dev/null
HOME="$HOME_DIR" ./mac-trace-audit.sh -nolinks -deep > /dev/null
HOME="$HOME_DIR" ./mac-trace-audit.sh -nolinks -search "zebrafixture,example" > /dev/null
after=$(snapshot)

if [ "$before" = "$after" ]; then
  echo "Read-only: $(echo "$before" | wc -l | tr -d ' ') files, none changed by the audit or the word search."
else
  echo "Changed files:"; diff <(echo "$before") <(echo "$after"); exit 1
fi
