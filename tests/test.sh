#!/bin/sh
# tests/test.sh: run seam-check.sh against clips this script generates itself.
#
#   sh tests/test.sh
#
# The clips come from ffmpeg's lavfi sources, are tiny, live in a mktemp folder
# and are removed when the test ends. Nothing binary is committed.
# SEAM_CHECK names the script under test (tests/mutate.sh sets it to a mutated copy).
# SEAM_TEST_SHELLS (default "sh bash zsh") picks which of those shells run the cases.
# Exit 0 when every case passes under every shell found, 1 when any case fails.

HERE=$(cd "$(dirname "$0")" && pwd)
SEAM_CHECK=${SEAM_CHECK:-"$HERE/../seam-check.sh"}

for tool in ffmpeg ffprobe; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'test.sh: %s not found on PATH\n' "$tool" >&2
    exit 2
  }
done
[ -f "$SEAM_CHECK" ] || {
  printf 'test.sh: no script at %s\n' "$SEAM_CHECK" >&2
  exit 2
}

ENC=mpeg4
if ffmpeg -hide_banner -encoders 2>/dev/null | grep ' libx264 ' >/dev/null 2>&1; then
  ENC=libx264
fi

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/seam-test.XXXXXX") || exit 2
# sweep_scratch: remove what a run left in the folder the runs use as TMPDIR.
sweep_scratch() {
  for d in "$TMPD"/scratch/seam-check.*; do
    [ -d "$d" ] || continue
    rm -f "$d/a.png" "$d/b.png" "$d/b-scaled.png"
    rmdir "$d" 2>/dev/null
  done
}

