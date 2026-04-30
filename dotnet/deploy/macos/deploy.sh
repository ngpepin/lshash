#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-lshash:macos}"
DOCKERFILE_PATH="$SCRIPT_DIR/Dockerfile"

usage() {
  cat <<'USAGE'
Usage:
  ./deploy.sh build
  ./deploy.sh audit <host-directory> [lshash-options...]
  ./deploy.sh cull <host-directory> [lshash-options...]
  ./deploy.sh run <host-directory> [lshash-options...]

Commands:
  build
    Build the Docker image for this host architecture.

  audit
    Run read-only audit mode against <host-directory>.
    Default lshash options: --algorithm sha256 -r

  cull
    Run dedupe mode against <host-directory> (read/write mount).
    Default lshash options: --algorithm sha256 -r -d shorter

  run
    Run with an explicit custom lshash command line (read/write mount).

Notes:
  - The target directory is mounted at /data inside the container.
  - Container runs as your current UID:GID to preserve file ownership.
  - Set IMAGE_NAME env var to override image tag.
USAGE
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker CLI is required." >&2
    exit 1
  fi
}

host_arch_to_target() {
  case "$(uname -m)" in
    arm64|aarch64)
      TARGET_RUNTIME="linux-arm64"
      TARGET_PLATFORM="linux/arm64"
      ;;
    x86_64|amd64)
      TARGET_RUNTIME="linux-x64"
      TARGET_PLATFORM="linux/amd64"
      ;;
    *)
      echo "Unsupported host architecture: $(uname -m)" >&2
      echo "Falling back to linux-x64/linux/amd64." >&2
      TARGET_RUNTIME="linux-x64"
      TARGET_PLATFORM="linux/amd64"
      ;;
  esac
}

build_image() {
  require_docker
  host_arch_to_target

  docker build \
    --platform "$TARGET_PLATFORM" \
    --build-arg "TARGET_RUNTIME=$TARGET_RUNTIME" \
    -f "$DOCKERFILE_PATH" \
    -t "$IMAGE_NAME" \
    "$REPO_ROOT"

  echo "Built image: $IMAGE_NAME ($TARGET_RUNTIME)"
}

image_exists() {
  docker image inspect "$IMAGE_NAME" >/dev/null 2>&1
}

ensure_image() {
  require_docker
  if ! image_exists; then
    echo "Image $IMAGE_NAME not found. Building it now..."
    build_image
  fi
}

abs_path() {
  local input_path="$1"
  if [[ ! -d "$input_path" ]]; then
    echo "Directory does not exist: $input_path" >&2
    exit 1
  fi

  (cd -- "$input_path" && pwd)
}

run_container() {
  local mount_mode="$1"
  local host_dir="$2"
  shift 2

  local target
  target="$(abs_path "$host_dir")"

  ensure_image

  docker run --rm -it \
    --user "$(id -u):$(id -g)" \
    -v "$target:/data:$mount_mode" \
    "$IMAGE_NAME" "$@" /data
}

main() {
  if (( $# == 0 )); then
    usage
    exit 1
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    build)
      build_image
      ;;
    audit)
      if (( $# < 1 )); then
        echo "Missing <host-directory> for audit." >&2
        usage >&2
        exit 1
      fi
      local host_dir="$1"
      shift
      if (( $# == 0 )); then
        run_container ro "$host_dir" --algorithm sha256 -r
      else
        run_container ro "$host_dir" "$@"
      fi
      ;;
    cull)
      if (( $# < 1 )); then
        echo "Missing <host-directory> for cull." >&2
        usage >&2
        exit 1
      fi
      local host_dir="$1"
      shift
      if (( $# == 0 )); then
        run_container rw "$host_dir" --algorithm sha256 -r -d shorter
      else
        run_container rw "$host_dir" "$@"
      fi
      ;;
    run)
      if (( $# < 2 )); then
        echo "run requires <host-directory> and at least one lshash option." >&2
        usage >&2
        exit 1
      fi
      local host_dir="$1"
      shift
      run_container rw "$host_dir" "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
