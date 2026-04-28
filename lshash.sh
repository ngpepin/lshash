#!/usr/bin/env bash

set -euo pipefail

algorithm="blake3"
recursive="false"
exclude_patterns=()
dedupe_enabled="false"
dedupe_mode="shorter"

auto_install_b3sum() {
  local -a elevate_cmd
  local installed=1
  local install_timeout

  run_install_cmd() {
    if command -v timeout >/dev/null 2>&1; then
      timeout "$install_timeout" "$@"
    else
      "$@"
    fi
  }

  install_timeout="${LSHASH_INSTALL_TIMEOUT:-20}"

  if [[ $(id -u) -eq 0 ]]; then
    elevate_cmd=()
  elif command -v sudo >/dev/null 2>&1; then
    if sudo -n true >/dev/null 2>&1; then
      elevate_cmd=(sudo -n)
    else
      echo "Skipping auto-install: sudo credentials are not available for non-interactive use." >&2
      return 1
    fi
  else
    echo "Skipping auto-install: no privilege escalation tool available." >&2
    return 1
  fi

  if command -v apt-get >/dev/null 2>&1; then
    echo "Attempting to install b3sum via apt-get..." >&2
    if run_install_cmd "${elevate_cmd[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y b3sum; then
      installed=0
    fi
  elif command -v dnf >/dev/null 2>&1; then
    echo "Attempting to install b3sum via dnf..." >&2
    if run_install_cmd "${elevate_cmd[@]}" dnf install -y b3sum; then
      installed=0
    fi
  elif command -v yum >/dev/null 2>&1; then
    echo "Attempting to install b3sum via yum..." >&2
    if run_install_cmd "${elevate_cmd[@]}" yum install -y b3sum; then
      installed=0
    fi
  elif command -v pacman >/dev/null 2>&1; then
    echo "Attempting to install b3sum via pacman..." >&2
    if run_install_cmd "${elevate_cmd[@]}" pacman -Sy --noconfirm b3sum; then
      installed=0
    fi
  elif command -v zypper >/dev/null 2>&1; then
    echo "Attempting to install b3sum via zypper..." >&2
    if run_install_cmd "${elevate_cmd[@]}" zypper --non-interactive install b3sum; then
      installed=0
    fi
  elif command -v apk >/dev/null 2>&1; then
    echo "Attempting to install b3sum via apk..." >&2
    if run_install_cmd "${elevate_cmd[@]}" apk add b3sum; then
      installed=0
    fi
  elif command -v brew >/dev/null 2>&1; then
    echo "Attempting to install b3sum via brew..." >&2
    if run_install_cmd brew install b3sum; then
      installed=0
    fi
  elif command -v cargo >/dev/null 2>&1; then
    echo "Attempting to install b3sum via cargo..." >&2
    if run_install_cmd cargo install b3sum; then
      installed=0
      if [[ -d "$HOME/.cargo/bin" ]]; then
        export PATH="$HOME/.cargo/bin:$PATH"
      fi
    fi
  fi

  if [[ $installed -eq 0 ]] && command -v b3sum >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

get_file_mtime() {
  local file="$1"

  if stat -c %Y -- "$file" >/dev/null 2>&1; then
    stat -c %Y -- "$file"
  else
    stat -f %m -- "$file"
  fi
}

print_help() {
  cat <<'EOF'
Usage: lshash.sh [--algorithm=NAME] [-r|--recursive] [-e PATTERN] [--exclude=PATTERN] [-d [MODE]]

NAME can be one of:
  blake3, sha256, sha512, sha1, md5, blake2

MODE can be one of:
  newer, older, shorter, longer

Options:
  -r, --recursive            Include files from subdirectories
  -e, --exclude PATTERN      Exclude files matching PATTERN (repeatable)
      --exclude=PATTERN      Exclude files matching PATTERN (repeatable)
  -d, --dedupe [MODE]        Dedupe files with same hash in each directory
      --dedupe=MODE          Keep one file by MODE, move others to .dups/

Short-option stacking:
  One-letter switches can be stacked in any order, for example: -rd, -dr, -re '*.log'.

Examples:
  lshash.sh
  lshash.sh --algorithm=sha256
  lshash.sh -r
  lshash.sh -r -e '*.log' -e '*.tmp'
  lshash.sh --algorithm=sha512 --exclude='build/*' --exclude='*.bak'
  lshash.sh -d
  lshash.sh -r --dedupe newer
  lshash.sh --dedupe=longer
  lshash.sh -dr newer
EOF
}

args=("$@")
arg_count=${#args[@]}
arg_index=0

while (( arg_index < arg_count )); do
  arg="${args[$arg_index]}"

  case "$arg" in
    --algorithm=*)
      algorithm="${arg#--algorithm=}"
      ;;
    --algorithm)
      if (( arg_index + 1 >= arg_count )); then
        echo "Missing value for --algorithm" >&2
        exit 1
      fi
      arg_index=$((arg_index + 1))
      algorithm="${args[$arg_index]}"
      ;;
    --exclude=*)
      exclude_patterns+=("${arg#--exclude=}")
      ;;
    --exclude)
      if (( arg_index + 1 >= arg_count )); then
        echo "Missing value for --exclude" >&2
        exit 1
      fi
      arg_index=$((arg_index + 1))
      exclude_patterns+=("${args[$arg_index]}")
      ;;
    --dedupe=*|--dedup=*|--dedub=*)
      dedupe_enabled="true"
      dedupe_mode="${arg#*=}"
      ;;
    --dedupe|--dedup|--dedub)
      dedupe_enabled="true"
      if (( arg_index + 1 < arg_count )) && [[ "${args[$((arg_index + 1))]}" != -* ]]; then
        arg_index=$((arg_index + 1))
        dedupe_mode="${args[$arg_index]}"
      else
        dedupe_mode="shorter"
      fi
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    -*)
      cluster="${arg#-}"
      cluster_len=${#cluster}
      cluster_pos=0
      d_mode_pending="false"

      while (( cluster_pos < cluster_len )); do
        opt="${cluster:cluster_pos:1}"
        case "$opt" in
          r)
            recursive="true"
            cluster_pos=$((cluster_pos + 1))
            ;;
          h)
            print_help
            exit 0
            ;;
          e)
            exclude_patterns+=("")
            if (( cluster_pos + 1 < cluster_len )); then
              exclude_patterns[$(( ${#exclude_patterns[@]} - 1 ))]="${cluster:$((cluster_pos + 1))}"
              cluster_pos=$cluster_len
            else
              if (( arg_index + 1 >= arg_count )); then
                echo "Missing value for -e" >&2
                exit 1
              fi
              arg_index=$((arg_index + 1))
              exclude_patterns[$(( ${#exclude_patterns[@]} - 1 ))]="${args[$arg_index]}"
              cluster_pos=$cluster_len
            fi
            ;;
          d)
            dedupe_enabled="true"
            remainder="${cluster:$((cluster_pos + 1))}"

            if [[ -n "$remainder" ]]; then
              if [[ "$remainder" == =* ]]; then
                dedupe_mode="${remainder#=}" 
                cluster_pos=$cluster_len
              elif [[ "$remainder" =~ ^[rhed]+$ ]]; then
                d_mode_pending="true"
                cluster_pos=$((cluster_pos + 1))
              else
                dedupe_mode="$remainder"
                cluster_pos=$cluster_len
              fi
            else
              d_mode_pending="true"
              cluster_pos=$((cluster_pos + 1))
            fi
            ;;
          *)
            echo "Unknown option: -$opt" >&2
            echo "Try: --help" >&2
            exit 1
            ;;
        esac
      done

      if [[ "$d_mode_pending" == "true" ]] && (( arg_index + 1 < arg_count )) && [[ "${args[$((arg_index + 1))]}" != -* ]]; then
        arg_index=$((arg_index + 1))
        dedupe_mode="${args[$arg_index]}"
      fi
      ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Try: --help" >&2
      exit 1
      ;;
  esac

  arg_index=$((arg_index + 1))
done

algorithm=$(printf '%s' "$algorithm" | tr '[:upper:]' '[:lower:]')
dedupe_mode=$(printf '%s' "$dedupe_mode" | tr '[:upper:]' '[:lower:]')

case "$dedupe_mode" in
  newer|older|shorter|longer)
    ;;
  *)
    echo "Unsupported dedupe mode: $dedupe_mode" >&2
    echo "Supported dedupe modes: newer, older, shorter, longer" >&2
    exit 1
    ;;
esac

case "$algorithm" in
  blake3)
    hash_cmd="b3sum"
    ;;
  sha256)
    hash_cmd="sha256sum"
    ;;
  sha512)
    hash_cmd="sha512sum"
    ;;
  sha1)
    hash_cmd="sha1sum"
    ;;
  md5)
    hash_cmd="md5sum"
    ;;
  blake2)
    hash_cmd="b2sum"
    ;;
  *)
    echo "Unsupported algorithm: $algorithm" >&2
    echo "Supported: blake3, sha256, sha512, sha1, md5, blake2" >&2
    exit 1
    ;;
