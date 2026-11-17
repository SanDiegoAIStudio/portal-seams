#!/bin/sh
# seam-check.sh: score the seam between two shots with SSIM.
#
#   sh seam-check.sh A B [--threshold T]
#
# A is a video clip or a still image (png, jpg, jpeg, webp, judged by extension).
# B is a video clip.
# Frame from A: the frame 0.05 seconds before the end of the clip, or the image itself.
# Frame from B: its first frame.
# Prints one line, "seam ssim 0.975 PASS (threshold 0.90)" or with FAIL.
# Exit 0 when the score is at or above T (default 0.90), 1 when it is below,
# 2 on a usage error, a missing file, ffmpeg not found or a frame that could not be read.
#
# POSIX sh. Needs ffmpeg (with the ssim filter) and ffprobe on PATH.

usage() {
  {
    printf '%s\n' "usage: sh seam-check.sh A B [--threshold T]"
    printf '%s\n' "  A  a video clip or a still image (png, jpg, jpeg, webp)"
    printf '%s\n' "  B  a video clip"
    printf '%s\n' "  T  pass line between 0 and 1, default 0.90"
  } >&2
}

die() {
  printf 'seam-check: %s\n' "$1" >&2
  exit 2
}

TMPD=""
cleanup() {
  if [ -n "$TMPD" ]; then
    rm -f "$TMPD/a.png" "$TMPD/b.png" "$TMPD/b-scaled.png"
    rmdir "$TMPD" 2>/dev/null
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

A=""
B=""
T="0.90"
NPOS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --threshold)
      if [ $# -lt 2 ]; then
        usage
        die "--threshold needs a value"
      fi
      T=$2
      shift 2
      ;;
    -*)
      usage
      die "unknown option: $1"
      ;;
    *)
      NPOS=$((NPOS + 1))
      case "$NPOS" in
        1) A=$1 ;;
        2) B=$1 ;;
        *)
          usage
          die "too many arguments"
          ;;
      esac
      shift
      ;;
  esac
done

if [ "$NPOS" -ne 2 ]; then
  usage
  die "give two files, A and B"
fi
case "$T" in
  '' | . | *[!0-9.]* | *.*.*)
    usage
    die "the threshold must be a number such as 0.90"
    ;;
esac
[ -f "$A" ] || die "not a file: $A"
[ -f "$B" ] || die "not a file: $B"
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg not found on PATH"
command -v ffprobe >/dev/null 2>&1 || die "ffprobe not found on PATH"
ffmpeg -hide_banner -filters 2>/dev/null | grep ' ssim ' >/dev/null 2>&1 ||
  die "this ffmpeg has no ssim filter"

A_IS_IMAGE=0
LOWER=$(printf '%s' "$A" | tr 'A-Z' 'a-z')
case "$LOWER" in
  *.png | *.jpg | *.jpeg | *.webp) A_IS_IMAGE=1 ;;
esac

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/seam-check.XXXXXX") || die "could not make a temporary folder"
FA="$TMPD/a.png"
FB="$TMPD/b.png"
FB2="$TMPD/b-scaled.png"

if [ "$A_IS_IMAGE" = 1 ]; then
  ffmpeg -v error -nostdin -i "$A" -frames:v 1 -pix_fmt rgb24 -y "$FA" >/dev/null 2>&1
else
  DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$A" 2>/dev/null)
  case "$DUR" in
    '' | N/A)
      die "A has no duration, so it is not a clip; name a still image .png, .jpg, .jpeg or .webp"
      ;;
  esac
  ffmpeg -v error -nostdin -sseof -0.05 -i "$A" -frames:v 1 -pix_fmt rgb24 -y "$FA" >/dev/null 2>&1
  if [ ! -s "$FA" ]; then
    # A low frame rate leaves no frame in the last 0.05 seconds; take the last frame there is.
    printf 'note: no frame in the last 0.05 seconds of A (low frame rate); used the last frame of A\n'
    ffmpeg -v error -nostdin -sseof -1 -i "$A" -update 1 -pix_fmt rgb24 -y "$FA" >/dev/null 2>&1
  fi
fi
[ -s "$FA" ] || die "could not read a frame from A: $A"

ffmpeg -v error -nostdin -ss 0 -i "$B" -frames:v 1 -pix_fmt rgb24 -y "$FB" >/dev/null 2>&1
[ -s "$FB" ] || die "could not read a frame from B: $B"

size_of() {
  ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$1" 2>/dev/null
}
SIZE_A=$(size_of "$FA")
SIZE_B=$(size_of "$FB")
[ -n "$SIZE_A" ] || die "could not read the frame size of A"
[ -n "$SIZE_B" ] || die "could not read the frame size of B"

if [ "$SIZE_A" != "$SIZE_B" ]; then
  printf 'note: frame sizes differ (A %s, B %s); scaled the frame from B to %s\n' "$SIZE_A" "$SIZE_B" "$SIZE_A"
  W=${SIZE_A%x*}
  H=${SIZE_A#*x}
  ffmpeg -v error -nostdin -i "$FB" -vf "scale=${W}:${H}" -pix_fmt rgb24 -y "$FB2" >/dev/null 2>&1
  [ -s "$FB2" ] || die "could not scale the frame from B"
  FB=$FB2
fi

# Both frames are converted to yuv420p first, the format clips are normally encoded in.
# Scored as RGB the same pair reads lower, because the blue channel weighs as much as red
# and green, so a pass line only means something against one fixed format.
LOG=$(ffmpeg -nostdin -hide_banner -i "$FA" -i "$FB" \
  -lavfi "[0:v]format=yuv420p[a];[1:v]format=yuv420p[b];[a][b]ssim" -f null - 2>&1)
SCORE=$(printf '%s\n' "$LOG" | sed -n 's/.*SSIM.* All:\([0-9.]*\).*/\1/p' | tail -n 1)
[ -n "$SCORE" ] || die "ffmpeg did not report an ssim score"

SCORE3=$(awk -v s="$SCORE" 'BEGIN { printf "%.3f", s }')
if awk -v s="$SCORE" -v t="$T" 'BEGIN { exit !(s>=t) }'; then
  printf 'seam ssim %s PASS (threshold %s)\n' "$SCORE3" "$T"
  exit 0
else
  printf 'seam ssim %s FAIL (threshold %s)\n' "$SCORE3" "$T"
  exit 1
fi
