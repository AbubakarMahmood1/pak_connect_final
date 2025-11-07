# fmt.sh
#!/usr/bin/env bash
set -euo pipefail

# Optional commit message (not used by pre-commit; kept for manual runs)
MSG="${1:-chore: format+analyze}"

# --- env detection -----------------------------------------------------------
is_wsl=0
case "$(uname -s)" in
  Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then
      is_wsl=1
    fi
    ;;
esac

# Prefer correct toolchain per platform
if [[ $is_wsl -eq 1 ]]; then
  # Use Linux binaries in WSL (avoid accidentally calling Windows exes)
  export PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
  # Put Linux locations ahead of any /mnt/c/... in PATH
  PATH="/snap/bin:/usr/local/bin:/usr/bin:$PATH"
fi

# Resolve tools *after* PATH fix
DART="$(command -v dart || true)"
FLUTTER="$(command -v flutter || true)"

if [[ -z "$DART" || -z "$FLUTTER" ]]; then
  echo "❌ dart or flutter not found on PATH."
  echo "   DART=$DART"
  echo "   FLUTTER=$FLUTTER"
  exit 2
fi

# Guard: if we’re in WSL but dart/flutter resolve to /mnt/c (Windows), fail loudly
if [[ $is_wsl -eq 1 ]] && ( [[ "$DART" == /mnt/* ]] || [[ "$FLUTTER" == /mnt/* ]] ); then
  echo "❌ Detected Windows dart/flutter in WSL PATH."
  echo "   DART=$DART"
  echo "   FLUTTER=$FLUTTER"
  echo "Fix: ensure /snap/bin is earlier in PATH and PUB_CACHE is Linux:"
  echo "  echo 'export PUB_CACHE=\$HOME/.pub-cache' >> ~/.bashrc && source ~/.bashrc"
  echo "  export PATH=/snap/bin:\$PATH"
  exit 3
fi

echo "🛠 Using:"
echo "  dart:    $DART"
echo "  flutter: $FLUTTER"
echo "  PUB_CACHE=${PUB_CACHE:-<unset>}"

# --- format + analyze --------------------------------------------------------
# Format (write in-place). If this changes files, we’ll stop the commit in the hook.
"$DART" format -o write .

# Analyze whole repo (respects analysis_options.yaml exclusions)
# If you only want lib/, switch this to: "$FLUTTER" analyze lib
"$DART" analyze --no-fatal-warnings

# Stage any formatting changes so user can see what changed
git add -A

# Optional: for manual runs, you can auto-commit when there are changes.
# We *don't* auto-commit from the hook; safer for the user to re-run commit.
if [[ "${CI:-}" == "true" ]]; then
  # In CI, fail if there are unstaged changes after formatting
  if ! git diff --cached --quiet; then
    echo "❌ Formatting issues detected. Please run ./fmt.sh locally."
    exit 4
  fi
fi

echo "✅ format + analyze complete"
