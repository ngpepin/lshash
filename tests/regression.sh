#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_IMPL="$ROOT_DIR/lshash.sh"
DOTNET_IMPL="$ROOT_DIR/dotnet/dist/linux-x64/lshash"

strip_ansi() {
  sed -E 's/\x1b\[[0-9;]*m//g'
}

assert_contains() {
  local file="$1"
  local text="$2"
  local message="$3"
  if ! grep -Fq -- "$text" "$file"; then
    echo "Assertion failed: $message" >&2
    echo "Expected to find: $text" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file="$1"
  local text="$2"
  local message="$3"
  if grep -Fq -- "$text" "$file"; then
    echo "Assertion failed: $message" >&2
    echo "Did not expect to find: $text" >&2
    exit 1
  fi
}

assert_same_output() {
  local left="$1"
  local right="$2"
  local message="$3"
  if ! diff -u "$left" "$right" >/dev/null; then
    echo "Assertion failed: $message" >&2
    diff -u "$left" "$right" >&2 || true
    exit 1
  fi
}

ensure_dotnet_binary() {
  (cd "$ROOT_DIR/dotnet" && ./build.sh linux-x64 >/dev/null)
}

run_impl() {
  local work_dir="$1"
  local out_file="$2"
  local err_file="$3"
  shift 3

  (cd "$work_dir" && "$@") > "$out_file" 2> "$err_file" || true
}

run_pair() {
  local scenario_name="$1"
  local setup_fn="$2"
  shift 2

  local tmpdir
  tmpdir="$(mktemp -d)"
  local bash_case="$tmpdir/bashcase"
  local dotnet_case="$tmpdir/dotnetcase"

  mkdir -p "$bash_case" "$dotnet_case"
  "$setup_fn" "$bash_case"
  "$setup_fn" "$dotnet_case"

  run_impl "$bash_case" "$tmpdir/bash.out" "$tmpdir/bash.err" "$BASH_IMPL" "$@"
  run_impl "$dotnet_case" "$tmpdir/dotnet.out" "$tmpdir/dotnet.err" "$DOTNET_IMPL" "$@"

  strip_ansi < "$tmpdir/bash.out" > "$tmpdir/bash.clean"
  strip_ansi < "$tmpdir/dotnet.out" > "$tmpdir/dotnet.clean"

  assert_same_output "$tmpdir/bash.clean" "$tmpdir/dotnet.clean" "$scenario_name: bash/.NET outputs differ"

  echo "$tmpdir"
}

setup_quiet_non_recursive() {
  local root="$1"
  printf 'same\n' > "$root/a.txt"
  cp "$root/a.txt" "$root/b.txt"
  printf 'different\n' > "$root/c.txt"
}

setup_quiet_recursive() {
  local root="$1"
  mkdir -p "$root/sub"
  printf 'unique\n' > "$root/z.txt"
  printf 'same\n' > "$root/sub/a.txt"
  cp "$root/sub/a.txt" "$root/sub/b.txt"
}

setup_quiet_dedupe() {
  local root="$1"
  printf 'same\n' > "$root/a.txt"
  cp "$root/a.txt" "$root/aa.txt"
  cp "$root/a.txt" "$root/aaa.txt"
}

setup_inaccessible_middle() {
  local root="$1"
  printf 'same\n' > "$root/a.pdf"
  cp "$root/a.pdf" "$root/aa.pdf"
  cp "$root/a.pdf" "$root/aaa.pdf"
  printf 'different\n' > "$root/b.pdf"
  cp "$root/a.pdf" "$root/z.pdf"
  chmod 000 "$root/aa.pdf"
}

setup_all_directory_non_adjacent() {
  local root="$1"
  printf 'same\n' > "$root/a-copy.txt"
  printf 'middle\n' > "$root/m-middle.txt"
  printf 'same\n' > "$root/z-sync-conflict.txt"
}

setup_symlink_directory() {
  local root="$1"
  mkdir -p "$root/real/sub"
  printf 'x\n' > "$root/real/a.txt"
  printf 'y\n' > "$root/real/sub/b.txt"
  ln -s real "$root/linkdir"
}

setup_inaccessible_subdirectory() {
  local root="$1"
  mkdir -p "$root/open" "$root/blocked"
  printf 'visible\n' > "$root/open/a.txt"
  printf 'hidden\n' > "$root/blocked/secret.txt"
  chmod 000 "$root/blocked"
}

