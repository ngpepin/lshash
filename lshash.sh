#!/usr/bin/env bash

set -euo pipefail

algorithm="blake3"
recursive="false"
exclude_patterns=()
dedupe_enabled="false"
dedupe_mode="shorter"
all_directory="false"
global_dedupe="false"
prompt_delete="false"
quiet="false"
target_dir="."
target_dir_set="false"
prev_hash=""
summary_total_files=0
summary_duplicate_files=0
summary_moved_files=0
summary_directories=0
console_width=0
dups_dirs=()
platform_name="$(uname -s 2>/dev/null || echo Unknown)"
is_macos="false"
if [[ "$platform_name" == "Darwin" ]]; then
  is_macos="true"
fi
current_group_files=()
current_subdirs=()
global_scope_active="false"

print_help() {
  cat <<'HELP'
Usage: lshash.sh [--algorithm=NAME] [-r|--recursive] [-e PATTERN] [--exclude=PATTERN] [-d [MODE]] [--directory] [--global] [--prompt-delete] [-q|--quiet] [DIRECTORY]

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
                 Valid MODE values: newer, older, shorter, longer
      --directory            With -d, dedupe all files in directory by hash
      --all-directory        Backward-compatible alias for --directory
      --global               With -d and -r, dedupe globally across all recursive files by hash
                 (ignores per-directory adjacency grouping).
             With -d only, behaves like --directory in the selected directory.
      --prompt-delete        With -d, after listing .dups directories, prompt y/N to delete them.
                 Used alone (or with only DIRECTORY), recursively gather existing
                 .dups directories, list them, and prompt y/N to delete them.
  -q, --quiet                Only print duplicate (green) file lines

Short-option stacking:
  One-letter switches can be stacked in any order, for example: -rd, -dr, -re '*.log'.

Examples:
  lshash.sh
  lshash.sh --algorithm=sha256
  lshash.sh -r
  lshash.sh -r -e '*.log' -e '*.tmp'
  lshash.sh --algorithm=sha512 --exclude='build/*' --exclude='*.bak'
  lshash.sh -d
  lshash.sh -d --directory
  lshash.sh -r -d shorter --global
  lshash.sh -r --dedupe newer
  lshash.sh --dedupe=longer
  lshash.sh -dr newer
  lshash.sh --prompt-delete
  lshash.sh --prompt-delete /path/to/scan
  lshash.sh -rq /path/to/scan
HELP
}

is_valid_dedupe_mode() {
  local mode
  mode="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$mode" in
    newer|older|shorter|longer)
      return 0
      ;;
  esac

  return 1
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift

  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_seconds" "$@"
  else
    "$@"
  fi
}

auto_install_b3sum() {
  local -a elevate_cmd
  local installed=1
  local install_timeout

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
    if run_with_timeout "$install_timeout" "${elevate_cmd[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y b3sum; then
      installed=0
    fi
  elif command -v dnf >/dev/null 2>&1; then
    echo "Attempting to install b3sum via dnf..." >&2
    if run_with_timeout "$install_timeout" "${elevate_cmd[@]}" dnf install -y b3sum; then
      installed=0
    fi
  elif command -v yum >/dev/null 2>&1; then
    echo "Attempting to install b3sum via yum..." >&2
    if run_with_timeout "$install_timeout" "${elevate_cmd[@]}" yum install -y b3sum; then
      installed=0
    fi
  elif command -v pacman >/dev/null 2>&1; then
    echo "Attempting to install b3sum via pacman..." >&2
    if run_with_timeout "$install_timeout" "${elevate_cmd[@]}" pacman -Sy --noconfirm b3sum; then
      installed=0
    fi
  elif command -v zypper >/dev/null 2>&1; then
    echo "Attempting to install b3sum via zypper..." >&2
    if run_with_timeout "$install_timeout" "${elevate_cmd[@]}" zypper --non-interactive install b3sum; then
      installed=0
    fi
  elif command -v apk >/dev/null 2>&1; then
    echo "Attempting to install b3sum via apk..." >&2
    if run_with_timeout "$install_timeout" "${elevate_cmd[@]}" apk add b3sum; then
      installed=0
    fi
  elif command -v brew >/dev/null 2>&1; then
    echo "Attempting to install b3sum via brew..." >&2
    if run_with_timeout "$install_timeout" brew install b3sum; then
      installed=0
    fi
  elif command -v cargo >/dev/null 2>&1; then
    echo "Attempting to install b3sum via cargo..." >&2
    if run_with_timeout "$install_timeout" cargo install b3sum; then
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

  if [[ "$is_macos" == "true" ]]; then
    stat -f %m -- "$file"
    return
  fi

  if stat -c %Y -- "$file" >/dev/null 2>&1; then
    stat -c %Y -- "$file"
  else
    stat -f %m -- "$file"
  fi
}

