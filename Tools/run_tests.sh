#!/bin/bash
# Engine test suite. Usage: Tools/run_tests.sh <work-dir>
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
WORK=${1:-/tmp/pdfream-tests}
CLI=$ROOT/build/pdfream-cli
F=$WORK/fixtures
O=$WORK/out
PASS=0
FAIL=0

command -v qpdf >/dev/null || { echo "qpdf is required for the engine tests: brew install qpdf"; exit 1; }
[ -x "$CLI" ] && [ -x ./build/make_fixtures ] || { echo "run ./build.sh first"; exit 1; }

check() { # check <description> <condition-result>
  if [ "$2" = "1" ]; then PASS=$((PASS + 1)); echo "  ok   $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL $1"; fi
}
bool() { if [ "$@" ]; then echo 1; else echo 0; fi; }
maxsize() { find "$1" -name '*.pdf' -exec stat -f%z {} \; | sort -n | tail -1; }
npages() { "$CLI" info "$1" | head -1 | sed -E 's/.*: ([0-9]+) pages.*/\1/'; }

rm -rf "$O"; mkdir -p "$O"
if [ ! -f "$F/scan20.pdf" ]; then ./build/make_fixtures "$F" >/dev/null; fi
qpdf --encrypt secret owner 256 -- "$F/single.pdf" "$F/locked.pdf" 2>/dev/null
[ -f "$F/big60.pdf" ] || qpdf --empty --pages "$F/scan20.pdf" "$F/scan20.pdf" "$F/scan20.pdf" -- "$F/big60.pdf"

