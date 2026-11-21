#!/usr/bin/env bash
# Pick a model and mmproj (from recent picks or a whiptail file browser), then serve
# them with llama.cpp, all prompt caching off. Each request is prefilled from scratch.
# Options from a config file (one per line) and the command line override the defaults,
# e.g. --port 8899. When they already set the model and mmproj, no TUI is shown.
set -euo pipefail

# The shc-built binary has no BASH_SOURCE, and its $0 is a bare name when found on PATH.
if [[ -n ${BASH_SOURCE[0]:-} ]]; then
  self=${BASH_SOURCE[0]}
else
  self=$0
  [[ $self == */* ]] || self=$(type -P "$self")
fi
# readlink -f keeps these next to the real script even when run through a symlink.
SCRIPT_DIR=$(dirname "$(readlink -f "$self")")
# Loaded when present; --config <file> loads another file instead.
DEFAULT_CONFIG="$SCRIPT_DIR/llama-server.args"
# The file browser starts here; use ".." to go anywhere else.
MODELS_ROOT="$HOME"
SKIP_ITEM="(no mmproj)"
# One "model<TAB>mmproj" per line, newest first; mmproj is empty for SKIP_ITEM.
HISTORY_FILE="$SCRIPT_DIR/.cache/llama-server-history.tsv"
HISTORY_SIZE=5
# Passed to llama serve before the config file and command-line options.
DEFAULT_ARGS=(
  --host 127.0.0.1
  --port 8888
  --ctx-size 32768
  --n-gpu-layers all
  --parallel 1
  --no-cache-prompt
  --cache-ram 0
  --ctx-checkpoints 0
)

cancel() {
  echo "Cancelled." >&2
  exit 1
}

# type -P only matches executables on PATH, never aliases or functions.
LLAMA_BIN=$(type -P llama) || {
  echo "llama CLI not found in PATH. Install llama.cpp so that 'llama serve' works." >&2
  exit 1
}

# Browse from $2 and print the picked .gguf path; prints nothing if SKIP_ITEM is picked.
# Returns 1 on Cancel/Esc.
pick_gguf() {
  local title=$1 dir=$2 can_skip=${3:-}
  local entries path name choice
  while true; do
    entries=()
    [[ -n $can_skip ]] && entries+=("$SKIP_ITEM" "")
    [[ $dir != / ]] && entries+=(".." "")
    while IFS= read -r -d '' path; do
      name=${path##*/}
      if [[ -d $path ]]; then
        entries+=("$name/" "")
      else
        entries+=("$name" "$(du -h --apparent-size "$path" | cut -f1)")
      fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -not -name '.*' \( -type d -o -iname '*.gguf' \) -print0 | sort -z)

    choice=$(whiptail --title "$title" --menu "$dir" 0 0 0 "${entries[@]}" 3>&1 1>&2 2>&3) || return 1
    case $choice in
      "$SKIP_ITEM") return 0 ;;
      ..) dir=$(dirname "$dir") ;;
      */) dir="${dir%/}/${choice%/}" ;;
      *) printf '%s\n' "${dir%/}/$choice"; return 0 ;;
    esac
  done
}