parse_args() {
  local args=("$@")
  local arg_count=${#args[@]}
  local arg_index=0

  while (( arg_index < arg_count )); do
    local arg="${args[$arg_index]}"

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
        dedupe_mode="shorter"
        if (( arg_index + 1 < arg_count )) && [[ "${args[$((arg_index + 1))]}" != -* ]]; then
          local possible_mode="${args[$((arg_index + 1))]}"
          if is_valid_dedupe_mode "$possible_mode"; then
            arg_index=$((arg_index + 1))
            dedupe_mode="$possible_mode"
          fi
        fi
        ;;
      --quiet)
        quiet="true"
        ;;
      --directory|--all-directory)
        all_directory="true"
        ;;
      --global)
        global_dedupe="true"
        ;;
      --prompt-delete)
        prompt_delete="true"
        ;;
      -h|--help)
        print_help
        exit 0
        ;;
      -*)
        local cluster="${arg#-}"
        local cluster_len=${#cluster}
        local cluster_pos=0
        local d_mode_pending="false"

        while (( cluster_pos < cluster_len )); do
          local opt="${cluster:cluster_pos:1}"
          case "$opt" in
            r)
              recursive="true"
              cluster_pos=$((cluster_pos + 1))
              ;;
            q)
              quiet="true"
              cluster_pos=$((cluster_pos + 1))
              ;;
            h)
              print_help
              exit 0
              ;;
            e)
              if (( cluster_pos + 1 < cluster_len )); then
                exclude_patterns+=("${cluster:$((cluster_pos + 1))}")
                cluster_pos=$cluster_len
              else
                if (( arg_index + 1 >= arg_count )); then
                  echo "Missing value for -e" >&2
                  exit 1
                fi
                arg_index=$((arg_index + 1))
                exclude_patterns+=("${args[$arg_index]}")
                cluster_pos=$cluster_len
              fi
              ;;
            d)
              dedupe_enabled="true"
              dedupe_mode="shorter"

              local remainder="${cluster:$((cluster_pos + 1))}"
              if [[ -n "$remainder" ]]; then
                if [[ "$remainder" == =* ]]; then
                  dedupe_mode="${remainder#=}" 
                  cluster_pos=$cluster_len
                elif [[ "$remainder" =~ ^[rhedq]+$ ]]; then
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
          local possible_mode="${args[$((arg_index + 1))]}"
          if is_valid_dedupe_mode "$possible_mode"; then
            arg_index=$((arg_index + 1))
            dedupe_mode="$possible_mode"
          fi
        fi
        ;;
      *)
        if [[ "$target_dir_set" == "false" ]]; then
          target_dir="$arg"
          target_dir_set="true"
        else
          echo "Unexpected argument: $arg" >&2
          echo "Try: --help" >&2
          exit 1
        fi
        ;;
    esac

    arg_index=$((arg_index + 1))
  done
}

should_exclude() {
  local path="$1"
  local pattern

  for pattern in "${exclude_patterns[@]}"; do
    if [[ "$path" == $pattern ]]; then
      return 0
    fi
  done

  return 1
}

warn_file_issue() {
  local action="$1"
  local file="$2"
  local details="$3"
  echo "Warning: cannot ${action} '$file': ${details}" >&2
}

try_hash_file() {
  local file="$1"
  local output

  if output="$($hash_cmd -- "$file" 2>&1)"; then
    awk '{print $1}' <<< "$output"
    return 0
  fi

  warn_file_issue "hash" "$file" "$output"
  return 1
}

try_get_file_mtime() {
  local file="$1"
  local output

  if output="$(get_file_mtime "$file" 2>&1)"; then
    printf '%s\n' "$output"
    return 0
  fi

  warn_file_issue "read mtime" "$file" "$output"
  return 1
}

safe_move_file() {
  local source_path="$1"
  local target_path="$2"
  local output

  if output="$(mv -- "$source_path" "$target_path" 2>&1)"; then
    return 0
  fi

  warn_file_issue "move" "$source_path" "$output"
  return 1
}

remember_dups_dir() {
  local dups_dir_rel="$1"
  local full_path

  if ! full_path="$(cd -- "$dups_dir_rel" 2>/dev/null && pwd -P)"; then
    return
  fi

  local existing
  for existing in "${dups_dirs[@]}"; do
    if [[ "$existing" == "$full_path" ]]; then
      return
    fi
  done

  dups_dirs+=("$full_path")
}

