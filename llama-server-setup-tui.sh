#!/usr/bin/env bash
# Pick a model and mmproj (from recent picks or a whiptail file browser), then serve
# them with llama.cpp, all prompt caching off. Each request is prefilled from scratch.
# Extra args are passed through and override the defaults, e.g. --port 8899.
set -euo pipefail

# The file browser starts here; use ".." to go anywhere else.
MODELS_ROOT="$HOME"
SKIP_ITEM="(no mmproj)"
# One "model<TAB>mmproj" per line, newest first; mmproj is empty for SKIP_ITEM.
# readlink -f keeps it next to the real script even when run through a symlink.
HISTORY_FILE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.cache/llama-server-history.tsv"
HISTORY_SIZE=5

cancel() {
  echo "Cancelled." >&2
  exit 1
}

# type -P only matches executables on PATH, never aliases or functions.
LLAMA_BIN=$(type -P llama) || {
  echo "llama CLI not found in PATH. Install llama.cpp so that 'llama serve' works." >&2
  exit 1
}
# Without this check a missing whiptail would look like a Cancel.
command -v whiptail >/dev/null || {
  echo "whiptail not found. Install it, e.g. 'sudo apt install whiptail'." >&2
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

# Recent picks whose files still exist.
recent_models=()
recent_mmprojs=()
recent_items=()
if [[ -f $HISTORY_FILE ]]; then
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
  model=$(pick_gguf "Select model (.gguf)" "$MODELS_ROOT") || cancel
  mmproj=$(pick_gguf "Select mmproj (.gguf)" "$(dirname "$model")" can_skip) || cancel
else
  model=${recent_models[choice - 1]}
  mmproj=${recent_mmprojs[choice - 1]}
fi

# Move this pick to the top, drop duplicates, keep the newest HISTORY_SIZE.
mkdir -p "${HISTORY_FILE%/*}"
{ printf '%s\t%s\n' "$model" "$mmproj"; cat "$HISTORY_FILE" 2>/dev/null || true; } \
  | awk -v max="$HISTORY_SIZE" '!seen[$0]++ && ++n <= max' > "$HISTORY_FILE.tmp"
mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"

mmproj_args=(--no-mmproj)
[[ -n $mmproj ]] && mmproj_args=(--mmproj "$mmproj")

echo "model:  $model"
echo "mmproj: ${mmproj:-none}"

# Fixed threshold makes glibc return large image buffers to the OS on free,
# instead of keeping them in per-thread arenas (RSS creeps up per image otherwise).
export MALLOC_MMAP_THRESHOLD_=131072

exec "$LLAMA_BIN" serve \
  --model "$model" \
  "${mmproj_args[@]}" \
  --host 127.0.0.1 \
  --port 8888 \
  --ctx-size 32768 \
  --n-gpu-layers all \
  --parallel 1 \
  --no-cache-prompt \
  --cache-ram 0 \
  --ctx-checkpoints 0 \
  "$@"