echo "== split: 20 pages, 2 MB limit"
OUT=$("$CLI" split "$F/scan20.pdf" "$O/s20" 2000000)
COUNT=$(ls "$O/s20"/*.pdf | wc -l | tr -d ' ')
MAX=$(maxsize "$O/s20")
check "20 files produced" "$(bool "$COUNT" = 20)"
check "every file <= 2 MB (max $MAX)" "$(bool "$MAX" -le 2000000)"
check "single page per file" "$(bool "$(npages "$O/s20/scan20_07.pdf")" = 1)"
check "numbering is zero padded" "$(bool -f "$O/s20/scan20_01.pdf")"
BAD=0; for f in "$O/s20"/*.pdf; do qpdf --check "$f" >/dev/null 2>&1 || BAD=1; done
check "all files valid per qpdf" "$(bool "$BAD" = 0)"
check "light pages kept lossless" "$(bool "$(echo "$OUT" | grep -c 'recompressed: \[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15\]')" = 1)"

echo "== split: worst case (incompressible noise)"
"$CLI" split "$F/noise2.pdf" "$O/noise" 2000000 >/dev/null
check "noise pages <= 2 MB" "$(bool "$(maxsize "$O/noise")" -le 2000000)"

echo "== split: hard limits"
"$CLI" split "$F/single.pdf" "$O/t30" 30000 >/dev/null
check "30 KB limit respected" "$(bool "$(maxsize "$O/t30")" -le 30000)"
OUT=$("$CLI" split "$F/single.pdf" "$O/t3" 3000)
check "impossible limit reports over_limit" "$(bool "$(echo "$OUT" | grep -c 'over_limit: \[1\]')" = 1)"

echo "== split: rotation, crop box, vector text"
"$CLI" split "$F/rotated.pdf" "$O/rot" 500000 >/dev/null
check "rotated page 2 stays landscape" "$(bool "$("$CLI" info "$O/rot/rotated_02.pdf" | grep -c 'display=842x595')" = 1)"
check "crop box preserved on page 1" "$(bool "$("$CLI" info "$O/rot/rotated_01.pdf" | grep -c 'box=500x700')" = 1)"
"$CLI" split "$F/vector6.pdf" "$O/vec" 2000000 >/dev/null
check "text page stays selectable" "$(bool "$("$CLI" info "$O/vec/vector6_03.pdf" | grep -c 'Vector page 3')" = 1)"
check "text page not recompressed" "$(bool "$(stat -f%z "$O/vec/vector6_03.pdf")" -lt 30000)"

echo "== merge"
"$CLI" combine "$O/merged.pdf" 10000000 "$O/s20"/*.pdf >/dev/null
check "merged has 20 pages" "$(bool "$(npages "$O/merged.pdf")" = 20)"
check "merged <= 10 MB" "$(bool "$(stat -f%z "$O/merged.pdf")" -le 10000000)"
check "merged valid per qpdf" "$(bool "$(qpdf --check "$O/merged.pdf" >/dev/null 2>&1; echo $?)" = 0)"
check "merged keeps JPEG streams" "$(bool "$("$CLI" streams "$O/merged.pdf" | grep -c 'DCTDecode: 20')" = 1)"
"$CLI" combine "$O/mixed.pdf" 5000000 "$F/vector6.pdf" "$F/rotated.pdf" "$F/single.pdf" >/dev/null
check "mixed merge page count" "$(bool "$(npages "$O/mixed.pdf")" = 11)"
check "mixed merge <= 5 MB" "$(bool "$(stat -f%z "$O/mixed.pdf")" -le 5000000)"
check "text survives merge" "$(bool "$("$CLI" info "$O/mixed.pdf" | grep -c 'Vector page 6')" = 1)"
check "page order preserved" "$(bool "$("$CLI" info "$O/mixed.pdf" | sed -n '9p' | grep -c 'display=842x595')" = 1)"

echo "== compress"
OUT=$("$CLI" combine "$O/comp.pdf" 10000000 "$F/scan20.pdf")
check "75 MB compressed <= 10 MB" "$(bool "$(stat -f%z "$O/comp.pdf")" -le 10000000)"
check "compressed keeps 20 pages" "$(bool "$(npages "$O/comp.pdf")" = 20)"
"$CLI" combine "$O/copy.pdf" 10000000 "$F/rotated.pdf" >/dev/null
check "file under limit copied byte for byte" "$(bool "$(cmp -s "$F/rotated.pdf" "$O/copy.pdf"; echo $?)" = 0)"

echo "== errors"
check "broken file" "$(bool "$("$CLI" split "$F/broken.pdf" "$O/e" 2000000 2>&1 | grep -c 'could not open it')" = 1)"
check "not a pdf" "$(bool "$("$CLI" split "$F/notes.txt" "$O/e" 2000000 2>&1 | grep -c 'could not open it')" = 1)"
check "password protected" "$(bool "$("$CLI" split "$F/locked.pdf" "$O/e" 2000000 2>&1 | grep -c 'password-protected')" = 1)"
check "password protected inside merge" "$(bool "$("$CLI" combine "$O/e.pdf" 9999999 "$F/vector6.pdf" "$F/locked.pdf" 2>&1 | grep -c 'password-protected')" = 1)"

# Deliberately non-ASCII: scans exported from Notes often carry names like this.
echo "== paths with spaces and cyrillic"
mkdir -p "$O/Мои сканы"
cp "$F/rotated.pdf" "$O/Мои сканы/Скан из Заметок 12.pdf"
"$CLI" split "$O/Мои сканы/Скан из Заметок 12.pdf" "$O/Мои сканы/Скан (страницы)" 2000000 >/dev/null
check "cyrillic paths" "$(bool -f "$O/Мои сканы/Скан (страницы)/Скан из Заметок 12_04.pdf")"

echo "== large file (60 pages)"
# Pin the worker count: the engine scales it with installed RAM, and so does the memory it uses.
STAT=$(PDFREAM_WORKERS=4 /usr/bin/time -l "$CLI" split "$F/big60.pdf" "$O/big" 2000000 2>&1)
SECS=$(echo "$STAT" | sed -n 's/seconds: //p'); SECS=${SECS:-999}
RSS=$(echo "$STAT" | awk '/maximum resident/ {print int($1/1048576)}'); RSS=${RSS:-999999}
check "60 pages split, max $(maxsize "$O/big") bytes" "$(bool "$(maxsize "$O/big")" -le 2000000)"
# Speed and memory depend on the machine — informational unless PDFREAM_PERF is set.
# Most of the peak is Quartz's own purgeable image cache, which is sized from installed RAM.
if [ -n "${PDFREAM_PERF:-}" ]; then
  check "60 pages in ${SECS}s, peak ${RSS} MB (<1600)" "$(bool "$RSS" -lt 1600)"
  check "60 pages under 15s (${SECS}s)" "$(bool "${SECS%.*}" -lt 15)"
else
  echo "  info 60 pages in ${SECS}s, peak ${RSS} MB (set PDFREAM_PERF=1 to assert)"
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" = 0 ]
