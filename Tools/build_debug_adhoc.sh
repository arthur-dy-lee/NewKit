#!/usr/bin/env bash
# Compatibility entry point. Debug builds now use a stable Developer ID
# signature so macOS can retain their Accessibility authorization.
set -euo pipefail
echo "Tools/build_debug_adhoc.sh is deprecated; building a signed Debug app instead." >&2
exec "$(dirname "$0")/build_debug_signed.sh" "$@"
