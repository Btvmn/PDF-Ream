# PDF Ream

A small native macOS app that splits a PDF into one file per page, merges several PDFs into one, and compresses a PDF down to a size limit you set.

## Why

A scan made with the iPhone Notes app is a full-resolution JPEG per page: twenty pages easily come to 75 MB. Upload forms routinely cap attachments at a few megabytes, and some want one file per page. PDF Ream takes the size limit as the input — you say "2 MB per page" or "10 MB total" and it keeps as much quality as fits under that number.

It uses the system PDFKit and CoreGraphics only: no third-party dependencies, no network access, nothing leaves the machine.

## Install / Build

Only the Xcode Command Line Tools are needed; full Xcode is not.

```sh
xcode-select --install
./build.sh
```

`build.sh` writes `PDF Ream.app` next to itself — a universal binary (arm64 + x86_64), ad-hoc signed. It also draws the icon and builds `build/pdfream-cli` and `build/make_fixtures`, which the test suites use.

The ad-hoc signature is not a Developer ID, so Gatekeeper blocks a copy that was downloaded or moved from another Mac. Right-click the app → **Open** → **Open**, once.

## Usage

Dropping files never starts a job. Files land in a list; the action button does the work.

1. **Add files.** Drop one or several PDFs on the window, or a folder (every PDF inside is collected). Files dropped on the Dock icon or opened from Finder are queued the same way. `⌘O`, the drop zone, and the **Add…** button open a file chooser.
2. **Pick a mode.** The list survives the switch.
   - **Split** — every page becomes its own PDF. Pages heavier than the limit are recompressed; the rest are copied untouched.
   - **Merge** — all queued files become one document. Row order is page order; drag the rows to change it.
   - **Compress** — each file is shrunk separately, staying a single document.
3. **Set the limit** at the bottom of the window. Split has its own per-page limit (default 2 MB); Merge and Compress share a final-file limit (default 10 MB). Both are remembered between launches. The field accepts 0.1–2000 MB.
4. **Press the action button** (`Split` / `Merge` / `Compress`, or `⌘R`). Only now does a save panel open, and the whole queue is processed.

Where the output goes:

| Mode | One file in the queue | Several files |
| --- | --- | --- |
| Split | Save panel; the name becomes a folder `<name> (pages)` holding `<name>_01.pdf`, `<name>_02.pdf`, … | Choose a folder; each input gets its own `<name> (pages)` subfolder |
| Merge | Save panel, default name `Merged.pdf` | Same — one file for the whole list |
| Compress | Save panel, default name `<name> (compressed).pdf` | Choose a folder; one `<name> (compressed).pdf` per input |

Existing files are never overwritten: a numeric suffix is added instead. While a job runs, the window shows progress and refuses new files. On success the list clears and the result offers **Open** / **Show in Finder**; on failure the list stays so you can fix it and press again.

## How compression works

**Lossless first.** Anything that already fits is copied, not re-encoded:

- Split: a page whose own bytes are under the limit is written out as is.
- Compress / Merge: a single file already under the limit is copied byte for byte. Otherwise the document is assembled losslessly first, and if *that* fits, it is saved untouched.

**Then the quality ladder.** Only what still overshoots is re-rendered as JPEG and wrapped back into a PDF page of the original size. A binary search over 15 steps — from 300 dpi at JPEG quality 0.85 down to 40 dpi at 0.20 — picks the highest step that fits.

- Split searches per page, so a heavy page never drags down a light one. If no step fits, the resolution keeps dropping (×0.75 down to 10 dpi) and, failing that, the smallest result is saved and the page is reported as over the limit.
- Compress / Merge render every page at one shared level, so the document stays visually consistent, and keep a page's original bytes whenever they are smaller than the render — text and vector pages usually are.

**Preserved:** page rotation, crop boxes, annotations (they are drawn into the render), and page order. Pages that were not re-rendered stay vector, with selectable text. The JPEG is embedded as a `DCTDecode` stream rather than re-encoded on the way in.

