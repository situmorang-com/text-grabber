# TextGrabber

A macOS menu bar app that copies text from anything on screen: select an area, and the text is on your clipboard.

## Use

- **⌘⇧1** — select an area; the text is copied. Right-clicking the menu bar icon does the same.
- Menu bar icon — capture the last area again, read a QR code or barcode, read an image on the clipboard, open an image or PDF, recent captures, settings.
- Drop image or PDF files on the app icon to read them.
- The first capture asks for Screen Recording permission. Grant it, then quit and reopen the app.

## Emoji and symbols

Apple's text recognition cannot read emoji or symbols such as ⌘ and ⇧. When the area you capture is a real app window, TextGrabber reads that window's own text through the Accessibility API and uses it for every line it can match, so those characters come out right. The confirmation says "exact text from the app" when this happened.

It needs a second permission: Settings → Recognition → Grant Access. Without it, captures still work with recognition alone. Images, videos and apps that expose no text also fall back to recognition alone.

Every screen capture writes a plain account of what happened to `~/Library/Logs/TextGrabber/last-capture.txt`: whether access is on, which app was under the capture, the text it exposed for each line, and which lines were taken from it. `open "textgrabber://probe?rect=x,y,w,h"` reads an area into that log without touching the clipboard.

To see what an app exposes at a screen point: `TextGrabber --ax-at 400,300` (the terminal you run it from needs Accessibility access).

## Build

```sh
swift test                 # layout engine tests
./scripts/build-app.sh     # makes build/TextGrabber.app
open build/TextGrabber.app
```

Run `./scripts/setup-signing.sh` once before the first build. It creates a self-signed signing identity in its own keychain, so rebuilt apps keep their macOS permissions. Without it the app is signed ad hoc, and macOS asks for Screen Recording and Accessibility again after every rebuild (and keeps asking until the stale entry is cleared with `tccutil reset ScreenCapture app.textgrabber.TextGrabber`).

## Tests

- `LayoutEngineTests`: the layout rules on synthetic fragments.
- `CaptureCorpusTests`: real recognition on every image in `Tests/TextGrabberCoreTests/Fixtures/captures`, compared with the text file beside it. Add real screenshots there; see its README.
- `ExactTextTests`: restoring emoji and symbols from an app's text, using misreads Apple's recognition really produced.

The first run in a fresh build can take about a minute while macOS prepares the recognition models; later runs take about a second.

Tests run before every commit. On a fresh clone, turn that on with `git config core.hooksPath scripts/hooks`.

## Command line

The same binary reads files when given arguments:

```sh
build/TextGrabber.app/Contents/MacOS/TextGrabber --mode paragraphs scan.png
build/TextGrabber.app/Contents/MacOS/TextGrabber --barcode ticket.png
build/TextGrabber.app/Contents/MacOS/TextGrabber --help
```

## Layout

| Path | What it is |
|---|---|
| `Sources/TextGrabberCore/LayoutEngine.swift` | Turns OCR fragments into text: reading order, columns, tables, paragraphs, hyphenation |
| `Sources/TextGrabberCore/Recognizer.swift` | Vision text and barcode recognition, image upscaling, PDF pages |
| `Sources/TextGrabberCore/ExactText.swift` | Matches recognised lines against an app's real text to restore emoji and symbols |
| `Sources/TextGrabber/` | The menu bar app: capture, shortcuts, clipboard, HUD, history, settings, CLI |
| `Tests/TextGrabberCoreTests/` | Layout engine tests |
| `research/` | What other screen-text apps offer, from public sources |
