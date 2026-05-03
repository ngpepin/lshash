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

assert_occurrences() {
  local file="$1"
  local text="$2"
  local expected_count="$3"
  local message="$4"
  local actual_count

  actual_count="$(grep -F -- "$text" "$file" | wc -l | tr -d ' ')"
  if [[ "$actual_count" != "$expected_count" ]]; then
    echo "Assertion failed: $message" >&2
    echo "Expected occurrence count: $expected_count" >&2
    echo "Actual occurrence count: $actual_count" >&2
    exit 1
  fi
}

assert_order() {
  local file="$1"
  local first_text="$2"
  local second_text="$3"
  local message="$4"
  local first_line
  local second_line

  first_line="$(grep -nF -- "$first_text" "$file" | head -n1 | cut -d: -f1 || true)"
  second_line="$(grep -nF -- "$second_text" "$file" | head -n1 | cut -d: -f1 || true)"

  if [[ -z "$first_line" || -z "$second_line" || "$second_line" -le "$first_line" ]]; then
    echo "Assertion failed: $message" >&2
    echo "Expected '$second_text' to appear after '$first_text'" >&2
    exit 1
  fi
}

ensure_dotnet_binary() {
  (cd "$ROOT_DIR/dotnet" && ./build.sh linux-x64 >/dev/null)
}

normalize_case_root() {
  local file="$1"
  local root="$2"
  local escaped_root
  local tmp

  escaped_root="$(printf '%s' "$root" | sed -e 's/[.[\*^$()+?{}|\/]/\\&/g' -e 's/&/\\&/g')"
  tmp="$(mktemp)"
  sed "s/${escaped_root}/<CASE_ROOT>/g" "$file" > "$tmp"
  mv "$tmp" "$file"
}

