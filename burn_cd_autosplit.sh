#!/usr/bin/env bash
# burn_cd_autosplit.sh — Audio CD DAO burner with auto-split that ALWAYS reflects current .wav files.
# - Rebuilds staging + disc folders each run (no stale re-burns)
# - Converts inputs to 44.1 kHz / 16-bit / stereo WAV
# - Honors playlist.m3u (if present), else Number*.wav, else *.wav (numeric sort)
# - Auto-splits across multiple discs by capacity (80 min default)
# - Optional per-track loudness normalization (EBU-ish)
# - Burns with wodim in DAO mode (-dao -pad) w/ BURN-Free
# - Chatty logs + per-disc logs
set -euo pipefail

# ----------------------- Defaults / Options -----------------------
SPEED="8"                 # --speed N
DEVICE=""                 # --device PATH (auto-detect if empty)
CAPACITY_MINS=80          # --capacity-mins N (per disc)
NORMALIZE="none"          # --normalize none|loudnorm
SIMULATE=0                # --simulate (no laser)
OVERBURN=0                # --overburn (allow slightly over capacity)
BLANK=""                  # --blank fast|all (for CD-RW)
USE_PLAYLIST=""           # --use-playlist FILE (else auto)
IGNORE_PLAYLIST=0         # --no-playlist
LIST_ONLY=0               # --list-only (plan only, no burn)
ONLY_DISC=""              # --disc N (burn only that disc number)
CLEANUP=0                 # --cleanup (delete staging after success)
LOGFILE="burn.log"
WORK_ALL="_stage_all"     # staged (converted) WAVs (global numbering)
DISC_PREFIX="_cd_disc"    # per-disc split output dirs
LC_ALL=C; export LC_ALL

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --device PATH            Optical drive (default: auto-detect, falls back to /dev/sr0)
  --speed N                Burn speed (default: 8)
  --capacity-mins N        Minutes per disc (default: 80)
  --normalize loudnorm     Apply EBU-ish loudness normalization per track
  --use-playlist FILE      Use specific M3U order
  --no-playlist            Ignore playlist.m3u even if present
  --simulate               Do a dummy burn (-dummy)
  --blank fast|all         Blank CD-RW before burning each disc
  --overburn               Allow slight over-capacity on a disc (not guaranteed)
  --list-only              Print disc plan(s) and exit (no burn)
  --disc N                 Burn only disc N (after planning/splitting)
  --cleanup                Remove staging directories after a successful burn
  -h|--help                Show this help

Examples:
  $(basename "$0") --list-only
  $(basename "$0") --speed 8 --device /dev/sr0
  $(basename "$0") --simulate --normalize loudnorm
  $(basename "$0") --disc 2
USAGE
}

# ----------------------- Parse Args -----------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="${2:-}"; shift 2;;
    --speed) SPEED="${2:-}"; shift 2;;
    --capacity-mins) CAPACITY_MINS="${2:-}"; shift 2;;
    --normalize) NORMALIZE="${2:-}"; shift 2;;
    --use-playlist) USE_PLAYLIST="${2:-}"; shift 2;;
    --no-playlist) IGNORE_PLAYLIST=1; shift;;
    --simulate) SIMULATE=1; shift;;
    --blank) BLANK="${2:-}"; shift 2;;
    --overburn) OVERBURN=1; shift;;
    --list-only) LIST_ONLY=1; shift;;
    --disc) ONLY_DISC="${2:-}"; shift 2;;
    --cleanup) CLEANUP=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

