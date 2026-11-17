#!/bin/sh
# tests/mutate.sh: prove that tests/test.sh fails when seam-check.sh is broken.
#
#   sh tests/mutate.sh
#
# For each mutation, sed writes a mutated copy of seam-check.sh into a mktemp folder,
# the script checks the copy differs from the original and still parses, and then
# runs tests/test.sh against it (SEAM_CHECK names the copy). A mutation the test
# turns red is "killed"; one the test lets through is "survived".
# Exit 0 when every mutation was killed, 1 when any survived or could not be tested.

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../seam-check.sh"
TESTSH="$HERE/test.sh"

[ -f "$SRC" ] || {
  printf 'mutate.sh: no script at %s\n' "$SRC" >&2
  exit 2
}

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/seam-mutate.XXXXXX") || exit 2
MUT="$TMPD/mutant.sh"
LOG="$TMPD/test.log"
cleanup() {
  rm -f "$MUT" "$LOG"
  rmdir "$TMPD" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Mutations never depend on the shell, so one shell is enough and keeps the run short.
SEAM_TEST_SHELLS=sh
export SEAM_TEST_SHELLS

# Baseline: the original must pass, or a "killed" below would mean nothing.
if ! SEAM_CHECK="$SRC" sh "$TESTSH" >"$LOG" 2>&1; then
  printf 'mutate.sh: the unmutated script does not pass tests/test.sh; fix that first\n' >&2
  exit 2
fi
printf 'baseline: tests/test.sh passes on the unmutated script\n'

TOTAL=0
KILLED=0
BAD=0

# mutate NAME SED_EXPRESSION
mutate() {
  _name=$1
  _expr=$2
  TOTAL=$((TOTAL + 1))
  sed "$_expr" "$SRC" >"$MUT"
  if cmp -s "$SRC" "$MUT"; then
    printf 'ERROR    %s: the sed expression changed nothing\n' "$_name"
    BAD=$((BAD + 1))
    return
  fi
  if ! sh -n "$MUT" 2>/dev/null; then
    printf 'ERROR    %s: the mutated copy does not parse\n' "$_name"
    BAD=$((BAD + 1))
    return
  fi
  SEAM_CHECK="$MUT" sh "$TESTSH" >"$LOG" 2>&1
  _rc=$?
  if [ "$_rc" -eq 1 ]; then
    _first=$(grep '^FAIL' "$LOG" | head -n 1 | sed 's/ ::.*//')
    printf 'killed   %s (first red case: %s)\n' "$_name" "${_first#FAIL }"
    KILLED=$((KILLED + 1))
  elif [ "$_rc" -eq 0 ]; then
    printf 'survived %s\n' "$_name"
    BAD=$((BAD + 1))
  else
    printf 'ERROR    %s: tests/test.sh exited %s instead of failing a case\n' "$_name" "$_rc"
    BAD=$((BAD + 1))
  fi
}

mutate "sample A at its first frame instead of its end" 's/-sseof -0\.05/-ss 0/'
mutate "sample B at 1 second instead of 0" 's/-ss 0 -i "[$]B"/-ss 1 -i "$B"/'
mutate "drop the image branch" 's/A_IS_IMAGE=1 ;;/A_IS_IMAGE=0 ;;/'
mutate "flip the comparison at the threshold" 's/s>=t/s<t/'
mutate "compare strictly above the threshold" 's/s>=t/s>t/'
mutate "ignore --threshold" 's/T=[$]2/T=0.90/'
mutate "change the default threshold" 's/^T="0\.90"$/T="0.10"/'
mutate "drop the scale step" 's/if \[ "[$]SIZE_A" != "[$]SIZE_B" \]/if false/'
mutate "drop the scale note" "s/^  printf 'note: frame sizes differ.*\$/  :/"
mutate "drop the low frame rate fallback" 's/if \[ ! -s "[$]FA" \]; then/if false; then/'
mutate "print one decimal instead of three" 's/%\.3f/%.1f/'
mutate "change exit 1 to 0" 's/^  exit 1$/  exit 0/'
mutate "change exit 2 to 0" 's/exit 2/exit 0/g'
mutate "remove the cleanup trap" 's/^trap cleanup EXIT$/:/'

printf '%s of %s mutations killed\n' "$KILLED" "$TOTAL"
if [ "$BAD" -ne 0 ]; then
  printf 'mutate.sh: %s mutation(s) survived or could not be tested\n' "$BAD"
  exit 1
fi
exit 0
