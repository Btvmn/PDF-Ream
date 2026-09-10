#!/bin/bash
# Engine test suite. Usage: Tools/run_tests.sh <work-dir>
set -uo pipefail
WORK=${1:-/tmp/pdfream-tests}
case $WORK in /*) ;; *) WORK="$PWD/$WORK" ;; esac   # a relative path means relative to where you are
cd "$(dirname "$0")/.."
ROOT=$(pwd)
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
# qpdf exits 3 for warnings. The one warning allowed is the one PDFKit's writer always causes:
# unused objects left in the cross-reference table at offset 0, which qpdf repairs and calls
# "a common error handled correctly by qpdf and most other applications".
valid() {
  local report status other
  report=$(qpdf --check "$1" 2>&1); status=$?
  [ "$status" = 0 ] && return 0
  # Collect first, then test: a "grep -q" at the end of a pipe would SIGPIPE the grep before it,
  # and under pipefail a long report of real damage would come out as a pass.
  other=$(printf '%s\n' "$report" | grep '^WARNING' | grep -v 'object has offset 0')
  [ "$status" = 3 ] && [ -z "$other" ]
}
qpdf_make() { qpdf "$@"; local status=$?; [ "$status" = 0 ] || [ "$status" = 3 ]; }

missing=0
for name in scan20.pdf noise2.pdf rotated.pdf vector6.pdf annotated.pdf single.pdf structured.pdf text40.pdf broken.pdf notes.txt; do
  [ -f "$F/$name" ] || missing=1
done
if [ "$missing" = 1 ]; then
  echo "generating fixtures in $F (about 200 MB)"
  ./build/make_fixtures "$F" >/dev/null || { echo "make_fixtures failed"; exit 1; }
fi
# A user password (cannot be opened) and an owner password only (opens; printing and copying restricted).
qpdf_make --encrypt secret owner 256 -- "$F/single.pdf" "$F/locked.pdf" || { echo "qpdf could not build locked.pdf"; exit 1; }
qpdf_make --encrypt "" owner 256 --print=none --extract=n -- "$F/single.pdf" "$F/restricted.pdf" \
  || { echo "qpdf could not build restricted.pdf"; exit 1; }
[ -f "$F/big60.pdf" ] || qpdf_make --empty --pages "$F/scan20.pdf" "$F/scan20.pdf" "$F/scan20.pdf" -- "$F/big60.pdf" \
  || { echo "qpdf could not build big60.pdf"; exit 1; }
# Five pages that all draw the same 4.7 MB image: a background shared by every page.
[ -f "$F/shared5.pdf" ] || qpdf_make --empty --pages "$F/single.pdf" 1,1,1,1,1 -- "$F/shared5.pdf" \
  || { echo "qpdf could not build shared5.pdf"; exit 1; }
rm -rf "$O"; mkdir -p "$O"

echo "== split: 20 pages, 2 MB limit"
OUT=$("$CLI" split "$F/scan20.pdf" "$O/s20" 2000000)
COUNT=$(ls "$O/s20"/*.pdf | wc -l | tr -d ' ')
MAX=$(maxsize "$O/s20")
check "20 files produced" "$(bool "$COUNT" = 20)"
check "every file <= 2 MB (max $MAX)" "$(bool "$MAX" -le 2000000)"
check "single page per file" "$(bool "$(npages "$O/s20/scan20_07.pdf")" = 1)"
check "numbering is zero padded" "$(bool -f "$O/s20/scan20_01.pdf")"
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

echo "== split: annotations are drawn into a re-rendered page"
# PDFKit writes the fixture's free-text annotation with a zero stream /Length, so CoreGraphics
# logs "CoreGraphics PDF has logged an error" once here; it reads the stream correctly anyway.
OUT=$("$CLI" split "$F/annotated.pdf" "$O/annot" 2000000)
check "annotated page was re-rendered" "$(bool "$(echo "$OUT" | grep -c 'recompressed: \[1\]')" = 1)"
check "annotations are flattened into the image" "$(bool "$("$CLI" structure "$O/annot/annotated_01.pdf" | grep -c '^annotations: 0$')" = 1)"
RGB=$("$CLI" pixel "$O/annot/annotated_01.pdf" 0 63 530)
check "the red square annotation is still visible (rgb $RGB)" "$(echo "$RGB" | awk '{ print ($1 > 150 && $2 < 110 && $3 < 110) ? 1 : 0 }')"

echo "== merge"
"$CLI" combine "$O/merged.pdf" 10000000 "$O/s20"/*.pdf >/dev/null
check "merged has 20 pages" "$(bool "$(npages "$O/merged.pdf")" = 20)"
check "merged <= 10 MB" "$(bool "$(stat -f%z "$O/merged.pdf")" -le 10000000)"
check "merged keeps JPEG streams" "$("$CLI" streams "$O/merged.pdf" | grep -c 'DCTDecode: 20')"
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

echo "== compression uses the room it is given"
# Text pages share one embedded font; judged page by page they look far heavier than they are.
OUT=$("$CLI" combine "$O/book.pdf" 800000 "$F/text40.pdf" "$F/single.pdf")
BYTES=$(echo "$OUT" | sed -n 's/^bytes: //p'); BYTES=${BYTES:-0}
check "40 text pages + a scan fit in 800 KB" "$(bool "$(echo "$OUT" | grep -c '^fits: true$')" = 1)"
check "using most of it ($BYTES bytes), not the lowest step" "$(bool "$BYTES" -ge 400000)"
check "every text page keeps its text" "$(bool "$("$CLI" info "$O/book.pdf" | grep -c 'text=[^-]')" = 40)"
OUT=$("$CLI" combine "$O/tiny.pdf" 10000 "$F/vector6.pdf")
check "an impossible limit never makes the file bigger" "$(bool "$(stat -f%z "$O/tiny.pdf")" -le "$(stat -f%z "$F/vector6.pdf")")"
check "and is reported as not fitting" "$(bool "$(echo "$OUT" | grep -c '^fits: false$')" = 1)"
# Keeping any one of these pages keeps the whole image, so only rendering all of them helps.
OUT=$("$CLI" combine "$O/shared.pdf" 3000000 "$F/shared5.pdf")
check "an image shared by every page still compresses under 3 MB ($(stat -f%z "$O/shared.pdf") bytes)" \
  "$(bool "$(echo "$OUT" | grep -c '^fits: true$')" = 1)"
check "and keeps its 5 pages" "$(bool "$(npages "$O/shared.pdf")" = 5)"

echo "== bookmarks, links and document info"
OUT=$("$CLI" combine "$O/structured-comp.pdf" 2000000 "$F/structured.pdf")
S=$("$CLI" structure "$O/structured-comp.pdf")
check "compress had to re-render the scan page" "$(bool "$(echo "$OUT" | grep -c '^recompressed: true$')" = 1)"
check "title and author kept" "$(bool "$(echo "$S" | grep -c -e '^title: Structured fixture$' -e '^author: PDF Ream tests$')" = 2)"
check "bookmarks kept, nesting included" "$(bool "$(echo "$S" | grep -c '^outline: Intro@1, Scan@3, -Details@4, End@5$')" = 1)"
check "links still land on their pages" "$(bool "$(echo "$S" | grep -c '^links: p1>4 p2>3 p5>1$')" = 1)"
"$CLI" combine "$O/structured-merge.pdf" 20000000 "$F/vector6.pdf" "$F/structured.pdf" >/dev/null
S=$("$CLI" structure "$O/structured-merge.pdf")
check "merge moves bookmarks with their pages" "$(bool "$(echo "$S" | grep -c '^outline: Intro@7, Scan@9, -Details@10, End@11$')" = 1)"
check "merge moves links with their pages" "$(bool "$(echo "$S" | grep -c '^links: p7>10 p8>9 p11>7$')" = 1)"

echo "== errors"
check "broken file" "$(bool "$("$CLI" split "$F/broken.pdf" "$O/e" 2000000 2>&1 | grep -c 'could not open it')" = 1)"
check "not a pdf" "$(bool "$("$CLI" split "$F/notes.txt" "$O/e" 2000000 2>&1 | grep -c 'could not open it')" = 1)"
check "password protected" "$(bool "$("$CLI" split "$F/locked.pdf" "$O/e" 2000000 2>&1 | grep -c 'password-protected')" = 1)"
check "password protected inside merge" "$(bool "$("$CLI" combine "$O/e.pdf" 9999999 "$F/vector6.pdf" "$F/locked.pdf" 2>&1 | grep -c 'password-protected')" = 1)"
check "a file that cannot be opened creates no folder" "$(bool ! -e "$O/e")"

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

echo "== every output is a valid PDF"
# First make sure the check can fail: a PDF cut short is reported as damaged.
head -c "$(( $(stat -f%z "$F/vector6.pdf") / 2 ))" "$F/vector6.pdf" > "$WORK/cut.pdf"
check "the validator rejects a damaged PDF" "$(valid "$WORK/cut.pdf" && echo 0 || echo 1)"
rm -f "$WORK/cut.pdf"
BAD=""; N=0
while IFS= read -r -d '' f; do
  N=$((N + 1))
  valid "$f" || BAD="$BAD $(basename "$f")"
done < <(find "$O" -name '*.pdf' -print0)
check "all $N outputs pass qpdf --check${BAD:+ (failed:$BAD)}" "$(bool -z "$BAD")"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" = 0 ]