setup_executable_program_exclusion() {
  local root="$1"
  printf 'same\n' > "$root/a.txt"
  cp "$root/a.txt" "$root/aa.txt"
  cp "$DOTNET_IMPL" "$root/prog-a"
  cp "$DOTNET_IMPL" "$root/prog-b"
}

main() {
  ensure_dotnet_binary

  local case_dir

  case_dir="$(run_pair "quiet non-recursive" setup_quiet_non_recursive --algorithm=sha256 -q)"
  assert_contains "$case_dir/bash.clean" "b.txt" "quiet mode should show duplicate line in non-recursive mode"
  assert_not_contains "$case_dir/bash.clean" "a.txt" "quiet mode should hide non-duplicate first line"
  assert_not_contains "$case_dir/bash.clean" "c.txt" "quiet mode should hide unique lines"
  assert_contains "$case_dir/bash.clean" "Summary: scanned 3 file(s); 1 duplicate file(s) were found (33.33% of scanned files)." "non-recursive summary should report duplicate count and percentage"
  rm -rf "$case_dir"

  case_dir="$(run_pair "quiet recursive" setup_quiet_recursive --algorithm=sha256 -r -q)"
  assert_contains "$case_dir/bash.clean" "sub/b.txt" "quiet recursive mode should show duplicate line"
  assert_not_contains "$case_dir/bash.clean" "sub/a.txt" "quiet recursive mode should hide non-duplicate first line"
  assert_contains "$case_dir/bash.clean" "2 directories were traversed." "recursive summary should report directories traversed"
  rm -rf "$case_dir"

  case_dir="$(run_pair "quiet dedupe" setup_quiet_dedupe --algorithm=sha256 -d shorter -q)"
  assert_contains "$case_dir/bash.clean" "aa.txt (moved to .dups/)" "quiet dedupe should show moved duplicate line"
  assert_contains "$case_dir/bash.clean" "aaa.txt (moved to .dups/)" "quiet dedupe should show all duplicate lines"
  assert_contains "$case_dir/bash.clean" "Summary: scanned 3 file(s); 2 duplicate file(s) were found and moved (66.66% of scanned files)." "dedupe summary should report duplicates as found and moved"
  [[ -f "$case_dir/bashcase/.dups/aa.txt" ]] || { echo "Assertion failed: bash dedupe should move aa.txt" >&2; exit 1; }
  [[ -f "$case_dir/dotnetcase/.dups/aa.txt" ]] || { echo "Assertion failed: dotnet dedupe should move aa.txt" >&2; exit 1; }
  rm -rf "$case_dir"

  case_dir="$(run_pair "inaccessible middle" setup_inaccessible_middle --algorithm=sha256 -d shorter)"
  assert_contains "$case_dir/bash.clean" "aa.pdf" "inaccessible file should still appear in output"
  assert_contains "$case_dir/bash.clean" "<hash unavailable>" "inaccessible file should show hash unavailable"
  [[ -f "$case_dir/bashcase/.dups/aaa.pdf" ]] || { echo "Assertion failed: bash should dedupe across inaccessible middle" >&2; exit 1; }
  [[ -f "$case_dir/dotnetcase/.dups/aaa.pdf" ]] || { echo "Assertion failed: dotnet should dedupe across inaccessible middle" >&2; exit 1; }
  chmod 644 "$case_dir/bashcase/aa.pdf" "$case_dir/dotnetcase/aa.pdf" || true
  rm -rf "$case_dir"

  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/parent/scan"
  printf 'same\n' > "$tmpdir/parent/scan/a.txt"
  cp "$tmpdir/parent/scan/a.txt" "$tmpdir/parent/scan/b.txt"

  run_impl "$tmpdir/parent" "$tmpdir/bash.path.out" "$tmpdir/bash.path.err" "$BASH_IMPL" --algorithm=sha256 -q scan
  run_impl "$tmpdir/parent" "$tmpdir/dotnet.path.out" "$tmpdir/dotnet.path.err" "$DOTNET_IMPL" --algorithm=sha256 -q scan

  strip_ansi < "$tmpdir/bash.path.out" > "$tmpdir/bash.path.clean"
  strip_ansi < "$tmpdir/dotnet.path.out" > "$tmpdir/dotnet.path.clean"

  assert_same_output "$tmpdir/bash.path.clean" "$tmpdir/dotnet.path.clean" "optional directory path: bash/.NET outputs differ"
  assert_contains "$tmpdir/bash.path.clean" "b.txt" "directory argument should be supported"
  assert_not_contains "$tmpdir/bash.path.clean" "scan/b.txt" "output should remain relative to selected directory root"

  rm -rf "$tmpdir"

  case_dir="$(run_pair "all-directory no-op without dedupe" setup_all_directory_non_adjacent --algorithm=sha256 --all-directory)"
  assert_contains "$case_dir/bash.clean" "a-copy.txt" "--all-directory without -d should keep normal listing behavior"
  assert_contains "$case_dir/bash.clean" "z-sync-conflict.txt" "--all-directory without -d should not suppress files"
  [[ ! -d "$case_dir/bashcase/.dups" ]] || { echo "Assertion failed: bash --all-directory without -d should not dedupe" >&2; exit 1; }
  [[ ! -d "$case_dir/dotnetcase/.dups" ]] || { echo "Assertion failed: dotnet --all-directory without -d should not dedupe" >&2; exit 1; }
  rm -rf "$case_dir"

  case_dir="$(run_pair "all-directory dedupe non-adjacent" setup_all_directory_non_adjacent --algorithm=sha256 -d shorter --all-directory)"
  assert_contains "$case_dir/bash.clean" "z-sync-conflict.txt (moved to .dups/)" "--all-directory with -d should dedupe non-adjacent duplicates"
  [[ -f "$case_dir/bashcase/.dups/z-sync-conflict.txt" ]] || { echo "Assertion failed: bash --all-directory with -d should move duplicate" >&2; exit 1; }
  [[ -f "$case_dir/dotnetcase/.dups/z-sync-conflict.txt" ]] || { echo "Assertion failed: dotnet --all-directory with -d should move duplicate" >&2; exit 1; }
  rm -rf "$case_dir"

  case_dir="$(run_pair "recursive ignores symlink directories" setup_symlink_directory --algorithm=sha256 -r)"
  assert_not_contains "$case_dir/bash.clean" "linkdir/" "recursive traversal should ignore symlinked directories"
  assert_contains "$case_dir/bash.clean" "Summary: scanned 2 file(s); 0 duplicate file(s) were found (0.00% of scanned files); 3 directories were traversed." "recursive summary should not count symlinked directory targets"
  rm -rf "$case_dir"

  case_dir="$(run_pair "recursive inaccessible subdirectory" setup_inaccessible_subdirectory --algorithm=sha256 -r)"
  assert_contains "$case_dir/bash.clean" "open/a.txt" "recursive traversal should continue processing accessible directories"
  assert_contains "$case_dir/bash.clean" "Summary: scanned" "recursive traversal should still emit summary when a subdirectory is inaccessible"
  chmod 755 "$case_dir/bashcase/blocked" "$case_dir/dotnetcase/blocked" || true
  rm -rf "$case_dir"

  case_dir="$(run_pair "dedupe excludes executable programs" setup_executable_program_exclusion --algorithm=sha256 -d shorter --all-directory)"
  assert_contains "$case_dir/bash.clean" "prog-a" "executable program entries should still be listed"
  assert_contains "$case_dir/bash.clean" "<excluded executable program>" "executable program entries should be explicitly excluded from dedupe"
  assert_not_contains "$case_dir/bash.clean" "prog-b (moved to .dups/)" "executable programs should not be moved by dedupe"
  [[ -f "$case_dir/bashcase/.dups/aa.txt" ]] || { echo "Assertion failed: regular duplicate should still be moved" >&2; exit 1; }
  [[ -f "$case_dir/dotnetcase/.dups/aa.txt" ]] || { echo "Assertion failed: dotnet regular duplicate should still be moved" >&2; exit 1; }
  [[ ! -f "$case_dir/bashcase/.dups/prog-b" ]] || { echo "Assertion failed: bash should not move excluded executable program" >&2; exit 1; }
  [[ ! -f "$case_dir/dotnetcase/.dups/prog-b" ]] || { echo "Assertion failed: dotnet should not move excluded executable program" >&2; exit 1; }
  rm -rf "$case_dir"

  echo "All regression checks passed."
}

main "$@"