cleanup() {
  for n in a.mp4 b.mp4 bad.mp4 small.mp4 slow.mp4 a-last.png a-last.jpg not-a-clip.mp4; do
    rm -f "$TMPD/$n"
  done
  sweep_scratch
  rmdir "$TMPD/scratch" 2>/dev/null
  rmdir "$TMPD/empty-path" 2>/dev/null
  rmdir "$TMPD" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

AMBER="0xFFB347"

# gen OUT FIRST SECOND SIZE RATE
# One second of FIRST then one second of SECOND, each "amber" or "pattern".
gen() {
  _out=$1
  _size=$4
  _rate=$5
  _src1="color=c=$AMBER:size=$_size:rate=$_rate:duration=1"
  _src2=$_src1
  [ "$2" = pattern ] && _src1="testsrc2=size=$_size:rate=$_rate:duration=1"
  [ "$3" = pattern ] && _src2="testsrc2=size=$_size:rate=$_rate:duration=1"
  ffmpeg -v error -nostdin -y -f lavfi -i "$_src1" -f lavfi -i "$_src2" \
    -filter_complex "[0:v][1:v]concat=n=2:v=1:a=0,format=yuv420p" \
    -c:v "$ENC" -b:v 200k "$_out" || {
    printf 'test.sh: could not generate %s\n' "$_out" >&2
    exit 2
  }
}

# A: pattern, then amber for its last second.  B: amber for its first second, then pattern.
gen "$TMPD/a.mp4" pattern amber 128x96 25
gen "$TMPD/b.mp4" amber pattern 128x96 25
gen "$TMPD/small.mp4" amber pattern 64x48 25
gen "$TMPD/slow.mp4" pattern amber 128x96 10
# bad: opens on the test pattern and stays on it.
ffmpeg -v error -nostdin -y -f lavfi -i "testsrc2=size=128x96:rate=25:duration=2" \
  -pix_fmt yuv420p -c:v "$ENC" -b:v 200k "$TMPD/bad.mp4" || exit 2
# Stills saved from the last frame of A.
ffmpeg -v error -nostdin -y -sseof -0.05 -i "$TMPD/a.mp4" -frames:v 1 "$TMPD/a-last.png" || exit 2
ffmpeg -v error -nostdin -y -sseof -0.05 -i "$TMPD/a.mp4" -frames:v 1 "$TMPD/a-last.jpg" || exit 2
printf 'this is text, not a video\n' >|"$TMPD/not-a-clip.mp4"
mkdir "$TMPD/empty-path" "$TMPD/scratch"

FAILS=0
CASE_BAD=0
CASE_MSG=""

# sh_run ARGS: run the script under test with the current shell. zsh gets -f so
# the user's own startup files cannot change PATH under the test.
sh_run() {
  if [ "$SH_NAME" = zsh ]; then
    "$SH_PATH" -f "$SEAM_CHECK" "$@"
  else
    "$SH_PATH" "$SEAM_CHECK" "$@"
  fi
}

# run ARGS: sets OUT (stdout and stderr) and RC. TMPDIR points at a folder this
# test owns, so finish can see whether the script cleaned up after itself.
run() {
  OUT=$(TMPDIR="$TMPD/scratch" sh_run "$@" 2>&1)
  RC=$?
}

note_bad() {
  CASE_BAD=$((CASE_BAD + 1))
  CASE_MSG="$CASE_MSG
      $1"
}

want_rc() {
  [ "$RC" -eq "$1" ] || note_bad "expected exit $1, got $RC; output: $OUT"
}

score_of() {
  printf '%s\n' "$OUT" | sed -n 's/^seam ssim \([0-9.]*\) .*/\1/p'
}

want_score() {
  _s=$(score_of)
  if [ -z "$_s" ]; then
    note_bad "no seam ssim line; output: $OUT"
  elif ! printf '%s\n' "$_s" | grep -E '^[0-9]\.[0-9][0-9][0-9]$' >/dev/null 2>&1; then
    note_bad "score $_s is not printed with three decimals"
  elif ! awk -v s="$_s" -v lo="$1" -v hi="$2" 'BEGIN { exit !(s>lo && s<=hi) }'; then
    note_bad "score $_s outside ($1, $2]"
  fi
}

want_text() {
  printf '%s\n' "$OUT" | grep -F -e "$1" >/dev/null 2>&1 || note_bad "output lacks \"$1\"; output: $OUT"
}

want_no_text() {
  if printf '%s\n' "$OUT" | grep -F -e "$1" >/dev/null 2>&1; then
    note_bad "output has \"$1\"; output: $OUT"
  fi
}

# finish NAME: print the case result with the verdict line, count a failure.
finish() {
  for d in "$TMPD"/scratch/seam-check.*; do
    [ -d "$d" ] && note_bad "left a temporary folder behind: ${d##*/}"
  done
  sweep_scratch
  _line=$(printf '%s\n' "$OUT" | grep -e '^seam ssim' -e '^seam-check:' | head -n 1)
  if [ "$CASE_BAD" -eq 0 ]; then
    printf 'ok   [%s] %s :: %s\n' "$SH_NAME" "$1" "$_line"
  else
    printf 'FAIL [%s] %s :: %s%s\n' "$SH_NAME" "$1" "$_line" "$CASE_MSG"
    FAILS=$((FAILS + 1))
  fi
  CASE_BAD=0
  CASE_MSG=""
}

run_cases() {
  # 1. A ends in amber, B opens on amber: the seam passes.
  run "$TMPD/a.mp4" "$TMPD/b.mp4"
  want_rc 0
  want_score 0.95 1
  want_text "PASS (threshold 0.90)"
  want_no_text "note:"
  finish "1 amber to amber passes"

  # 2. Same A, B opens on a test pattern: the seam fails.
  run "$TMPD/a.mp4" "$TMPD/bad.mp4"
  want_rc 1
  want_score 0 0.6
  want_text "FAIL (threshold 0.90)"
  finish "2 amber to test pattern fails"

  # 3. A still saved from the last frame of A against B of case 1: the image path.
  run "$TMPD/a-last.png" "$TMPD/b.mp4"
  want_rc 0
  want_score 0.95 1
  finish "3 png still to clip passes"
  run "$TMPD/a-last.jpg" "$TMPD/b.mp4"
  want_rc 0
  want_score 0.95 1
  finish "3b jpg still to clip passes"
  run "$TMPD/a-last.png" "$TMPD/bad.mp4"
  want_rc 1
  want_score 0 0.6
  finish "3c png still to test pattern fails"

  # 4. Different sizes: B's frame is scaled to A's size and a note says so.
  run "$TMPD/a.mp4" "$TMPD/small.mp4"
  want_rc 0
  want_score 0.95 1
  want_text "note: frame sizes differ (A 128x96, B 64x48)"
  finish "4 different sizes prints the scale note"

  # 5a. --threshold is read, before or after the files.
  run "$TMPD/a.mp4" "$TMPD/bad.mp4" --threshold 0.1
  want_rc 0
  want_text "PASS (threshold 0.1)"
  finish "5a --threshold 0.1 lets the failing seam pass"
  run --threshold 0.1 "$TMPD/a.mp4" "$TMPD/bad.mp4"
  want_rc 0
  finish "5b --threshold before the files"
  run "$TMPD/a.mp4" "$TMPD/b.mp4" --threshold 1
  want_rc 0
  want_text "PASS (threshold 1)"
  finish "5c a score equal to the threshold passes"

  # 6. Usage errors and missing files exit 2.
  run
  want_rc 2
  finish "6a no arguments exits 2"
  run "$TMPD/a.mp4"
  want_rc 2
  finish "6b one argument exits 2"
  run "$TMPD/a.mp4" "$TMPD/b.mp4" "$TMPD/b.mp4"
  want_rc 2
  finish "6c three arguments exits 2"
  run "$TMPD/a.mp4" "$TMPD/b.mp4" --nope
  want_rc 2
  finish "6d unknown option exits 2"
  run "$TMPD/a.mp4" "$TMPD/b.mp4" --threshold
  want_rc 2
  finish "6e --threshold without a value exits 2"
  run "$TMPD/a.mp4" "$TMPD/b.mp4" --threshold high
  want_rc 2
  finish "6f non-numeric threshold exits 2"
  run "$TMPD/missing.mp4" "$TMPD/b.mp4"
  want_rc 2
  finish "6g missing A exits 2"
  run "$TMPD/a.mp4" "$TMPD/missing.mp4"
  want_rc 2
  finish "6h missing B exits 2"
  run "$TMPD/not-a-clip.mp4" "$TMPD/b.mp4"
  want_rc 2
  finish "6i A that is not a clip exits 2"
  run "$TMPD/a.mp4" "$TMPD/not-a-clip.mp4"
  want_rc 2
  finish "6j B that is not a clip exits 2"
  OUT=$(TMPDIR="$TMPD/scratch" PATH="$TMPD/empty-path" sh_run "$TMPD/a.mp4" "$TMPD/b.mp4" 2>&1)
  RC=$?
  want_rc 2
  want_text "ffmpeg not found"
  finish "6k ffmpeg not on PATH exits 2"

  # 7. A low frame rate leaves no frame in the last 0.05 seconds: the last frame is used.
  run "$TMPD/slow.mp4" "$TMPD/b.mp4"
  want_rc 0
  want_score 0.95 1
  want_text "note: no frame in the last 0.05 seconds of A"
  finish "7 low frame rate falls back to the last frame"
}

# Every shell of sh, bash and zsh that exists runs every case.
SH_LIST="sh=/bin/sh"
for s in bash zsh; do
  p=$(command -v "$s" 2>/dev/null)
  if [ -n "$p" ] && [ -x "$p" ]; then
    SH_LIST="$SH_LIST
$s=$p"
  fi
done
WANT=${SEAM_TEST_SHELLS:-"sh bash zsh"}

SHELLS=""
while IFS= read -r entry; do
  SH_NAME=${entry%%=*}
  SH_PATH=${entry#*=}
  case " $WANT " in
    *" $SH_NAME "*) ;;
    *) continue ;;
  esac
  SHELLS="$SHELLS $SH_NAME"
  run_cases
done <<LIST_END
$SH_LIST
LIST_END

if [ "$FAILS" -ne 0 ]; then
  printf 'test.sh: %s case(s) failed\n' "$FAILS"
  exit 1
fi
printf 'test.sh: all cases passed under:%s\n' "$SHELLS"
exit 0