print_dups_directories() {
  local green=$'\033[32m'
  local reset=$'\033[0m'

  if (( ${#dups_dirs[@]} == 0 )); then
    printf '%b%s%b\n' "$green" "No duplicates were moved into .dups directories." "$reset"
    return
  fi

  local dir
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    printf '%b%s%b\n' "$green" "$dir" "$reset"
  done < <(printf '%s\n' "${dups_dirs[@]}" | LC_ALL=C sort)
}

prompt_delete_dups_directories() {
  if (( ${#dups_dirs[@]} == 0 )); then
    return
  fi

  local reply=""
  if [[ -t 0 ]]; then
    printf 'Delete listed .dups directories? y/N: '
    read -r reply
  elif [[ -r /dev/tty ]]; then
    printf 'Delete listed .dups directories? y/N: ' > /dev/tty
    read -r reply < /dev/tty
  else
    echo "Warning: --prompt-delete requested, but input is not interactive; skipping delete prompt." >&2
    return
  fi

  if [[ "$reply" != "y" && "$reply" != "Y" ]]; then
    return
  fi

  local dir
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    if ! rm -rf -- "$dir" 2>/dev/null; then
      warn_file_issue "delete" "$dir" "failed to remove directory"
    fi
  done < <(printf '%s\n' "${dups_dirs[@]}" | LC_ALL=C sort)
}

print_existing_dups_directories() {
  local green=$'\033[32m'
  local reset=$'\033[0m'

  if (( ${#dups_dirs[@]} == 0 )); then
    printf '%b%s%b\n' "$green" "No .dups directories were found." "$reset"
    return
  fi

  local dir
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    printf '%b%s%b\n' "$green" "$dir" "$reset"
  done < <(printf '%s\n' "${dups_dirs[@]}" | LC_ALL=C sort)
}

is_prompt_delete_garbage_collect_mode() {
  [[ "$prompt_delete" == "true" ]] || return 1
  [[ "$dedupe_enabled" == "false" ]] || return 1
  [[ "$recursive" == "false" ]] || return 1
  [[ "$quiet" == "false" ]] || return 1
  [[ "$all_directory" == "false" ]] || return 1
  [[ "$global_dedupe" == "false" ]] || return 1
  (( ${#exclude_patterns[@]} == 0 )) || return 1

  local normalized_algorithm
  normalized_algorithm="$(printf '%s' "$algorithm" | tr '[:upper:]' '[:lower:]')"
  [[ "$normalized_algorithm" == "blake3" ]]
}

gather_existing_dups_directories() {
  dups_dirs=()

  local stack=(".")
  while (( ${#stack[@]} > 0 )); do
    local dir_rel="${stack[$(( ${#stack[@]} - 1 ))]}"
    unset 'stack[$(( ${#stack[@]} - 1 ))]'

    local search_dir="$dir_rel"
    local names=()
    local candidate
    shopt -s nullglob dotglob
    for candidate in "$search_dir"/*; do
      [[ -d "$candidate" ]] || continue
      [[ -L "$candidate" ]] && continue
      local base_name="${candidate##*/}"
      if [[ "$base_name" == ".dups" ]]; then
        local dups_rel
        if [[ "$dir_rel" == "." ]]; then
          dups_rel=".dups"
        else
          dups_rel="$dir_rel/.dups"
        fi
        remember_dups_dir "$dups_rel"
        continue
      fi

      names+=("$base_name")
    done
    shopt -u nullglob dotglob

    local sorted_names=()
    local name
    if (( ${#names[@]} > 0 )); then
      while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        sorted_names+=("$name")
      done < <(printf '%s\n' "${names[@]}" | LC_ALL=C sort)
    fi

    local i
    for (( i=${#sorted_names[@]}-1; i>=0; i-- )); do
      local sub="${sorted_names[$i]}"
      if [[ "$dir_rel" == "." ]]; then
        stack+=("$sub")
      else
        stack+=("$dir_rel/$sub")
      fi
    done
  done
}

collect_files_for_global_scope() {
  current_group_files=()

  if [[ "$recursive" != "true" ]]; then
    collect_files_for_directory "."
    return
  fi

  local all_files=()
  local stack=(".")

  while (( ${#stack[@]} > 0 )); do
    local dir_rel="${stack[$(( ${#stack[@]} - 1 ))]}"
    unset 'stack[$(( ${#stack[@]} - 1 ))]'
    summary_directories=$((summary_directories + 1))

    collect_files_for_directory "$dir_rel"
    if (( ${#current_group_files[@]} > 0 )); then
      all_files+=("${current_group_files[@]}")
    fi
    collect_subdirs_for_directory "$dir_rel"

    local i
    for (( i=${#current_subdirs[@]}-1; i>=0; i-- )); do
      local sub="${current_subdirs[$i]}"
      if [[ "$dir_rel" == "." ]]; then
        stack+=("$sub")
      else
        stack+=("$dir_rel/$sub")
      fi
    done
  done

  current_group_files=("${all_files[@]}")
}

to_absolute_path() {
  local path="$1"
  if [[ "$path" == /* ]]; then
    printf '%s' "$path"
    return
  fi

  local cwd
  cwd="$(pwd -P)"
  if [[ "$path" == "." ]]; then
    printf '%s' "$cwd"
  elif [[ "$path" == ./* ]]; then
    printf '%s/%s' "$cwd" "${path#./}"
  else
    printf '%s/%s' "$cwd" "$path"
  fi
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

is_program_mime_type() {
  local mime_type="$1"
  local normalized

  normalized="$(printf '%s' "$mime_type" | tr '[:upper:]' '[:lower:]')"

  case "$normalized" in
    application/x-executable|application/x-pie-executable|application/x-mach-binary|application/x-dosexec|application/vnd.microsoft.portable-executable|application/x-shellscript|text/x-shellscript|text/x-python|text/x-perl|text/x-ruby|text/x-php|text/x-lua|text/x-tcl)
      return 0
      ;;
  esac

  if [[ "$normalized" == application/*program* ]]; then
    return 0
  fi

  if [[ "$normalized" == text/x-*script* ]]; then
    return 0
  fi

  return 1
}

has_any_execute_permission_bit() {
  local file="$1"
  local mode

  if [[ "$is_macos" == "true" ]]; then
    mode="$(stat -f %Lp -- "$file" 2>/dev/null || true)"
  else
    mode="$(stat -c %a -- "$file" 2>/dev/null || stat -f %Lp -- "$file" 2>/dev/null || true)"
  fi

  [[ -n "$mode" ]] || return 1

  # Keep the permission bits only (last 3 octal digits).
  mode="${mode: -3}"

  if (( (8#$mode & 8#111) != 0 )); then
    return 0
  fi

  return 1
}

has_shebang_prefix() {
  local file="$1"
  local prefix

  prefix="$(head -c 2 -- "$file" 2>/dev/null || true)"
  [[ "$prefix" == '#!' ]]
}

is_executable_program_for_dedupe() {
  local file="$1"

  has_any_execute_permission_bit "$file" || return 1
  has_shebang_prefix "$file" && return 0
  command -v file >/dev/null 2>&1 || return 1

  local mime_type
  if ! mime_type="$(file --mime-type -b -- "$file" 2>/dev/null)"; then
    return 1
  fi

  is_program_mime_type "$mime_type"
}

detect_console_width() {
  console_width=0

  if [[ -n "${LSHASH_CONSOLE_WIDTH:-}" && "$LSHASH_CONSOLE_WIDTH" =~ ^[0-9]+$ && "$LSHASH_CONSOLE_WIDTH" -gt 0 ]]; then
    console_width="$LSHASH_CONSOLE_WIDTH"
    return
  fi

  if [[ -n "${COLUMNS:-}" && "$COLUMNS" =~ ^[0-9]+$ && "$COLUMNS" -gt 0 ]]; then
    console_width="$COLUMNS"
    return
  fi

  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    local cols
    cols="$(tput cols 2>/dev/null || true)"
    if [[ "$cols" =~ ^[0-9]+$ && "$cols" -gt 0 ]]; then
      console_width="$cols"
      return
    fi
  fi

  if [[ -t 1 ]]; then
    local stty_size
    stty_size="$(stty size 2>/dev/null || true)"
    local cols="${stty_size##* }"
    if [[ "$cols" =~ ^[0-9]+$ && "$cols" -gt 0 ]]; then
      console_width="$cols"
      return
    fi
  fi

  if [[ -t 1 ]]; then
    # Conservative fallback for interactive terminals when width cannot be detected.
    console_width=80
  fi
}

strip_ansi_codes() {
  local text="$1"
  printf '%s' "$text" | sed -E $'s/\x1b\[[0-9;]*m//g'
}

visible_text_length() {
  local text="$1"
  local plain
  plain="$(strip_ansi_codes "$text")"
  printf '%d' "${#plain}"
}

truncate_right_with_ellipsis() {
  local text="$1"
  local max_width="$2"

  if (( max_width <= 0 )); then
    printf ''
    return
  fi

  if (( ${#text} <= max_width )); then
    printf '%s' "$text"
    return
  fi

  if (( max_width <= 3 )); then
    printf '%*s' "$max_width" '' | tr ' ' '.'
    return
  fi

  printf '%s...' "${text:0:max_width-3}"
}

repeat_middle_dots() {
  local count="$1"
  local dots=""
  local i

  for (( i=0; i<count; i++ )); do
    dots+="·"
  done

  printf '%s' "$dots"
}

format_name_field() {
  local display_name="$1"
  local display_hash="$2"
  local fallback_width="$3"
  local italicize="$4"
  local gray=$'\033[37m'
  local italic=$'\033[3m'
  local reset=$'\033[0m'

  local field_width="$fallback_width"
  if (( console_width > 0 )); then
    local hash_len
    hash_len="$(visible_text_length "$display_hash")"
    field_width=$(( console_width - hash_len ))
  fi

  if (( field_width <= 0 )); then
    field_width=3
  fi

  local fitted_name
  fitted_name="$(truncate_right_with_ellipsis "$display_name" "$field_width")"
  local fitted_len=${#fitted_name}
  local pad_count=$(( field_width - fitted_len ))
  if (( pad_count < 0 )); then
    pad_count=0
  fi

  local pad=""
  if (( pad_count > 0 )); then
    pad="$(repeat_middle_dots "$pad_count")"
  fi

  if [[ "$italicize" == "true" ]]; then
    if (( pad_count > 0 )); then
      printf '%b%s%b%b%s%b' "$italic" "$fitted_name" "$reset" "$gray" "$pad" "$reset"
    else
      printf '%b%s%b' "$italic" "$fitted_name" "$reset"
    fi
    return
  fi

  if (( pad_count > 0 )); then
    printf '%s%b%s%b' "$fitted_name" "$gray" "$pad" "$reset"
  else
    printf '%s' "$fitted_name"
  fi
}

format_moved_name_field() {
  local file_name="$1"
  local moved_suffix="$2"
  local display_hash="$3"
  local fallback_width="$4"
  local gray=$'\033[37m'
  local italic=$'\033[3m'
  local reset=$'\033[0m'

  local field_width="$fallback_width"
  if (( console_width > 0 )); then
    local hash_len
    hash_len="$(visible_text_length "$display_hash")"
    field_width=$(( console_width - hash_len ))
  fi

  if (( field_width <= 0 )); then
    field_width=3
  fi

  local fitted_name
  local suffix_len=${#moved_suffix}
  if (( field_width <= suffix_len )); then
    fitted_name="$(truncate_right_with_ellipsis "$moved_suffix" "$field_width")"
  else
    local file_width=$(( field_width - suffix_len ))
    local fitted_file
    fitted_file="$(truncate_right_with_ellipsis "$file_name" "$file_width")"
    fitted_name="${fitted_file}${moved_suffix}"
  fi

  local fitted_len=${#fitted_name}
  local pad_count=$(( field_width - fitted_len ))
  if (( pad_count < 0 )); then
    pad_count=0
  fi

  local pad=""
  if (( pad_count > 0 )); then
    pad="$(repeat_middle_dots "$pad_count")"
  fi

  if (( pad_count > 0 )); then
    printf '%b%s%b%b%s%b' "$italic" "$fitted_name" "$reset" "$gray" "$pad" "$reset"
  else
    printf '%b%s%b' "$italic" "$fitted_name" "$reset"
  fi
}

format_percent() {
  local numerator="$1"
  local denominator="$2"

  if (( denominator <= 0 )); then
    printf '0.00'
    return
  fi

  local basis_points=$(( numerator * 10000 / denominator ))
  printf '%d.%02d' $(( basis_points / 100 )) $(( basis_points % 100 ))
}

print_summary() {
  local duplicates_reported
  local duplicate_phrase
  local yellow_bold=$'\033[1;33m'
  local reset=$'\033[0m'

  if [[ "$dedupe_enabled" == "true" ]]; then
    duplicates_reported="$summary_moved_files"
    duplicate_phrase="were found and moved"
  else
    duplicates_reported="$summary_duplicate_files"
    duplicate_phrase="were found"
  fi

  local duplicate_percent
  duplicate_percent="$(format_percent "$duplicates_reported" "$summary_total_files")"

  if [[ "$recursive" == "true" ]]; then
    printf '%bSummary: scanned %d file(s); %d duplicate file(s) %s (%s%% of scanned files); %d directories were traversed.%b\n' \
      "$yellow_bold" "$summary_total_files" "$duplicates_reported" "$duplicate_phrase" "$duplicate_percent" "$summary_directories" "$reset"
  else
    printf '%bSummary: scanned %d file(s); %d duplicate file(s) %s (%s%% of scanned files).%b\n' \
      "$yellow_bold" "$summary_total_files" "$duplicates_reported" "$duplicate_phrase" "$duplicate_percent" "$reset"
  fi
}

print_non_dedupe_group() {
  local max_name_len=0
  local file

  for file in "${current_group_files[@]}"; do
    if (( ${#file} > max_name_len )); then
      max_name_len=${#file}
    fi
  done

  local green=$'\033[32m'
  local reset=$'\033[0m'

  for file in "${current_group_files[@]}"; do
    local hash
    if ! hash="$(try_hash_file "$file")"; then
      if [[ "$quiet" != "true" ]]; then
        local display_hash="<hash unavailable>"
        local display_name
          display_name="$(format_name_field "$file" "$display_hash" "$max_name_len" "false")"
          printf "%s%s\n" "$display_name" "$display_hash"
      fi
      continue
    fi

    local is_duplicate="false"
    local display_hash="$hash"
    if [[ -n "$prev_hash" && "$hash" == "$prev_hash" ]]; then
      display_hash="${green}${hash}${reset}"
      is_duplicate="true"
      summary_duplicate_files=$((summary_duplicate_files + 1))
    fi

    if [[ "$quiet" != "true" || "$is_duplicate" == "true" ]]; then
      local display_name
      display_name="$(format_name_field "$file" "$display_hash" "$max_name_len" "false")"
      printf "%s%b\n" "$display_name" "$display_hash"
    fi

    prev_hash="$hash"
  done
}

print_dedupe_group() {
  local dir_rel="$1"

  local moved_suffix=" (moved to .dups/)"
  local max_name_len=0
  local file
  for file in "${current_group_files[@]}"; do
    local possible_len=$(( ${#file} + ${#moved_suffix} ))
    if (( possible_len > max_name_len )); then
      max_name_len=$possible_len
    fi
  done

  local green=$'\033[32m'
  local italic=$'\033[3m'
  local reset=$'\033[0m'

  local run_active="false"
  local run_hash=""
  local run_files=()
  local run_hashes=()
  local run_hash_valid=()
  local run_excluded_exec=()
  local run_basenames=()
  local run_mtimes=()
  local run_mtime_valid=()
  local run_moved_flags=()
  local run_moved_paths=()

  resolve_dups_dir_for_file() {
    local file_path="$1"
    local fallback_dir_rel="$2"

    if [[ "$global_scope_active" == "true" ]]; then
      local source_dir="${file_path%/*}"
      if [[ "$source_dir" == "$file_path" ]]; then
        printf '.dups'
      else
        printf '%s/.dups' "$source_dir"
      fi
      return
    fi

    if [[ "$fallback_dir_rel" == "." ]]; then
      printf '.dups'
    else
      printf '%s/.dups' "$fallback_dir_rel"
    fi
  }

  write_global_metadata_for_indices() {
    local hash="$1"
    shift
    local indices=("$@")

    if [[ "$global_scope_active" != "true" ]]; then
      return 0
    fi

    if (( ${#indices[@]} < 2 )); then
      return 0
    fi

    local subject_idx
    for subject_idx in "${indices[@]}"; do
      [[ "${run_moved_flags[$subject_idx]}" == "1" ]] || continue
      local subject_path="${run_moved_paths[$subject_idx]}"
      [[ -n "$subject_path" ]] || continue

      local metadata_path="${subject_path}.json"
      local escaped_hash
      escaped_hash="$(json_escape "$hash")"
      local escaped_mode
      escaped_mode="$(json_escape "$dedupe_mode")"
      local escaped_subject
      escaped_subject="$(json_escape "$(to_absolute_path "$subject_path")")"

      {
        printf '{\n'
        printf '  "hash": "%s",\n' "$escaped_hash"
        printf '  "dedupeMode": "%s",\n' "$escaped_mode"
        printf '  "subject": {\n'
        printf '    "path": "%s",\n' "$escaped_subject"
        printf '    "status": "moved"\n'
        printf '  },\n'
        printf '  "others": [\n'

        local first="true"
        local idx
        for idx in "${indices[@]}"; do
          if [[ "$idx" == "$subject_idx" ]]; then
            continue
          fi

          local other_status="kept"
          local other_path_rel="${run_files[$idx]}"
          if [[ "${run_moved_flags[$idx]}" == "1" && -n "${run_moved_paths[$idx]}" ]]; then
            other_status="moved"
            other_path_rel="${run_moved_paths[$idx]}"
          fi

          local other_path_abs
          other_path_abs="$(to_absolute_path "$other_path_rel")"
          local escaped_other_path
          escaped_other_path="$(json_escape "$other_path_abs")"

          if [[ "$first" != "true" ]]; then
            printf ',\n'
          fi
          first="false"
          printf '    {"path": "%s", "status": "%s"}' "$escaped_other_path" "$other_status"
        done

        printf '\n'
        printf '  ]\n'
        printf '}\n'
      } > "$metadata_path" || warn_file_issue "write metadata" "$metadata_path" "failed to write metadata json"
    done
  }

  print_all_entries() {
    local count=${#run_files[@]}
    local j
    for (( j=0; j<count; j++ )); do
      local display_hash
      local is_duplicate="false"
      if [[ "${run_excluded_exec[$j]}" == "1" ]]; then
        display_hash="<excluded executable program>"
      elif [[ "${run_hash_valid[$j]}" == "1" ]]; then
        local hash="${run_hashes[$j]}"
        display_hash="$hash"
        if [[ -n "$prev_hash" && "$hash" == "$prev_hash" ]]; then
          display_hash="${green}${hash}${reset}"
          is_duplicate="true"
          summary_duplicate_files=$((summary_duplicate_files + 1))
        fi
        prev_hash="$hash"
      else
        display_hash="<hash unavailable>"
      fi

      if [[ "$quiet" != "true" || "$is_duplicate" == "true" ]]; then
        local formatted_name
        if [[ "${run_moved_flags[$j]}" == "1" ]]; then
          formatted_name="$(format_moved_name_field "${run_files[$j]}" "$moved_suffix" "$display_hash" "$max_name_len")"
        else
          formatted_name="$(format_name_field "${run_files[$j]}" "$display_hash" "$max_name_len" "false")"
        fi
        printf "%s%b\n" "$formatted_name" "$display_hash"
      fi
    done
  }

  flush_run() {
    if [[ "$run_active" != "true" ]]; then
      return
    fi

    local run_count=${#run_files[@]}
    local hashable_indices=()
    local j
    for (( j=0; j<run_count; j++ )); do
      if [[ "${run_hash_valid[$j]}" == "1" ]]; then
        hashable_indices+=("$j")
      fi
    done

    if (( ${#hashable_indices[@]} >= 2 )); then
      local keep_idx="${hashable_indices[0]}"
      local candidate_idx
      for candidate_idx in "${hashable_indices[@]:1}"; do
        local choose_candidate="false"
        case "$dedupe_mode" in
          newer)
            if [[ "${run_mtime_valid[$candidate_idx]}" == "1" && "${run_mtime_valid[$keep_idx]}" == "0" ]]; then
              choose_candidate="true"
            elif [[ "${run_mtime_valid[$candidate_idx]}" == "1" && "${run_mtime_valid[$keep_idx]}" == "1" ]] && (( ${run_mtimes[$candidate_idx]} > ${run_mtimes[$keep_idx]} )); then
              choose_candidate="true"
            fi
            ;;
          older)
            if [[ "${run_mtime_valid[$candidate_idx]}" == "1" && "${run_mtime_valid[$keep_idx]}" == "0" ]]; then
              choose_candidate="true"
            elif [[ "${run_mtime_valid[$candidate_idx]}" == "1" && "${run_mtime_valid[$keep_idx]}" == "1" ]] && (( ${run_mtimes[$candidate_idx]} < ${run_mtimes[$keep_idx]} )); then
              choose_candidate="true"
            fi
            ;;
          shorter)
            if (( ${#run_basenames[$candidate_idx]} < ${#run_basenames[$keep_idx]} )); then
              choose_candidate="true"
            fi
            ;;
          longer)
            if (( ${#run_basenames[$candidate_idx]} > ${#run_basenames[$keep_idx]} )); then
              choose_candidate="true"
            fi
            ;;
        esac

        if [[ "$choose_candidate" == "true" ]]; then
          keep_idx="$candidate_idx"
        fi
      done

      for candidate_idx in "${hashable_indices[@]}"; do
        if [[ "$candidate_idx" == "$keep_idx" ]]; then
          continue
        fi

        local source_path="${run_files[$candidate_idx]}"
        local dups_dir
        dups_dir="$(resolve_dups_dir_for_file "$source_path" "$dir_rel")"

        mkdir -p -- "$dups_dir"
        local target_path="$dups_dir/${run_basenames[$candidate_idx]}"
        if [[ -e "$target_path" ]]; then
          local suffix=1
          while [[ -e "$dups_dir/${run_basenames[$candidate_idx]}.dup$suffix" ]]; do
            suffix=$((suffix + 1))
          done
          target_path="$dups_dir/${run_basenames[$candidate_idx]}.dup$suffix"
        fi

        if safe_move_file "$source_path" "$target_path"; then
          run_moved_flags[$candidate_idx]="1"
          run_moved_paths[$candidate_idx]="$target_path"
          remember_dups_dir "$dups_dir"
            summary_moved_files=$((summary_moved_files + 1))
        fi
      done

      write_global_metadata_for_indices "$run_hash" "${hashable_indices[@]}"
    fi

    print_all_entries

    run_active="false"
    run_hash=""
    run_files=()
    run_hashes=()
    run_hash_valid=()
    run_excluded_exec=()
    run_basenames=()
    run_mtimes=()
    run_mtime_valid=()
    run_moved_flags=()
    run_moved_paths=()
  }

  if [[ "$all_directory" == "true" ]]; then
    for file in "${current_group_files[@]}"; do
      local base_name="${file##*/}"

      local hash_valid="0"
      local hash=""
      local excluded_exec="0"
      if is_executable_program_for_dedupe "$file"; then
        excluded_exec="1"
      elif hash="$(try_hash_file "$file")"; then
        hash_valid="1"
      fi

      local mtime_valid="0"
      local mtime="0"
      if mtime="$(try_get_file_mtime "$file")"; then
        mtime_valid="1"
      fi

      run_files+=("$file")
      run_hashes+=("$hash")
      run_hash_valid+=("$hash_valid")
      run_excluded_exec+=("$excluded_exec")
      run_basenames+=("$base_name")
      run_mtimes+=("$mtime")
      run_mtime_valid+=("$mtime_valid")
      run_moved_flags+=("0")
      run_moved_paths+=("")
    done

    local entry_count=${#run_files[@]}
    local processed_flags=()
    local i
    for (( i=0; i<entry_count; i++ )); do
      processed_flags+=("0")
    done

    for (( i=0; i<entry_count; i++ )); do
      if [[ "${processed_flags[$i]}" == "1" ]]; then
        continue
      fi
      if [[ "${run_hash_valid[$i]}" != "1" ]]; then
        continue
      fi

      local group_hash="${run_hashes[$i]}"
      local indices=("$i")
      processed_flags[$i]="1"

      local j
      for (( j=i+1; j<entry_count; j++ )); do
        if [[ "${processed_flags[$j]}" == "1" ]]; then
          continue
        fi
        if [[ "${run_hash_valid[$j]}" == "1" && "${run_hashes[$j]}" == "$group_hash" ]]; then
          indices+=("$j")
          processed_flags[$j]="1"
        fi
      done

      if (( ${#indices[@]} < 2 )); then
        continue
      fi

      local keep_idx="${indices[0]}"
      local candidate_idx
      for candidate_idx in "${indices[@]:1}"; do
        local choose_candidate="false"
        case "$dedupe_mode" in
          newer)
            if [[ "${run_mtime_valid[$candidate_idx]}" == "1" && "${run_mtime_valid[$keep_idx]}" == "0" ]]; then
              choose_candidate="true"
            elif [[ "${run_mtime_valid[$candidate_idx]}" == "1" && "${run_mtime_valid[$keep_idx]}" == "1" ]] && (( ${run_mtimes[$candidate_idx]} > ${run_mtimes[$keep_idx]} )); then
              choose_candidate="true"
            fi
            ;;
          older)
            if [[ "${run_mtime_valid[$candidate_idx]}" == "1" && "${run_mtime_valid[$keep_idx]}" == "0" ]]; then
              choose_candidate="true"
            elif [[ "${run_mtime_valid[$candidate_idx]}" == "1" && "${run_mtime_valid[$keep_idx]}" == "1" ]] && (( ${run_mtimes[$candidate_idx]} < ${run_mtimes[$keep_idx]} )); then
              choose_candidate="true"
            fi
            ;;
          shorter)
            if (( ${#run_basenames[$candidate_idx]} < ${#run_basenames[$keep_idx]} )); then
              choose_candidate="true"
            fi
            ;;
          longer)
            if (( ${#run_basenames[$candidate_idx]} > ${#run_basenames[$keep_idx]} )); then
              choose_candidate="true"
            fi
            ;;
        esac

        if [[ "$choose_candidate" == "true" ]]; then
          keep_idx="$candidate_idx"
        fi
      done

      for candidate_idx in "${indices[@]}"; do
        if [[ "$candidate_idx" == "$keep_idx" ]]; then
          continue
        fi

        local source_path="${run_files[$candidate_idx]}"
        local dups_dir
        dups_dir="$(resolve_dups_dir_for_file "$source_path" "$dir_rel")"

        mkdir -p -- "$dups_dir"
        local target_path="$dups_dir/${run_basenames[$candidate_idx]}"
        if [[ -e "$target_path" ]]; then
          local suffix=1
          while [[ -e "$dups_dir/${run_basenames[$candidate_idx]}.dup$suffix" ]]; do
            suffix=$((suffix + 1))
          done
          target_path="$dups_dir/${run_basenames[$candidate_idx]}.dup$suffix"
        fi

        if safe_move_file "$source_path" "$target_path"; then
          run_moved_flags[$candidate_idx]="1"
          run_moved_paths[$candidate_idx]="$target_path"
          remember_dups_dir "$dups_dir"
          summary_moved_files=$((summary_moved_files + 1))
        fi
      done

      write_global_metadata_for_indices "$group_hash" "${indices[@]}"
    done

    print_all_entries
    return
  fi

  for file in "${current_group_files[@]}"; do
    local base_name="${file##*/}"

    local hash_valid="0"
    local hash=""
    local excluded_exec="0"
    if is_executable_program_for_dedupe "$file"; then
      excluded_exec="1"
    elif hash="$(try_hash_file "$file")"; then
      hash_valid="1"
    fi

    local mtime_valid="0"
    local mtime="0"
    if mtime="$(try_get_file_mtime "$file")"; then
      mtime_valid="1"
    fi

    if [[ "$run_active" != "true" ]]; then
      if [[ "$hash_valid" == "1" ]]; then
        run_active="true"
        run_hash="$hash"
        run_files+=("$file")
        run_hashes+=("$hash")
        run_hash_valid+=("1")
        run_excluded_exec+=("0")
        run_basenames+=("$base_name")
        run_mtimes+=("$mtime")
        run_mtime_valid+=("$mtime_valid")
        run_moved_flags+=("0")
        run_moved_paths+=("")
      else
        if [[ "$quiet" != "true" ]]; then
          if [[ "$excluded_exec" == "1" ]]; then
            printf "%-*s  %s\n" "$max_name_len" "$file" "<excluded executable program>"
          else
            printf "%-*s  %s\n" "$max_name_len" "$file" "<hash unavailable>"
          fi
        fi
      fi
      continue
    fi

    if [[ "$hash_valid" == "0" ]]; then
      run_files+=("$file")
      run_hashes+=("")
      run_hash_valid+=("0")
      run_excluded_exec+=("$excluded_exec")
      run_basenames+=("$base_name")
      run_mtimes+=("$mtime")
      run_mtime_valid+=("$mtime_valid")
      run_moved_flags+=("0")
      run_moved_paths+=("")
      continue
    fi

    if [[ "$hash" == "$run_hash" ]]; then
      run_files+=("$file")
      run_hashes+=("$hash")
      run_hash_valid+=("1")
      run_excluded_exec+=("0")
      run_basenames+=("$base_name")
      run_mtimes+=("$mtime")
      run_mtime_valid+=("$mtime_valid")
      run_moved_flags+=("0")
      run_moved_paths+=("")
      continue
    fi

    flush_run

    run_active="true"
    run_hash="$hash"
    run_files=("$file")
    run_hashes=("$hash")
    run_hash_valid=("1")
    run_excluded_exec=("0")
    run_basenames=("$base_name")
    run_mtimes=("$mtime")
    run_mtime_valid=("$mtime_valid")
    run_moved_flags=("0")
    run_moved_paths=("")
  done

  flush_run
}

process_directory_files() {
  local dir_rel="$1"

  summary_total_files=$((summary_total_files + ${#current_group_files[@]}))

  if (( ${#current_group_files[@]} == 0 )); then
    return
  fi

  if [[ "$dedupe_enabled" == "true" ]]; then
    print_dedupe_group "$dir_rel"
  else
    print_non_dedupe_group
  fi
}

collect_files_for_directory() {
  local dir_rel="$1"
  current_group_files=()

  local search_dir
  if [[ "$dir_rel" == "." ]]; then
    search_dir="."
  else
    search_dir="$dir_rel"
  fi

  local names=()
  local candidate
  shopt -s nullglob dotglob
  for candidate in "$search_dir"/*; do
    [[ -f "$candidate" ]] || continue
    [[ -L "$candidate" ]] && continue
    names+=("${candidate##*/}")
  done
  shopt -u nullglob dotglob

  local name
  if (( ${#names[@]} > 0 )); then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local rel
      if [[ "$dir_rel" == "." ]]; then
        rel="$name"
      else
        rel="$dir_rel/$name"
      fi

      if should_exclude "$rel"; then
        continue
      fi

      current_group_files+=("$rel")
    done < <(printf '%s\n' "${names[@]}" | LC_ALL=C sort)
  fi
}

collect_subdirs_for_directory() {
  local dir_rel="$1"
  current_subdirs=()

  local search_dir
  if [[ "$dir_rel" == "." ]]; then
    search_dir="."
  else
    search_dir="$dir_rel"
  fi

  local names=()
  local candidate
  shopt -s nullglob dotglob
  for candidate in "$search_dir"/*; do
    [[ -d "$candidate" ]] || continue
    [[ -L "$candidate" ]] && continue
    local base_name="${candidate##*/}"
    [[ "$base_name" == ".dups" ]] && continue
    names+=("$base_name")
  done
  shopt -u nullglob dotglob

  local name
  if (( ${#names[@]} > 0 )); then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      current_subdirs+=("$name")
    done < <(printf '%s\n' "${names[@]}" | LC_ALL=C sort)
  fi
}

walk_recursive_and_process() {
  local stack=(".")

  while (( ${#stack[@]} > 0 )); do
    local dir_rel="${stack[$(( ${#stack[@]} - 1 ))]}"
    unset 'stack[$(( ${#stack[@]} - 1 ))]'
    summary_directories=$((summary_directories + 1))

    collect_files_for_directory "$dir_rel"
    process_directory_files "$dir_rel"
    collect_subdirs_for_directory "$dir_rel"

    local i
    for (( i=${#current_subdirs[@]}-1; i>=0; i-- )); do
      local sub="${current_subdirs[$i]}"
      if [[ "$dir_rel" == "." ]]; then
        stack+=("$sub")
      else
        stack+=("$dir_rel/$sub")
      fi
    done
  done
}

parse_args "$@"

if ! cd -- "$target_dir"; then
  echo "Cannot access directory: $target_dir" >&2
  exit 1
fi

if is_prompt_delete_garbage_collect_mode; then
  gather_existing_dups_directories
  print_existing_dups_directories
  prompt_delete_dups_directories
  exit 0
fi

detect_console_width

algorithm="$(printf '%s' "$algorithm" | tr '[:upper:]' '[:lower:]')"
dedupe_mode="$(printf '%s' "$dedupe_mode" | tr '[:upper:]' '[:lower:]')"

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

if [[ "$dedupe_enabled" == "true" && "$global_dedupe" == "true" ]]; then
  all_directory="true"
  if [[ "$recursive" == "true" ]]; then
    global_scope_active="true"
    collect_files_for_global_scope
    process_directory_files "."
    global_scope_active="false"
  else
    collect_files_for_directory "."
    process_directory_files "."
  fi
elif [[ "$recursive" == "true" ]]; then
  walk_recursive_and_process
else
  collect_files_for_directory "."
  process_directory_files "."
fi

print_summary

if [[ "$dedupe_enabled" == "true" ]]; then
  print_dups_directories
fi

if [[ "$dedupe_enabled" == "true" && "$prompt_delete" == "true" ]]; then
  prompt_delete_dups_directories
fi
