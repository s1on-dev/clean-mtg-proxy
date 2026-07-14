#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

awk '
  /^  cat > .*CONTROL_EOF/ { capture = 1; next }
  capture && /^CONTROL_EOF$/ { found = 1; exit }
  capture { print }
  END { if (!found) exit 1 }
' "${ROOT_DIR}/install.sh"
