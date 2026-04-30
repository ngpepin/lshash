#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH="$SCRIPT_DIR/LsHash.csproj"
CONFIGURATION="${CONFIGURATION:-Release}"
OUTPUT_ROOT="$SCRIPT_DIR/dist"

usage() {
  cat <<'USAGE'
Usage:
  ./build-macos.sh [all|osx-arm64|osx-x64 ...]

Examples:
  ./build-macos.sh
  ./build-macos.sh all
  ./build-macos.sh osx-arm64
  ./build-macos.sh osx-x64
  ./build-macos.sh osx-arm64 osx-x64

Notes:
  - Builds self-contained single-file binaries for macOS.
  - Uses CONFIGURATION from environment if set (default: Release).
USAGE
}

if ! command -v dotnet >/dev/null 2>&1; then
  echo "dotnet CLI is required to build this project." >&2
  exit 1
fi

declare -a rids=()

if (( $# == 0 )); then
  rids=("osx-arm64" "osx-x64")
else
  for arg in "$@"; do
    case "$arg" in
      all)
        rids=("osx-arm64" "osx-x64")
        ;;
      osx-arm64|osx-x64)
        rids+=("$arg")
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unsupported target: $arg" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
fi

if (( ${#rids[@]} == 0 )); then
  echo "No valid macOS runtime identifiers were provided." >&2
  usage >&2
  exit 1
fi

# De-duplicate while preserving order (Bash 3-compatible).
declare -a unique_rids=()
for rid in "${rids[@]}"; do
  local_seen="false"
  for existing in "${unique_rids[@]}"; do
    if [[ "$existing" == "$rid" ]]; then
      local_seen="true"
      break
    fi
  done

  if [[ "$local_seen" != "true" ]]; then
    unique_rids+=("$rid")
  fi
done

for rid in "${unique_rids[@]}"; do
  output_dir="$OUTPUT_ROOT/$rid"

  dotnet publish "$PROJECT_PATH" \
    -c "$CONFIGURATION" \
    -r "$rid" \
    --self-contained true \
    -p:PublishSingleFile=true \
    -p:PublishTrimmed=false \
    -p:IncludeNativeLibrariesForSelfExtract=true \
    -o "$output_dir"

  echo "Built macOS self-contained single-file executable:"
  echo "  $output_dir/lshash"
done
