#!/usr/bin/env bash
# burn_cd_autosplit.sh — Audio CD DAO burner with flexible split strategies
# - Rebuilds staging/split folders each run (no stale re-burns)
# - Converts inputs to 44.1 kHz / 16-bit / stereo WAV (CD-DA)
# - Honors playlist.m3u (if present), else Number*.wav, else *.wav (numeric sort)
# - Multiple split strategies on overflow: fill-first (default), balanced, manual, fixed N discs
# - Optional per-track loudness normalization (EBU-ish)
# - Burns with wodim in DAO mode (-dao -pad) + BURN-Free
# - Verbose logs + per-disc logs
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

# New split controls
SPLIT_STRATEGY="fill"     # --split fill|balanced|manual
DISCS=""                  # --discs N (force planning into exactly N discs; used by 'fill' or 'balanced')
MANUAL_SPLIT=""           # --manual-split "k1,k2,..." (start new disc BEFORE track k1+1, etc; 1-based)
STRICT_CAP=1              # --no-strict-cap to allow target balancing under capacity; still hard-stop at cap unless --overburn

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Core:
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

Split behavior (overflow handling):
  --split fill             (default) Fill each disc to capacity before moving on (preserves order)
  --split balanced         Balance program length across discs while preserving order
  --split manual           Use manual split points (see --manual-split)
  --discs N                Plan into exactly N discs (works with 'fill' or 'balanced')
  --manual-split "k1,k2"   1-based track numbers where a NEW disc begins at the *next* track
  --no-strict-cap          When balancing, use target-per-disc even if under capacity; still won't exceed capacity unless --overburn

Examples:
  $(basename "$0") --list-only
  $(basename "$0") --split balanced --discs 2
  $(basename "$0") --split manual --manual-split "12"      # Disc 1 = tracks 1..12, Disc 2 = 13..end (subject to capacity)
  $(basename "$0") --capacity-mins 90 --overburn           # 90-min media + allow overburn
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
    --split) SPLIT_STRATEGY="${2:-}"; shift 2;;
    --discs) DISCS="${2:-}"; shift 2;;
    --manual-split) MANUAL_SPLIT="${2:-}"; shift 2;;
    --no-strict-cap) STRICT_CAP=0; shift;;
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

if [[ $IGNORE_PLAYLIST -eq 0 && -z "$USE_PLAYLIST" && -f playlist.m3u ]]; then
  USE_PLAYLIST="playlist.m3u"
fi
if [[ -n "$USE_PLAYLIST" ]]; then
  [[ -f "$USE_PLAYLIST" ]] || die "Playlist not found: $USE_PLAYLIST"
  log "Using playlist: $USE_PLAYLIST"
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^\# ]] && continue
    line="${line%$'\r'}"
    [[ -f "$line" ]] || [[ -f "./$line" ]] || die "Missing file from playlist: $line"
    TRACKS+=("$line")
  done < "$USE_PLAYLIST"
fi