# ----------------------- Helpers -----------------------
log(){ echo "[$(date '+%H:%M:%S')] $*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
die(){ echo "ERROR: $*" >&2; exit 1; }

ceil_secs(){ awk 'BEGIN{printf("%d",('$1')+0.999)}'; }
fmt_mmss(){ awk 'BEGIN{s='$1'; printf("%d:%02d", int(s/60), int(s%60))}'; }

auto_device() {
  if [[ -n "${DEVICE}" && -e "${DEVICE}" ]]; then
    echo "$DEVICE"; return
  fi
  if [[ -e /dev/sr0 ]]; then
    echo "/dev/sr0"; return
  fi
  local cand
  cand="$(lsblk -o NAME,TYPE | awk '$2=="rom"{print $1; exit}' || true)"
  if [[ -n "$cand" && -e "/dev/$cand" ]]; then
    echo "/dev/$cand"; return
  fi
  echo "/dev/sr0"
}

disable_ctrl_z() {
  STTY_SUSP_SAVE="$(stty -a | sed -n 's/.*susp = \([^;]*\);.*/\1/p' || true)"
  stty susp undef || true
}
restore_ctrl_z() { [[ -n "${STTY_SUSP_SAVE:-}" ]] && stty susp "$STTY_SUSP_SAVE" || true; }

disc_dir_for(){ printf '%s%02d' "$DISC_PREFIX" "$1"; }

# ----------------------- Preflight -----------------------
have ffmpeg || die "ffmpeg is required. Install: sudo apt-get update && sudo apt-get install -y ffmpeg"
have ffprobe || die "ffprobe is required. Install: sudo apt-get update && sudo apt-get install -y ffmpeg"
have wodim  || die "wodim is required. Install: sudo apt-get update && sudo apt-get install -y wodim"
if ! have eject; then log "Note: 'eject' not found; will skip auto-eject."; fi

DEVICE="$(auto_device)"
log "Using device: $DEVICE"
log "Caching sudo… (enter password once if asked)"
sudo -v || true

# ----------------------- Collect Tracks (current dir) -----------------------
declare -a TRACKS=()

# Prefer playlist.m3u when present (unless --no-playlist), else Number*.wav, else *.wav
if [[ $IGNORE_PLAYLIST -eq 0 && -z "$USE_PLAYLIST" && -f playlist.m3u ]]; then
  USE_PLAYLIST="playlist.m3u"
fi
if [[ -n "$USE_PLAYLIST" ]]; then
  [[ -f "$USE_PLAYLIST" ]] || die "Playlist not found: $USE_PLAYLIST"
  log "Using playlist: $USE_PLAYLIST"
  # Read playlist robustly; ignore comments/blank lines; preserve spaces/UTF-8
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^\# ]] && continue
    line="${line%$'\r'}"
    [[ -f "$line" ]] || [[ -f "./$line" ]] || die "Missing file from playlist: $line"
    TRACKS+=("$line")
  done < "$USE_PLAYLIST"
fi

if [[ ${#TRACKS[@]} -eq 0 ]]; then
  # Number*.wav first, else any *.wav — use NUL delim to handle funky names
  mapfile -d '' TRACKS < <(find . -maxdepth 1 -type f -iname 'Number*.wav' -printf '%P\0' | sort -zV || true)
  if [[ ${#TRACKS[@]} -eq 0 ]]; then
    mapfile -d '' TRACKS < <(find . -maxdepth 1 -type f -iname '*.wav' -printf '%P\0' | sort -zV || true)
  fi
fi
[[ ${#TRACKS[@]} -gt 0 ]] || die "No WAV files found in $(pwd)"

# ----------------------- Rebuild staging & disc folders -----------------------
# ALWAYS rebuild so plan matches current directory contents
rm -rf -- "$WORK_ALL"
mkdir -p "$WORK_ALL"

# Remove any prior split output
rm -rf -- "${DISC_PREFIX}"??
# (Later creation of per-disc dirs will also ensure fresh state)

# ----------------------- Stage: Convert to CD-DA format -----------------------
declare -a STAGE_FILES=() DUR_SECS=()
total_secs=0
idx=0

log "Staging and converting to 44.1kHz/16-bit/stereo…"
for inwav in "${TRACKS[@]}"; do
  idx=$((idx+1))
  base="$(basename "${inwav%.*}")"
  out="$WORK_ALL/$(printf '%02d' "$idx")-${base}.wav"

  # Probe input (informational)
  sr="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1:nk=1 "$inwav" || echo 0)"
  ch="$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=nw=1:nk=1 "$inwav" || echo 0)"
  fmt="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_fmt -of default=nw=1:nk=1 "$inwav" || echo "unknown")"
  log "  #$idx  $inwav  (sr=$sr ch=$ch fmt=$fmt) → $(basename "$out")"

  af=""
  if [[ "$NORMALIZE" == "loudnorm" ]]; then
    af='loudnorm=I=-14:TP=-1.5:LRA=11'
  fi
  if [[ -n "$af" ]]; then
    ffmpeg -y -hide_banner -stats -v warning -i "$inwav" -af "$af" -ar 44100 -ac 2 -sample_fmt s16 "$out"
  else
    ffmpeg -y -hide_banner -stats -v warning -i "$inwav" -ar 44100 -ac 2 -sample_fmt s16 "$out"
  fi

  d="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$out" || echo 0)"
  sec="$(ceil_secs "$d")"
  STAGE_FILES+=("$out")
  DUR_SECS+=("$sec")
  total_secs=$((total_secs + sec))
done

cap_sec=$((CAPACITY_MINS*60))
log "Total program length: $(fmt_mmss "$total_secs")  (~$((total_secs/60))m $((total_secs%60))s)"
log "Disc capacity target: ${CAPACITY_MINS} minutes (per disc)"

# ----------------------- Auto-split Across Discs -----------------------
declare -a DISC_DIRS=() DISC_SECS=()
disc=1
disc_secs=0
disc_track_idx=0

make_disc_dir() {
  local n="$1"; local d
  d="$(disc_dir_for "$n")"
  rm -rf -- "$d"
  mkdir -p "$d"
  echo "$d"
}

current_dir="$(make_disc_dir "$disc")"
DISC_DIRS+=("$current_dir")
DISC_SECS+=(0)

for i in "${!STAGE_FILES[@]}"; do
  f="${STAGE_FILES[$i]}"
  s="${DUR_SECS[$i]}"

  # Single track longer than capacity? Fail unless --overburn
  if (( s > cap_sec )) && (( OVERBURN == 0 )); then
    die "Track $(basename "$f") is longer than ${CAPACITY_MINS} minutes. Split/trim or re-run with --overburn (not guaranteed)."
  fi

  if (( disc_secs + s > cap_sec )) && (( OVERBURN == 0 )); then
    disc=$((disc+1))
    disc_secs=0
    disc_track_idx=0
    current_dir="$(make_disc_dir "$disc")"
    DISC_DIRS+=("$current_dir")
    DISC_SECS+=(0)
  fi

  disc_track_idx=$((disc_track_idx+1))
  title="$(basename "$f")"; title="${title#??-}"  # drop global 2-digit prefix
  out_disc="$current_dir/$(printf '%02d' "$disc_track_idx")-$title"
  # Hardlink to avoid duplicate data; fallback to copy if FS disallows links
  ln -f "$f" "$out_disc" 2>/dev/null || cp -f "$f" "$out_disc"

  disc_secs=$((disc_secs + s))
  DISC_SECS[$((disc-1))]=$disc_secs
done

disc_count="${#DISC_DIRS[@]}"

# ----------------------- Print Plan -----------------------
echo
for d_i in $(seq 1 "$disc_count"); do
  ddir="${DISC_DIRS[$((d_i-1))]}"
  dsec="${DISC_SECS[$((d_i-1))]}"
  echo "=== Disc $d_i plan: $ddir ==="
  mapfile -t listing < <(ls -1 "$ddir"/*.wav | sort -V)
  for t_i in "${!listing[@]}"; do
    file="${listing[$t_i]}"
    dur="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$file" | awk '{printf("%d:%02d", int(($1+0.5)/60), int(($1+0.5)%60))}')"
    printf "  %2d. %s  [%s]\n" "$((t_i+1))" "$(basename "$file")" "$dur"
  done
  printf "  Disc %d total: %s\n\n" "$d_i" "$(fmt_mmss "$dsec")"
done

if (( LIST_ONLY == 1 )); then
  log "--list-only: finished planning; no burning performed."
  exit 0
fi

# ----------------------- Burn Function -----------------------
burn_one_disc() {
  local dnum="$1" ddir="$2" dlog="disc$(printf '%02d' "$dnum").log"

  # Optional blanking (CD-RW)
  if [[ -n "$BLANK" ]]; then
    case "$BLANK" in fast|all) ;; *) die "--blank must be 'fast' or 'all'";; esac
    log "Blanking CD-RW ($BLANK) for Disc $dnum…"
    sudo wodim dev="$DEVICE" blank="$BLANK" -v | tee -a "$LOGFILE"
  fi

  mapfile -t wavs < <(ls -1 "$ddir"/*.wav | sort -V)
  [[ ${#wavs[@]} -gt 0 ]] || die "No WAVs found in $ddir"

  log "Starting burn for Disc $dnum at speed $SPEED on $DEVICE (simulate=$SIMULATE overburn=$OVERBURN)…"
  disable_ctrl_z
  trap 'restore_ctrl_z' RETURN

  CMD=(wodim -v -dao -pad "dev=$DEVICE" speed="$SPEED" driveropts=burnfree -audio)
  (( OVERBURN == 1 )) && CMD+=(-overburn)
  (( SIMULATE == 1 )) && CMD+=(-dummy)

  set -o pipefail
  sudo "${CMD[@]}" "${wavs[@]}" 2>&1 | tee -a "$LOGFILE" | tee -a "$dlog"
  set +o pipefail

  restore_ctrl_z
  trap - RETURN

  log "Disc $dnum burn complete."
  if have eject; then eject "$DEVICE" || true; fi
}

# ----------------------- Burn Selection -----------------------
if [[ -n "$ONLY_DISC" ]]; then
  [[ "$ONLY_DISC" =~ ^[0-9]+$ ]] || die "--disc expects a number"
  (( ONLY_DISC >= 1 && ONLY_DISC <= disc_count )) || die "--disc out of range (1..$disc_count)"
  burn_one_disc "$ONLY_DISC" "${DISC_DIRS[$((ONLY_DISC-1))]}"
else
  for d_i in $(seq 1 "$disc_count"); do
    burn_one_disc "$d_i" "${DISC_DIRS[$((d_i-1))]}"
  done
fi

if (( CLEANUP == 1 )); then
  log "Cleaning up staging and disc directories…"
  rm -rf -- "$WORK_ALL" "${DISC_PREFIX}"??
fi

log "All done. See $LOGFILE and discXX.log for details."
