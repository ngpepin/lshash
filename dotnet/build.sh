#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH="$SCRIPT_DIR/LsHash.csproj"
RID="${1:-linux-x64}"
CONFIGURATION="${CONFIGURATION:-Release}"
OUTPUT_DIR="$SCRIPT_DIR/dist/$RID"

if ! command -v dotnet >/dev/null 2>&1; then
  echo "dotnet CLI is required to build this project." >&2
  exit 1
fi

dotnet publish "$PROJECT_PATH" \
  -c "$CONFIGURATION" \
  -r "$RID" \
  --self-contained true \
  -p:PublishSingleFile=true \
  -p:PublishTrimmed=false \
  -p:IncludeNativeLibrariesForSelfExtract=true \
  -o "$OUTPUT_DIR"

echo "Built self-contained single-file executable:" 
echo "  $OUTPUT_DIR/lshash"