if [[ ${#TRACKS[@]} -eq 0 ]]; then
  mapfile -d '' TRACKS < <(find . -maxdepth 1 -type f -iname 'Number*.wav' -printf '%P\0' | sort -zV || true)
  if [[ ${#TRACKS[@]} -eq 0 ]]; then
    mapfile -d '' TRACKS < <(find . -maxdepth 1 -type f -iname '*.wav' -printf '%P\0' | sort -zV || true)
  fi
fi
[[ ${#TRACKS[@]} -gt 0 ]] || die "No WAV files found in $(pwd)"

# ----------------------- Rebuild staging/split folders -----------------------
rm -rf -- "$WORK_ALL" "${DISC_PREFIX}"??
mkdir -p "$WORK_ALL"

# ----------------------- Stage: Convert to CD-DA -----------------------
declare -a STAGE_FILES=() DUR_SECS=()
total_secs=0
idx=0

log "Staging and converting to 44.1kHz/16-bit/stereo…"
for inwav in "${TRACKS[@]}"; do
  idx=$((idx+1))
  base="$(basename "${inwav%.*}")"
  out="$WORK_ALL/$(printf '%02d' "$idx")-${base}.wav"

  # Probe input (info only)
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
log "Total program length: $(fmt_mmss "$total_secs")"
log "Disc capacity target: ${CAPACITY_MINS} minutes (per disc)"

# ----------------------- Split Planners -----------------------
declare -a DISC_IDX_STARTS=()  # 1-based track index where each disc starts
declare -i disc_count=0

ensure_overburn_or_die() {
  local val="$1"
  if (( val > cap_sec )) && (( OVERBURN == 0 )); then
    die "A planned disc exceeds capacity (${CAPACITY_MINS}m). Use --overburn or increase --capacity-mins (90/99-min media)."
  fi
}

# fill-first (default): pack to capacity, then continue; optional --discs to cap number of discs
plan_fill() {
  local i=1 cur=0 used=0
  DISC_IDX_STARTS=()
  disc_count=0
  DISC_IDX_STARTS+=(1); disc_count=1; cur=0

  local target_discs="${DISCS:-}"
  # If user limits discs, compute tighter per-disc target but never exceed capacity (unless overburn)
  local per_disc_target="$cap_sec"
  if [[ -n "$target_discs" && "$target_discs" =~ ^[0-9]+$ && "$target_discs" -gt 0 ]]; then
    local need=$(( (total_secs + target_discs - 1) / target_discs ))
    per_disc_target=$(( need < cap_sec ? need : cap_sec ))
    if (( need > cap_sec )) && (( OVERBURN == 0 )); then
      log "Note: requested --discs=$target_discs implies >${CAPACITY_MINS}m per disc. Will still hard-stop at capacity; may produce more discs."
    fi
  fi

  for ((i=1;i<=${#DUR_SECS[@]};i++)); do
    local s="${DUR_SECS[$((i-1))]}"
    if (( s > cap_sec )) && (( OVERBURN == 0 )); then
      die "Track #$i is longer than disc capacity (${CAPACITY_MINS}m). Split/trim or use --overburn."
    fi
    if (( cur + s > per_disc_target )) && (( OVERBURN == 0 )); then
      disc_count=$((disc_count+1))
      DISC_IDX_STARTS+=("$i")
      cur=0
    fi
    cur=$((cur+s))
  done
  disc_count=${#DISC_IDX_STARTS[@]}
}

# balanced: try to equalize total time per disc while preserving order
# - If --discs given: use that N (subject to capacity)
# - Else: N = ceil(total/capacity)
plan_balanced() {
  local n_discs
  if [[ -n "$DISCS" && "$DISCS" =~ ^[0-9]+$ && "$DISCS" -gt 0 ]]; then
    n_discs="$DISCS"
  else
    n_discs=$(( (total_secs + cap_sec - 1) / cap_sec ))
    (( n_discs < 1 )) && n_discs=1
  fi

  local target=$(( (total_secs + n_discs - 1) / n_discs ))
  # Respect capacity unless --overburn; target cannot exceed capacity in strict mode
  if (( STRICT_CAP == 1 )); then
    (( target > cap_sec )) && target="$cap_sec"
  fi

  DISC_IDX_STARTS=()
  DISC_IDX_STARTS+=(1)
  local cur=0 i s discs_made=1

  for ((i=1;i<=${#DUR_SECS[@]};i++)); do
    s="${DUR_SECS[$((i-1))]}"
    if (( s > cap_sec )) && (( OVERBURN == 0 )); then
      die "Track #$i is longer than disc capacity (${CAPACITY_MINS}m). Split/trim or use --overburn."
    fi

    # If adding this track would overshoot both target and capacity (when strict),
    # start a new disc — but keep at least 1 track per disc.
    if (( cur > 0 )) && (( cur + s > target || (STRICT_CAP==1 && cur + s > cap_sec && OVERBURN==0) )); then
      discs_made=$((discs_made+1))
      DISC_IDX_STARTS+=("$i")
      cur=0
      # Recalculate remaining average target if --discs provided to better balance
      if (( STRICT_CAP==0 )) && [[ -n "$DISCS" ]]; then
        local remain_total=0 j
        for ((j=i;j<=${#DUR_SECS[@]};j++)); do remain_total=$((remain_total + DUR_SECS[$((j-1))])); done
        local remain_discs=$(( n_discs - discs_made + 1 ))
        (( remain_discs < 1 )) && remain_discs=1
        target=$(( (remain_total + remain_discs - 1) / remain_discs ))
      fi
    fi
    cur=$((cur+s))
  done

  disc_count=${#DISC_IDX_STARTS[@]}
}

# manual split: user supplies split indices (1-based track numbers where a new disc starts at next track)
plan_manual() {
  [[ -n "$MANUAL_SPLIT" ]] || die "--split manual requires --manual-split \"k1,k2,...\""
  DISC_IDX_STARTS=()
  DISC_IDX_STARTS+=(1)
  IFS=',' read -r -a cuts <<< "$MANUAL_SPLIT"
  local c
  for c in "${cuts[@]}"; do
    [[ "$c" =~ ^[0-9]+$ ]] || die "Invalid manual split index: $c"
    local next=$((c+1))
    (( next <= ${#DUR_SECS[@]} )) && DISC_IDX_STARTS+=("$next")
  done
  # Ensure strictly increasing and unique
  local uniq=() last=0 val
  for val in "${DISC_IDX_STARTS[@]}"; do
    (( val>last )) && uniq+=("$val"); last="$val"
  done
  DISC_IDX_STARTS=("${uniq[@]}")

  # Capacity check per disc unless --overburn
  local d start end sum i
  for ((d=1; d<=${#DISC_IDX_STARTS[@]}; d++)); do
    start="${DISC_IDX_STARTS[$((d-1))]}"
    if (( d < ${#DISC_IDX_STARTS[@]} )); then
      end=$(( DISC_IDX_STARTS[$d] - 1 ))
    else
      end=${#DUR_SECS[@]}
    fi
    sum=0
    for ((i=start;i<=end;i++)); do sum=$((sum + DUR_SECS[$((i-1))])); done
    if (( sum > cap_sec )) && (( OVERBURN == 0 )); then
      die "Manual split makes Disc $d exceed capacity (${CAPACITY_MINS}m). Use --overburn or adjust --manual-split."
    fi
  done

  disc_count=${#DISC_IDX_STARTS[@]}
}

# ----------------------- Build Plan -----------------------
case "$SPLIT_STRATEGY" in
  fill)      plan_fill;;
  balanced)  plan_balanced;;
  manual)    plan_manual;;
  *) die "Unknown --split strategy: $SPLIT_STRATEGY (use: fill|balanced|manual)";;
esac

# ----------------------- Materialize per-disc directories --------------------
declare -a DISC_DIRS=() DISC_SECS=()
mkdir -p "$WORK_ALL"
for ((d=1; d<=disc_count; d++)); do
  ddir="$(disc_dir_for "$d")"
  rm -rf -- "$ddir"
  mkdir -p "$ddir"
  DISC_DIRS+=("$ddir")
  DISC_SECS+=(0)

  start="${DISC_IDX_STARTS[$((d-1))]}"
  if (( d < disc_count )); then
    end=$(( DISC_IDX_STARTS[$d] - 1 ))
  else
    end=${#STAGE_FILES[@]}
  fi

  disc_track_idx=0
  for ((i=start;i<=end;i++)); do
    f="${STAGE_FILES[$((i-1))]}"
    s="${DUR_SECS[$((i-1))]}"
    disc_track_idx=$((disc_track_idx+1))
    title="$(basename "$f")"; title="${title#??-}"  # drop global 2-digit prefix
    out_disc="${ddir}/$(printf '%02d' "$disc_track_idx")-$title"
    ln -f "$f" "$out_disc" 2>/dev/null || cp -f "$f" "$out_disc"
    DISC_SECS[$((d-1))]=$(( DISC_SECS[$((d-1))] + s ))
  done

  # Capacity enforcement unless --overburn
  if (( DISC_SECS[$((d-1))] > cap_sec )) && (( OVERBURN == 0 )); then
    die "Planned Disc $d exceeds capacity (${CAPACITY_MINS}m) — choose a different split or --overburn."
  fi
done

# ----------------------- Print Plan -----------------------
echo
for ((d=1; d<=disc_count; d++)); do
  ddir="${DISC_DIRS[$((d-1))]}"
  dsec="${DISC_SECS[$((d-1))]}"
  echo "=== Disc $d plan: $ddir  (strategy=$SPLIT_STRATEGY) ==="
  mapfile -t listing < <(ls -1 "$ddir"/*.wav | sort -V)
  for t_i in "${!listing[@]}"; do
    file="${listing[$t_i]}"
    dur="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$file" | awk '{printf("%d:%02d", int(($1+0.5)/60), int(($1+0.5)%60))}')"
    printf "  %2d. %s  [%s]\n" "$((t_i+1))" "$(basename "$file")" "$dur"
  done
  printf "  Disc %d total: %s\n\n" "$d" "$(fmt_mmss "$dsec")"
done

if (( LIST_ONLY == 1 )); then
  log "--list-only: finished planning; no burning performed."
  exit 0
fi

# ----------------------- Burn Function -----------------------
disable_ctrl_z() {
  STTY_SUSP_SAVE="$(stty -a | sed -n 's/.*susp = \([^;]*\);.*/\1/p' || true)"
  stty susp undef || true
}
restore_ctrl_z() { [[ -n "${STTY_SUSP_SAVE:-}" ]] && stty susp "$STTY_SUSP_SAVE" || true; }

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
  for ((d=1; d<=disc_count; d++)); do
    burn_one_disc "$d" "${DISC_DIRS[$((d-1))]}"
  done
fi

if (( CLEANUP == 1 )); then
  log "Cleaning up staging and disc directories…"
  rm -rf -- "$WORK_ALL" "${DISC_PREFIX}"??
fi

log "All done. See $LOGFILE and discXX.log for details."
