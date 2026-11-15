#!/usr/bin/env bash
# Preserve the old filename while sharing the app's single cleanup implementation.
set -euo pipefail
exec "$(dirname "$0")/cleanup_residuals.sh" "$@"
