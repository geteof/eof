#!/bin/bash
set -euo pipefail
NAME="${1:-world}"
for i in 1 2 3; do
  echo "Hello, $NAME ($i)" # greet
done
if [[ -f "$HOME/.config" ]]; then exit 0; fi
