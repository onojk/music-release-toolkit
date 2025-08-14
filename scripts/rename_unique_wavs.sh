#!/usr/bin/env bash
set -Eeuo pipefail

# rename_unique_wavs.sh
# Universal WAV renamer + duplicate (MD5) checker.
# Compatible with Linux/macOS. No GNU-only flags required.

# -------------------
# Defaults (overridable via flags)
MAX_TRACKS=20
PREFIX="Number"
EXT="wav"
BACKUP_DIR="old"
DRY_RUN=0
FORCE=0
# -------------------

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --max=N             Max tracks to rename (default: $MAX_TRACKS)
  --prefix=NAME       Output filename prefix (default: $PREFIX)
  --ext=EXT           File extension to process (default: $EXT)
  --backup-dir=DIR    Directory to copy originals (default: $BACKUP_DIR)
  --dry-run           Show what would happen; make no changes
  --force             Proceed with renaming even if duplicates detected
  -h, --help          Show this help

Examples:
  $(basename "$0") --max=20
  $(basename "$0") --prefix=Track --ext=wav
EOF
}

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --max=*)        MAX_TRACKS="${arg#*=}";;
    --prefix=*)     PREFIX="${arg#*=}";;
    --ext=*)        EXT="${arg#*=}";;
    --backup-dir=*) BACKUP_DIR="${arg#*=}";;
    --dry-run)      DRY_RUN=1;;
    --force)        FORCE=1;;
    -h|--help)      usage; exit 0;;
    *)
      echo "Unknown option: $arg" >&2
      usage
      exit 2
      ;;
  esac
done

# Shell options for robust globbing
shopt -s nullglob

# Collect target files (case-insensitive on extension)
# Use two globs to cover lower/upper cases portably.
files=( *."$EXT" *."${EXT^^}" )
if (( ${#files[@]} == 0 )); then
  echo "No *.$EXT files found."
  exit 1
fi

printf "Found %d *.%s files.\n" "${#files[@]}" "$EXT"

# -------- Hashing (portable) --------
# Return MD5 hash for a given file via the best available tool.
file_md5() {
  local f="$1"
  if command -v openssl >/dev/null 2>&1; then
    # OpenSSL is present on macOS & most Linux
    # '-r' prints 'hash filename'
    openssl md5 -r -- "$f" | awk '{print $1}'
  elif command -v md5sum >/dev/null 2>&1; then
    md5sum -- "$f" | awk '{print $1}'
  elif command -v md5 >/dev/null 2>&1; then
    # macOS 'md5' prints 'MD5 (filename) = hash'
    md5 -- "$f" | awk -F'= ' '{print $2}'
  else
    echo "ERROR: No MD5 tool found (openssl/md5sum/md5)." >&2
    exit 3
  fi
}

echo "Checking for duplicate audio content (MD5)…"
declare -A seen_hash
declare -A first_of_hash
dup_found=0

# Compute hashes safely, one-by-one (portable; handles spaces)
for f in "${files[@]}"; do
  h="$(file_md5 "$f")"
  if [[ -n "${seen_hash[$h]:-}" ]]; then
    if [[ "${seen_hash[$h]}" == "once" ]]; then
      echo
      echo "Duplicate group (MD5: $h):"
      echo "  - ${first_of_hash[$h]}"
      seen_hash[$h]="grouped"
    fi
    echo "  - $f"
    dup_found=1
  else
    seen_hash[$h]="once"
    first_of_hash[$h]="$f"
  fi
done

if (( dup_found )); then
  echo
  if (( FORCE )); then
    echo "⚠️  Duplicates detected, but --force specified. Continuing…"
  else
    echo "❌ Duplicate files detected. Resolve them or re-run with --force to proceed anyway."
    exit 4
  fi
else
  echo "✅ All files are unique by MD5."
fi

# Prepare backup
if (( DRY_RUN )); then
  echo "[DRY-RUN] Would create backup dir: $BACKUP_DIR"
else
  mkdir -p -- "$BACKUP_DIR"
fi

# Copy originals to backup
if (( DRY_RUN )); then
  for f in "${files[@]}"; do
    echo "[DRY-RUN] Would copy: $f -> $BACKUP_DIR/"
  done
else
  for f in "${files[@]}"; do
    cp -- "$f" "$BACKUP_DIR/"
  done
fi
echo "Backup ready in: $BACKUP_DIR"

# Renaming loop
i=1
renamed=()
skipped=()

for f in "${files[@]}"; do
  # Skip already in the target scheme PREFIXNN.EXT (NN = two digits)
  fname="${f##*/}"
  if [[ "$fname" =~ ^${PREFIX}[0-9]{2}\.${EXT}$ ]]; then
    skipped+=("$f")
    continue
  fi

  # Stop after MAX_TRACKS fresh renames
  if (( i > MAX_TRACKS )); then
    skipped+=("$f")
    continue
  fi

  new="$(printf "%s%02d.%s" "$PREFIX" "$i" "$EXT")"

  if (( DRY_RUN )); then
    echo "[DRY-RUN] Would rename: $f  ->  $new"
  else
    mv -- "$f" "$new"
  fi
  renamed+=("$new")
  ((i++))
done

# Playlist (only renamed + any already-correctly-named that exist)
# Because names are zero-padded, plain sort is sufficient and portable.
playlist="playlist.m3u"
if (( DRY_RUN )); then
  echo "[DRY-RUN] Would write $playlist with ordered tracks."
else
  : > "$playlist"
  # Include all correctly named files, whether newly created or pre-existing
  declare -a all_named=( ${PREFIX}[0-9][0-9].${EXT} )
  if (( ${#all_named[@]} > 0 )); then
    printf "%s\n" "${all_named[@]}" | LC_ALL=C sort > "$playlist"
  fi
fi

# Summary
echo
echo "---------- SUMMARY ----------"
printf "Renamed (up to %d): %d file(s)\n" "$MAX_TRACKS" "${#renamed[@]}"
for r in "${renamed[@]}"; do echo "  - $r"; done
if (( ${#skipped[@]} )); then
  echo "Skipped (already named or beyond limit): ${#skipped[@]}"
  for s in "${skipped[@]}"; do echo "  - $s"; done
fi
if (( DRY_RUN )); then
  echo "Playlist: [DRY-RUN] $playlist (not written)"
else
  if [[ -s "$playlist" ]]; then
    echo "Playlist written: $playlist"
  else
    echo "Playlist was empty (no correctly named files found)."
  fi
fi
echo "-----------------------------"