# Print this script's own options and defaults; the llama serve help follows it.
print_help() {
  local arg separator=
  cat <<EOF
Usage: ${self##*/} [--config FILE] [llama serve options...]

Pick a model and mmproj in a TUI (recent picks or a file browser), then run llama serve.

Options handled by this script:
  --config FILE, --config=FILE  Load llama serve options from FILE, one per line.
                                Default: $DEFAULT_CONFIG (loaded when present).
  -h, --help                    Show this help, then the llama serve help.

Every other option goes to llama serve as-is (see below).
-m/--model skips the model pick; -mm/--mmproj or --no-mmproj skips the mmproj pick.

Defaults passed to llama serve (the config file overrides them, the command line overrides both):
EOF
  for arg in "${DEFAULT_ARGS[@]}"; do
    if [[ $arg == -* ]]; then
      printf '%s  %s' "$separator" "$arg"
      separator=$'\n'
    else
      printf ' %s' "$arg"
    fi
  done
  cat <<EOF


Examples:
  ${self##*/} --port 8899
  ${self##*/} --config my-model.args

----- llama serve --help -----

EOF
}

# Take out --config and -h/--help; every other argument goes to llama serve as-is.
config_file=$DEFAULT_CONFIG
is_config_required=
cli_args=()
while (($#)); do
  case $1 in
    --config)
      (($# >= 2)) || { echo "--config needs a file path." >&2; exit 1; }
      config_file=$2
      is_config_required=1
      shift 2
      ;;
    --config=*)
      config_file=${1#*=}
      is_config_required=1
      shift
      ;;
    -h | --help)
      print_help
      exec "$LLAMA_BIN" serve --help
      ;;
    *)
      cli_args+=("$1")
      shift
      ;;
  esac
done

# One option per line: "--opt value" or "--opt=value" (llama.cpp only takes the first form).
# Blank lines and lines starting with "#" are skipped.
config_args=()
if [[ -f $config_file ]]; then
  echo "config: $config_file"
  while read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    option=${line%%[[:space:]=]*}
    config_args+=("$option")
    if [[ $line != "$option" ]]; then
      read -r value <<< "${line:${#option}+1}"
      config_args+=("$value")
    fi
  done < "$config_file"
elif [[ -n $is_config_required ]]; then
  echo "Config file not found: $config_file" >&2
  exit 1
fi

# A model or mmproj already set by the config or the command line skips its TUI step.
model=
mmproj=
has_model=
has_mmproj=
given_args=("${config_args[@]}" "${cli_args[@]}")
for ((i = 0; i < ${#given_args[@]}; i++)); do
  case ${given_args[i]} in
    -m | --model) model=${given_args[i + 1]:-}; has_model=1 ;;
    -mm | --mmproj) mmproj=${given_args[i + 1]:-}; has_mmproj=1 ;;
    --no-mmproj) mmproj=; has_mmproj=1 ;;
  esac
done

picked_args=()
if [[ -z $has_model || -z $has_mmproj ]]; then
  # Without this check a missing whiptail would look like a Cancel.
  command -v whiptail >/dev/null || {
    echo "whiptail not found. Install it, e.g. 'sudo apt install whiptail'." >&2
    exit 1
  }

  # Recent picks whose files still exist; offered only when neither is set yet.
  recent_models=()
  recent_mmprojs=()
  recent_items=()
  if [[ -z $has_model && -z $has_mmproj && -f $HISTORY_FILE ]]; then
    while IFS=$'\t' read -r recent_model recent_mmproj; do
      [[ -f $recent_model && ( -z $recent_mmproj || -f $recent_mmproj ) ]] || continue
      recent_models+=("$recent_model")
      recent_mmprojs+=("$recent_mmproj")
      mmproj_name=${recent_mmproj##*/}
      recent_items+=("${#recent_models[@]}" "${recent_model##*/}  +  ${mmproj_name:-$SKIP_ITEM}")
    done < "$HISTORY_FILE"
  fi

  choice=B
  if ((${#recent_items[@]})); then
    choice=$(whiptail --title "Recent models" --menu "Pick a recent model + mmproj, or browse files." 0 0 0 \
      "${recent_items[@]}" B "Browse files..." 3>&1 1>&2 2>&3) || cancel
  fi

  if [[ $choice == B ]]; then
    [[ -n $has_model ]] || model=$(pick_gguf "Select model (.gguf)" "$MODELS_ROOT") || cancel
    [[ -n $has_mmproj ]] || mmproj=$(pick_gguf "Select mmproj (.gguf)" "$(dirname "$model")" can_skip) || cancel
  else
    model=${recent_models[choice - 1]}
    mmproj=${recent_mmprojs[choice - 1]}
  fi

  [[ -n $has_model ]] || picked_args+=(--model "$model")
  if [[ -z $has_mmproj ]]; then
    if [[ -n $mmproj ]]; then
      picked_args+=(--mmproj "$mmproj")
    else
      picked_args+=(--no-mmproj)
    fi
  fi
fi

# Move this pick to the top, drop duplicates, keep the newest HISTORY_SIZE.
mkdir -p "${HISTORY_FILE%/*}"
{ printf '%s\t%s\n' "$model" "$mmproj"; cat "$HISTORY_FILE" 2>/dev/null || true; } \
  | awk -v max="$HISTORY_SIZE" '!seen[$0]++ && ++n <= max' > "$HISTORY_FILE.tmp"
mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"

echo "model:  $model"
echo "mmproj: ${mmproj:-none}"

# Fixed threshold makes glibc return large image buffers to the OS on free,
# instead of keeping them in per-thread arenas (RSS creeps up per image otherwise).
export MALLOC_MMAP_THRESHOLD_=131072

# llama.cpp keeps the last value of a repeated option,
# so the config file overrides the defaults and the command line overrides both.
exec "$LLAMA_BIN" serve \
  "${picked_args[@]}" \
  "${DEFAULT_ARGS[@]}" \
  "${config_args[@]}" \
  "${cli_args[@]}"
