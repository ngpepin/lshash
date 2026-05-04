#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH="$SCRIPT_DIR/LsHash.csproj"
CONFIGURATION="${CONFIGURATION:-Release}"
FRAMEWORK="${FRAMEWORK:-net6.0}"
OUTPUT_ROOT="$SCRIPT_DIR/dist"

usage() {
  cat <<'USAGE'
Usage:
  ./build-macos.sh [all|osx-arm64|osx-x64 ...] [--framework net6.0|net10.0]

Examples:
  ./build-macos.sh
  ./build-macos.sh all
  ./build-macos.sh osx-arm64
  ./build-macos.sh osx-x64
  ./build-macos.sh osx-arm64 osx-x64
  ./build-macos.sh --framework net6.0
  ./build-macos.sh osx-x64 --framework net10.0

Notes:
  - Builds self-contained single-file binaries for macOS.
  - Default framework is net6.0 (Catalina-compatible).
  - Uses CONFIGURATION from environment if set (default: Release).
  - Optional env override: FRAMEWORK=net10.0 ./build-macos.sh osx-arm64
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
  while (( $# > 0 )); do
    arg="$1"
    case "$arg" in
      --framework)
        shift
        if (( $# == 0 )); then
          echo "Missing value for --framework" >&2
          usage >&2
          exit 1
        fi
        FRAMEWORK="$1"
        ;;
      --framework=*)
        FRAMEWORK="${arg#--framework=}"
        ;;
      --net6)
        FRAMEWORK="net6.0"
        ;;
      --net10)
        FRAMEWORK="net10.0"
        ;;
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
    shift
  done
fi

case "$FRAMEWORK" in
  net6.0|net10.0)
    ;;
  *)
    echo "Unsupported framework for build-macos.sh: $FRAMEWORK" >&2
    echo "Supported: net6.0, net10.0" >&2
    exit 1
    ;;
esac

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
    -f "$FRAMEWORK" \
    -r "$rid" \
    --self-contained true \
    -p:PublishSingleFile=true \
    -p:PublishTrimmed=false \
    -p:IncludeNativeLibrariesForSelfExtract=true \
    -o "$output_dir"

  echo "Built macOS self-contained single-file executable ($FRAMEWORK):"
  echo "  $output_dir/lshash"
done