**Not preserved:** a page that had to be re-rendered becomes an image, so its text stops being selectable.

## Testing

`./build.sh` builds both harnesses along with the app: `build/pdfream-cli`, `build/make_fixtures`,
`build/uitest` and `build/snapshot`.

**Engine — 30 assertions.** Needs [qpdf](https://qpdf.sourceforge.io/):

```sh
brew install qpdf
./build.sh
Tools/run_tests.sh /tmp/pdfream-tests
```

The first run generates synthetic "scan" fixtures into `<work-dir>/fixtures` (about 190 MB, including a
75 MB 20-page scan). It checks page counts and sizes, validates every output with `qpdf --check`, and
covers rotation, crop boxes, vector text, byte-for-byte copies, damaged and password-protected files,
non-ASCII paths, and a 60-page run. Speed and peak memory are reported but not asserted, since both
depend on the machine — set `PDFREAM_PERF=1` to turn them into checks.

**UI — 93 assertions.** Drives the real `AppModel` with the save panels scripted instead of shown, so it
runs headless. It reuses the engine fixtures (including `locked.pdf` and `big60.pdf`, which qpdf builds),
so run the engine suite first:

```sh
build/uitest /tmp/pdfream-tests/fixtures /tmp/pdfream-tests/ui
```

It covers the drop-queues-nothing-runs contract in every mode, batch runs, cancelled panels, a double
press of the action button, files that vanish between drop and run, partial and total batch failures,
output-name collisions (including names differing only by case on a case-insensitive volume), Finder
and Dock opens, and input refused while a job runs.

**Snapshots** (optional) render the window offscreen to PNGs — useful for checking layout without a display:

```sh
build/snapshot /tmp/pdfream-tests/fixtures /tmp/pdfream-shots
```

Measured on an M4 Pro with the generated fixtures: the 20-page 75 MB scan splits in 1.4 s with every page
under 2 MB (5 pages were already small enough and were copied untouched); the same file compresses to
8.6 MB in about 3 s; a 60-page version splits in under 5 s.

## Project layout

```
build.sh                  Builds "PDF Ream.app" plus the CLI and fixture tools
Sources/PDFEngine.swift   Split, merge, compress — PDFKit + CoreGraphics, no UI
Sources/AppModel.swift    Queue, modes, save panels, background jobs, status
Sources/ContentView.swift SwiftUI views
Sources/AppDelegate.swift Finder / Dock opens (queue, never process)
Sources/PDFReamApp.swift  App entry point and menu commands
Resources/Info.plist      Bundle metadata
Tools/cli.swift           CLI harness around the engine (build/pdfream-cli)
Tools/run_tests.sh        Engine test suite
Tools/make_fixtures.swift Generates synthetic scan PDFs for the tests
Tools/uitest.swift        Headless UI suite
Tools/snapshot.swift      Offscreen window renderer
Tools/make_icon.swift     Draws the app icon
```

`build.sh` produces `PDF Ream.app` plus `build/pdfream-cli`, `build/make_fixtures`, `build/uitest`
and `build/snapshot`.

`build/` and `PDF Ream.app` are build output and are not committed.

## Requirements and limitations

- **macOS 13 or later**, Apple silicon or Intel.
- **No OCR.** Re-rendered pages become images and lose their text layer; pages that fit keep theirs.
- **No cancel button.** A started job runs to completion, and the window refuses input meanwhile.
- **Password-protected PDFs are not supported** — they are rejected on add, with a message naming the file.
- **Ad-hoc signed, not notarized.** See the Gatekeeper note in [Install / Build](#install--build).
- **Not sandboxed.** macOS may ask once for access to Desktop/Documents/Downloads on the first drop from there.
- Rendering holds a full-page bitmap per worker. The worker count adapts to installed RAM (2, 4, or 6) capped by CPU count; `PDFREAM_WORKERS` overrides it.