esac

if ! command -v "$hash_cmd" >/dev/null 2>&1; then
  if [[ "$algorithm" == "blake3" ]]; then
    echo "BLAKE3 requires 'b3sum', but it was not found." >&2
    if auto_install_b3sum; then
      hash_cmd="b3sum"
    else
      echo "Auto-install failed. Install b3sum manually or use --algorithm=sha256 (or sha512/sha1/md5/blake2)." >&2
      exit 1
    fi
  else
    echo "Required command not found: $hash_cmd" >&2
    echo "Install coreutils (or equivalent) for this hash command." >&2
    exit 1
  fi
fi

# Collect regular files and sort by name/path.
if [[ "$recursive" == "true" ]]; then
  mapfile -d '' files < <(find . -type d -name .dups -prune -o -type f -printf '%P\0' | LC_ALL=C sort -z)
else
  mapfile -d '' files < <(find . -maxdepth 1 -type d -name .dups -prune -o -type f -printf '%P\0' | LC_ALL=C sort -z)
fi

if [[ ${#exclude_patterns[@]} -gt 0 ]]; then
  filtered_files=()
  for file in "${files[@]}"; do
    excluded="false"
    for pattern in "${exclude_patterns[@]}"; do
      if [[ "$file" == $pattern ]]; then
        excluded="true"
        break
      fi
    done

    if [[ "$excluded" == "false" ]]; then
      filtered_files+=("$file")
    fi
  done
  files=("${filtered_files[@]}")
fi

if [[ ${#files[@]} -eq 0 ]]; then
  exit 0
fi

if [[ "$dedupe_enabled" != "true" ]]; then
  max_name_len=0
  for file in "${files[@]}"; do
    if (( ${#file} > max_name_len )); then
      max_name_len=${#file}
    fi
  done

  prev_hash=""
  green=$'\033[32m'
  reset=$'\033[0m'
  for file in "${files[@]}"; do
    hash=$($hash_cmd -- "$file" | awk '{print $1}')
    display_hash="$hash"
    if [[ -n "$prev_hash" && "$hash" == "$prev_hash" ]]; then
      display_hash="${green}${hash}${reset}"
    fi

    printf "%-*s  %b\n" "$max_name_len" "$file" "$display_hash"
    prev_hash="$hash"
  done
  exit 0
fi

hashes=()
dirs=()
basenames=()
mtimes=()
moved_flags=()

for file in "${files[@]}"; do
  hash=$($hash_cmd -- "$file" | awk '{print $1}')
  hashes+=("$hash")

  if [[ "$file" == */* ]]; then
    dirs+=("${file%/*}")
  else
    dirs+=(".")
  fi

  basenames+=("${file##*/}")
  mtimes+=("$(get_file_mtime "$file")")
  moved_flags+=("0")
done

if [[ "$dedupe_enabled" == "true" ]]; then
  declare -A grouped_indices

  for i in "${!files[@]}"; do
    group_key="${dirs[$i]}|${hashes[$i]}"
    if [[ -n "${grouped_indices[$group_key]+x}" ]]; then
      grouped_indices[$group_key]+=" $i"
    else
      grouped_indices[$group_key]="$i"
    fi
  done

  for group_key in "${!grouped_indices[@]}"; do
    read -r -a idx_list <<< "${grouped_indices[$group_key]}"
    if (( ${#idx_list[@]} < 2 )); then
      continue
    fi

    keep_idx="${idx_list[0]}"

    for idx in "${idx_list[@]:1}"; do
      choose_candidate="false"
      case "$dedupe_mode" in
        newer)
          if (( ${mtimes[$idx]} > ${mtimes[$keep_idx]} )); then
            choose_candidate="true"
          fi
          ;;
        older)
          if (( ${mtimes[$idx]} < ${mtimes[$keep_idx]} )); then
            choose_candidate="true"
          fi
          ;;
        shorter)
          if (( ${#basenames[$idx]} < ${#basenames[$keep_idx]} )); then
            choose_candidate="true"
          fi
          ;;
        longer)
          if (( ${#basenames[$idx]} > ${#basenames[$keep_idx]} )); then
            choose_candidate="true"
          fi
          ;;
      esac

      if [[ "$choose_candidate" == "true" ]]; then
        keep_idx="$idx"
      fi
    done

    for idx in "${idx_list[@]}"; do
      if [[ "$idx" == "$keep_idx" ]]; then
        continue
      fi

      source_path="${files[$idx]}"
      dir_path="${dirs[$idx]}"
      dups_dir="$dir_path/.dups"
      target_path="$dups_dir/${basenames[$idx]}"

      mkdir -p -- "$dups_dir"
      if [[ -e "$target_path" ]]; then
        suffix=1
        while [[ -e "$dups_dir/${basenames[$idx]}.dup$suffix" ]]; do
          ((suffix++))
        done
        target_path="$dups_dir/${basenames[$idx]}.dup$suffix"
      fi

      mv -- "$source_path" "$target_path"
      moved_flags[$idx]="1"
    done
  done
fi

display_names=()
for i in "${!files[@]}"; do
  display_name="${files[$i]}"
  if [[ "${moved_flags[$i]}" == "1" ]]; then
    display_name+=" (moved to .dups/)"
  fi
  display_names+=("$display_name")
done

# Compute the width needed to display the longest filename fully.
max_name_len=0
for display_name in "${display_names[@]}"; do
  if (( ${#display_name} > max_name_len )); then
    max_name_len=${#display_name}
  fi
done

# Print name and hash, with hashes aligned in one left-justified column.
prev_hash=""
green=$'\033[32m'
italic=$'\033[3m'
reset=$'\033[0m'
for i in "${!files[@]}"; do
  hash="${hashes[$i]}"
  display_hash="$hash"
  if [[ -n "$prev_hash" && "$hash" == "$prev_hash" ]]; then
    display_hash="${green}${hash}${reset}"
  fi

  if [[ "${moved_flags[$i]}" == "1" ]]; then
    printf "%b%-*s%b  %b\n" "$italic" "$max_name_len" "${display_names[$i]}" "$reset" "$display_hash"
  else
    printf "%-*s  %b\n" "$max_name_len" "${display_names[$i]}" "$display_hash"
  fi

  prev_hash="$hash"
done