run_impl() {
  local work_dir="$1"
  local out_file="$2"
  local err_file="$3"
  shift 3

  # Force non-interactive execution so prompt-delete paths don't block in CI/regression runs.
  if command -v setsid >/dev/null 2>&1; then
    (cd "$work_dir" && setsid "$@" < /dev/null) > "$out_file" 2> "$err_file" || true
  else
    (cd "$work_dir" && "$@" < /dev/null) > "$out_file" 2> "$err_file" || true
  fi
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

  normalize_case_root "$tmpdir/bash.clean" "$bash_case"
  normalize_case_root "$tmpdir/dotnet.clean" "$dotnet_case"

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

setup_executable_script_exclusion() {
  local root="$1"
  printf 'same\n' > "$root/a.txt"
  cp "$root/a.txt" "$root/aa.txt"

  cat > "$root/script-a.sh" <<'SCRIPT'
#!/usr/bin/env sh
echo hi
SCRIPT
  cp "$root/script-a.sh" "$root/script-b.sh"
  chmod +x "$root/script-a.sh" "$root/script-b.sh"
}

setup_long_name_duplicate_pair() {
  local root="$1"
  local long_a="this_is_a_very_long_filename_that_should_be_truncated_and_keep_suffix_a.txt"
  local long_b="this_is_a_very_long_filename_that_should_be_truncated_and_keep_suffix_b.txt"

  printf 'same\n' > "$root/$long_a"
  cp "$root/$long_a" "$root/$long_b"
}

setup_prompt_delete_gc_tree() {
  local root="$1"
  mkdir -p "$root/scan/x/.dups"
  mkdir -p "$root/scan/y/z/.dups"
  mkdir -p "$root/outside/.dups"
  printf 'trash\n' > "$root/scan/x/.dups/a.txt"
  printf 'trash\n' > "$root/scan/y/z/.dups/b.txt"
  printf 'trash\n' > "$root/outside/.dups/c.txt"
}

setup_global_recursive_cross_directory() {
  local root="$1"
  mkdir -p "$root/sub"
  printf 'same\n' > "$root/keep.txt"
  cp "$root/keep.txt" "$root/sub/this_is_a_significantly_longer_duplicate_filename.txt"
  printf 'unique\n' > "$root/sub/unique.txt"
}

setup_move_dups_default_root() {
  local root="$1"
  mkdir -p "$root/.dups" "$root/sub/.dups"
  printf 'root-dup\n' > "$root/.dups/a.txt"
  printf 'sub-dup\n' > "$root/sub/.dups/b.txt"
}

setup_move_dups_scoped_root() {
  local root="$1"
  mkdir -p "$root/scan/a/.dups" "$root/scan/b/c/.dups" "$root/outside/.dups"
  printf 'x\n' > "$root/scan/a/.dups/one.txt"
  printf 'y\n' > "$root/scan/b/c/.dups/two.txt"
  printf 'z\n' > "$root/outside/.dups/keep.txt"
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

  case_dir="$(run_pair "prompt-delete no-op with extra option" setup_quiet_non_recursive --algorithm=sha256 --prompt-delete)"
  assert_not_contains "$case_dir/bash.clean" "No duplicates were moved into .dups directories." "--prompt-delete without -d should not trigger dedupe post-summary output"
  assert_contains "$case_dir/bash.clean" "Summary: scanned 3 file(s); 1 duplicate file(s) were found (33.33% of scanned files)." "--prompt-delete with extra options should keep normal scanning behavior"
  rm -rf "$case_dir"

  case_dir="$(run_pair "prompt-delete gc from current directory" setup_prompt_delete_gc_tree --prompt-delete)"
  assert_contains "$case_dir/bash.clean" "<CASE_ROOT>/outside/.dups" "--prompt-delete alone should discover root-level .dups directories recursively"
  assert_contains "$case_dir/bash.clean" "<CASE_ROOT>/scan/x/.dups" "--prompt-delete alone should discover nested .dups directories recursively"
  assert_contains "$case_dir/bash.clean" "<CASE_ROOT>/scan/y/z/.dups" "--prompt-delete alone should discover deeply nested .dups directories recursively"
  assert_not_contains "$case_dir/bash.clean" "Summary: scanned" "--prompt-delete standalone gc mode should not perform file scan summary"
  rm -rf "$case_dir"

  case_dir="$(run_pair "prompt-delete gc scoped to directory argument" setup_prompt_delete_gc_tree --prompt-delete scan)"
  assert_contains "$case_dir/bash.clean" "<CASE_ROOT>/scan/x/.dups" "--prompt-delete DIRECTORY should include .dups under DIRECTORY"
  assert_contains "$case_dir/bash.clean" "<CASE_ROOT>/scan/y/z/.dups" "--prompt-delete DIRECTORY should include nested .dups under DIRECTORY"
  assert_not_contains "$case_dir/bash.clean" "<CASE_ROOT>/outside/.dups" "--prompt-delete DIRECTORY should not include .dups outside DIRECTORY"
  assert_not_contains "$case_dir/bash.clean" "Summary: scanned" "--prompt-delete DIRECTORY gc mode should not perform file scan summary"
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

  case_dir="$(run_pair "directory no-op without dedupe" setup_all_directory_non_adjacent --algorithm=sha256 --directory)"
  assert_contains "$case_dir/bash.clean" "a-copy.txt" "--directory without -d should keep normal listing behavior"
  assert_contains "$case_dir/bash.clean" "z-sync-conflict.txt" "--directory without -d should not suppress files"
  [[ ! -d "$case_dir/bashcase/.dups" ]] || { echo "Assertion failed: bash --directory without -d should not dedupe" >&2; exit 1; }
  [[ ! -d "$case_dir/dotnetcase/.dups" ]] || { echo "Assertion failed: dotnet --directory without -d should not dedupe" >&2; exit 1; }
  rm -rf "$case_dir"

  case_dir="$(run_pair "directory dedupe non-adjacent" setup_all_directory_non_adjacent --algorithm=sha256 -d shorter --directory)"
  assert_contains "$case_dir/bash.clean" "z-sync-conflict.txt (moved to .dups/)" "--directory with -d should dedupe non-adjacent duplicates"
  assert_occurrences "$case_dir/bash.clean" "z-sync-conflict.txt" "2" "--directory should list duplicate during hashing and re-list it after move"
  assert_contains "$case_dir/bash.clean" "<CASE_ROOT>/.dups" "--directory should list .dups directories"
  assert_order "$case_dir/bash.clean" "Summary: scanned" "<CASE_ROOT>/.dups" ".dups directories should be listed after summary for --directory"
  [[ -f "$case_dir/bashcase/.dups/z-sync-conflict.txt" ]] || { echo "Assertion failed: bash --directory with -d should move duplicate" >&2; exit 1; }
  [[ -f "$case_dir/dotnetcase/.dups/z-sync-conflict.txt" ]] || { echo "Assertion failed: dotnet --directory with -d should move duplicate" >&2; exit 1; }
  rm -rf "$case_dir"

  case_dir="$(run_pair "all-directory alias compatibility" setup_all_directory_non_adjacent --algorithm=sha256 -d shorter --all-directory)"
  assert_contains "$case_dir/bash.clean" "z-sync-conflict.txt (moved to .dups/)" "--all-directory alias should remain compatible"
  rm -rf "$case_dir"

  case_dir="$(run_pair "global without dedupe no-op" setup_all_directory_non_adjacent --algorithm=sha256 --global)"
  assert_contains "$case_dir/bash.clean" "a-copy.txt" "--global without -d should keep normal listing behavior"
  [[ ! -d "$case_dir/bashcase/.dups" ]] || { echo "Assertion failed: bash --global without -d should not dedupe" >&2; exit 1; }
  [[ ! -d "$case_dir/dotnetcase/.dups" ]] || { echo "Assertion failed: dotnet --global without -d should not dedupe" >&2; exit 1; }
  rm -rf "$case_dir"

  case_dir="$(run_pair "global non-rec behaves all-directory" setup_all_directory_non_adjacent --algorithm=sha256 -d shorter --global)"
  assert_contains "$case_dir/bash.clean" "z-sync-conflict.txt (moved to .dups/)" "--global with -d should dedupe non-adjacent duplicates in non-recursive mode"
  assert_occurrences "$case_dir/bash.clean" "z-sync-conflict.txt" "2" "--global non-recursive should list duplicate during hashing and re-list it after move"
  assert_contains "$case_dir/bash.clean" "<CASE_ROOT>/.dups" "--global non-recursive should list .dups directories"
  assert_order "$case_dir/bash.clean" "Summary: scanned" "<CASE_ROOT>/.dups" ".dups directories should be listed after summary for non-recursive --global"
  [[ -f "$case_dir/bashcase/.dups/z-sync-conflict.txt" ]] || { echo "Assertion failed: bash --global non-recursive should move duplicate" >&2; exit 1; }
  [[ -f "$case_dir/dotnetcase/.dups/z-sync-conflict.txt" ]] || { echo "Assertion failed: dotnet --global non-recursive should move duplicate" >&2; exit 1; }
  [[ ! -f "$case_dir/bashcase/.dups/z-sync-conflict.txt.json" ]] || { echo "Assertion failed: bash --global non-recursive should not write metadata json" >&2; exit 1; }
  [[ ! -f "$case_dir/dotnetcase/.dups/z-sync-conflict.txt.json" ]] || { echo "Assertion failed: dotnet --global non-recursive should not write metadata json" >&2; exit 1; }
  rm -rf "$case_dir"

  case_dir="$(run_pair "global recursive cross-directory" setup_global_recursive_cross_directory --algorithm=sha256 -r -d shorter --global)"
  assert_contains "$case_dir/bash.clean" "sub/this_is_a_significantly_longer_duplicate_filename.txt (moved to .dups/)" "--global recursive should dedupe across directories and move loser in-place"
  assert_occurrences "$case_dir/bash.clean" "sub/this_is_a_significantly_longer_duplicate_filename.txt" "2" "--global recursive should list duplicate during hashing and re-list it after move"
  assert_contains "$case_dir/bash.clean" "<CASE_ROOT>/sub/.dups" "--global recursive should list all .dups directories"
  assert_order "$case_dir/bash.clean" "Summary: scanned" "<CASE_ROOT>/sub/.dups" ".dups directories should be listed after summary for recursive --global"
  [[ -f "$case_dir/bashcase/sub/.dups/this_is_a_significantly_longer_duplicate_filename.txt" ]] || { echo "Assertion failed: bash --global recursive should move duplicate into source directory .dups" >&2; exit 1; }
  [[ -f "$case_dir/dotnetcase/sub/.dups/this_is_a_significantly_longer_duplicate_filename.txt" ]] || { echo "Assertion failed: dotnet --global recursive should move duplicate into source directory .dups" >&2; exit 1; }
  [[ -f "$case_dir/bashcase/sub/.dups/this_is_a_significantly_longer_duplicate_filename.txt.json" ]] || { echo "Assertion failed: bash --global recursive should write metadata json" >&2; exit 1; }
  [[ -f "$case_dir/dotnetcase/sub/.dups/this_is_a_significantly_longer_duplicate_filename.txt.json" ]] || { echo "Assertion failed: dotnet --global recursive should write metadata json" >&2; exit 1; }
  assert_contains "$case_dir/bashcase/sub/.dups/this_is_a_significantly_longer_duplicate_filename.txt.json" "\"status\": \"kept\"" "metadata json should identify kept file"
  assert_contains "$case_dir/bashcase/sub/.dups/this_is_a_significantly_longer_duplicate_filename.txt.json" "\"status\": \"moved\"" "metadata json should identify moved file"
  assert_contains "$case_dir/dotnetcase/sub/.dups/this_is_a_significantly_longer_duplicate_filename.txt.json" "\"status\": \"kept\"" "dotnet metadata json should identify kept file"
  assert_contains "$case_dir/dotnetcase/sub/.dups/this_is_a_significantly_longer_duplicate_filename.txt.json" "\"status\": \"moved\"" "dotnet metadata json should identify moved file"
  rm -rf "$case_dir"

  case_dir="$(run_pair "move-dups spaced syntax default root" setup_move_dups_default_root --move-dups .dups-archive)"
  assert_contains "$case_dir/bash.clean" "<CASE_ROOT>/.dups-archive/.dups" "--move-dups should print moved root .dups destination"
  assert_contains "$case_dir/bash.clean" "<CASE_ROOT>/.dups-archive/sub/.dups" "--move-dups should preserve tree structure for nested .dups"
  [[ ! -d "$case_dir/bashcase/.dups" ]] || { echo "Assertion failed: bash --move-dups should remove source root .dups" >&2; exit 1; }
  [[ ! -d "$case_dir/dotnetcase/.dups" ]] || { echo "Assertion failed: dotnet --move-dups should remove source root .dups" >&2; exit 1; }
  [[ -d "$case_dir/bashcase/.dups-archive/.dups" ]] || { echo "Assertion failed: bash --move-dups should create archive root .dups" >&2; exit 1; }
  [[ -d "$case_dir/dotnetcase/.dups-archive/.dups" ]] || { echo "Assertion failed: dotnet --move-dups should create archive root .dups" >&2; exit 1; }
  [[ -d "$case_dir/bashcase/.dups-archive/sub/.dups" ]] || { echo "Assertion failed: bash --move-dups should create archive nested .dups" >&2; exit 1; }
  [[ -d "$case_dir/dotnetcase/.dups-archive/sub/.dups" ]] || { echo "Assertion failed: dotnet --move-dups should create archive nested .dups" >&2; exit 1; }
  rm -rf "$case_dir"

  case_dir="$(run_pair "move-dups equals syntax with scoped root" setup_move_dups_scoped_root --move-dups=.dups-archive scan)"
  assert_contains "$case_dir/bash.clean" "<CASE_ROOT>/scan/.dups-archive/a/.dups" "--move-dups=PATH should move scoped root .dups directories"
  assert_contains "$case_dir/bash.clean" "<CASE_ROOT>/scan/.dups-archive/b/c/.dups" "--move-dups=PATH should preserve scoped nested tree"
  [[ ! -d "$case_dir/bashcase/scan/a/.dups" ]] || { echo "Assertion failed: bash --move-dups=PATH should remove scoped source .dups" >&2; exit 1; }
  [[ ! -d "$case_dir/dotnetcase/scan/a/.dups" ]] || { echo "Assertion failed: dotnet --move-dups=PATH should remove scoped source .dups" >&2; exit 1; }
  [[ -d "$case_dir/bashcase/scan/.dups-archive/a/.dups" ]] || { echo "Assertion failed: bash --move-dups=PATH should create scoped archive .dups" >&2; exit 1; }
  [[ -d "$case_dir/dotnetcase/scan/.dups-archive/a/.dups" ]] || { echo "Assertion failed: dotnet --move-dups=PATH should create scoped archive .dups" >&2; exit 1; }
  [[ -d "$case_dir/bashcase/outside/.dups" ]] || { echo "Assertion failed: bash scoped --move-dups should not move outside root .dups" >&2; exit 1; }
  [[ -d "$case_dir/dotnetcase/outside/.dups" ]] || { echo "Assertion failed: dotnet scoped --move-dups should not move outside root .dups" >&2; exit 1; }
  rm -rf "$case_dir"

  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bashcase" "$tmpdir/dotnetcase"
  setup_long_name_duplicate_pair "$tmpdir/bashcase"
  setup_long_name_duplicate_pair "$tmpdir/dotnetcase"

  run_impl "$tmpdir/bashcase" "$tmpdir/bash.trunc.out" "$tmpdir/bash.trunc.err" env LSHASH_CONSOLE_WIDTH=90 "$BASH_IMPL" --algorithm=sha256 -d shorter --directory
  run_impl "$tmpdir/dotnetcase" "$tmpdir/dotnet.trunc.out" "$tmpdir/dotnet.trunc.err" env LSHASH_CONSOLE_WIDTH=90 "$DOTNET_IMPL" --algorithm=sha256 -d shorter --directory

  strip_ansi < "$tmpdir/bash.trunc.out" > "$tmpdir/bash.trunc.clean"
  strip_ansi < "$tmpdir/dotnet.trunc.out" > "$tmpdir/dotnet.trunc.clean"
  normalize_case_root "$tmpdir/bash.trunc.clean" "$tmpdir/bashcase"
  normalize_case_root "$tmpdir/dotnet.trunc.clean" "$tmpdir/dotnetcase"

  assert_same_output "$tmpdir/bash.trunc.clean" "$tmpdir/dotnet.trunc.clean" "moved suffix truncation: bash/.NET outputs differ"
  assert_contains "$tmpdir/bash.trunc.clean" "(moved to .dups/)" "moved marker should remain visible when names are truncated to fit width"
  rm -rf "$tmpdir"

  case_dir="$(run_pair "recursive ignores symlink directories" setup_symlink_directory --algorithm=sha256 -r)"
  assert_not_contains "$case_dir/bash.clean" "linkdir/" "recursive traversal should ignore symlinked directories"
  assert_contains "$case_dir/bash.clean" "Summary: scanned 2 file(s); 0 duplicate file(s) were found (0.00% of scanned files); 3 directories were traversed." "recursive summary should not count symlinked directory targets"
  rm -rf "$case_dir"

  case_dir="$(run_pair "recursive inaccessible subdirectory" setup_inaccessible_subdirectory --algorithm=sha256 -r)"
  assert_contains "$case_dir/bash.clean" "open/a.txt" "recursive traversal should continue processing accessible directories"
  assert_contains "$case_dir/bash.clean" "Summary: scanned" "recursive traversal should still emit summary when a subdirectory is inaccessible"
  chmod 755 "$case_dir/bashcase/blocked" "$case_dir/dotnetcase/blocked" || true
  rm -rf "$case_dir"

  case_dir="$(run_pair "dedupe excludes executable programs" setup_executable_program_exclusion --algorithm=sha256 -d shorter --directory)"
  assert_contains "$case_dir/bash.clean" "prog-a" "executable program entries should still be listed"
  assert_contains "$case_dir/bash.clean" "<excluded executable program>" "executable program entries should be explicitly excluded from dedupe"
  assert_not_contains "$case_dir/bash.clean" "prog-b (moved to .dups/)" "executable programs should not be moved by dedupe"
  [[ -f "$case_dir/bashcase/.dups/aa.txt" ]] || { echo "Assertion failed: regular duplicate should still be moved" >&2; exit 1; }
  [[ -f "$case_dir/dotnetcase/.dups/aa.txt" ]] || { echo "Assertion failed: dotnet regular duplicate should still be moved" >&2; exit 1; }
  [[ ! -f "$case_dir/bashcase/.dups/prog-b" ]] || { echo "Assertion failed: bash should not move excluded executable program" >&2; exit 1; }
  [[ ! -f "$case_dir/dotnetcase/.dups/prog-b" ]] || { echo "Assertion failed: dotnet should not move excluded executable program" >&2; exit 1; }
  rm -rf "$case_dir"

  case_dir="$(run_pair "dedupe excludes executable scripts" setup_executable_script_exclusion --algorithm=sha256 -d shorter --directory)"
  assert_contains "$case_dir/bash.clean" "script-a.sh" "executable script entries should still be listed"
  assert_contains "$case_dir/bash.clean" "<excluded executable program>" "executable script entries should be explicitly excluded from dedupe"
  assert_not_contains "$case_dir/bash.clean" "script-b.sh (moved to .dups/)" "executable scripts should not be moved by dedupe"
  [[ -f "$case_dir/bashcase/.dups/aa.txt" ]] || { echo "Assertion failed: regular duplicate should still be moved with executable scripts present" >&2; exit 1; }
  [[ -f "$case_dir/dotnetcase/.dups/aa.txt" ]] || { echo "Assertion failed: dotnet regular duplicate should still be moved with executable scripts present" >&2; exit 1; }
  [[ ! -f "$case_dir/bashcase/.dups/script-b.sh" ]] || { echo "Assertion failed: bash should not move excluded executable script" >&2; exit 1; }
  [[ ! -f "$case_dir/dotnetcase/.dups/script-b.sh" ]] || { echo "Assertion failed: dotnet should not move excluded executable script" >&2; exit 1; }
  rm -rf "$case_dir"

  echo "All regression checks passed."
}

main "$@"
