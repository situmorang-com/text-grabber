# TextGrabber

A macOS menu bar app that copies text from anything on screen: select an area, and the text is on your clipboard.

## Use

- **⌘⇧1** — select an area; the text is copied. Right-clicking the menu bar icon does the same.
- Menu bar icon — capture the last area again, read a QR code or barcode, read an image on the clipboard, open an image or PDF, recent captures, settings.
- Drop image or PDF files on the app icon to read them.
- The first capture asks for Screen Recording permission. Grant it, then quit and reopen the app.

## Reading windows and small text

- On macOS 26 and later, Apple's document recognition decides what belongs together: paragraphs, list items and table cells, including cells whose text wraps over several lines. The words themselves still come from TextGrabber's own recognition, so enlargement, retries and exact text from apps all still apply. Where it is unavailable, TextGrabber's own layout rules take over.

- A sidebar beside its content, or any panes whose lines do not line up with each other, are read one after the other. Columns of a table or grid, whose rows do line up, stay together.
- Small text is enlarged before reading, based on the height of the letters. This matters most on non-Retina displays.
- A line recognition was unsure about is read a second time from an enlarged crop; this catches small text that would otherwise come back upside-down.

## The editor

"Capture and Edit…" (menu, or a shortcut you set) opens the result in an editor instead of only copying it; Settings can make that the default. "Edit Last Capture…" reopens the last one, and history entries have an Edit button. In the editor you can:

- edit the text, switch line breaks (smart, keep, single line) and format (plain text or Markdown; tables as tabs, CSV or Markdown);
- **translate** it with Apple's on-device translation (macOS 15+), keeping lines and table columns;
- **clean up** recognition mistakes with Apple's on-device model (macOS 26+, Apple Intelligence on). A reply that changes too many words is refused. Check the result: the model can guess wrong.

Nothing leaves the Mac for either.

## Emoji and symbols

Apple's text recognition cannot read emoji or symbols such as ⌘ and ⇧. When the area you capture is a real app window, TextGrabber reads that window's own text through the Accessibility API and uses it for every line it can match, so those characters come out right. The confirmation says "exact text from the app" when this happened.

It needs a second permission: Settings → Recognition → Grant Access. Without it, captures still work with recognition alone. Images, videos and apps that expose no text also fall back to recognition alone.

Every screen capture writes a plain account of what happened to `~/Library/Logs/TextGrabber/last-capture.txt`: whether access is on, which app was under the capture, the text it exposed for each line, and which lines were taken from it. `open "textgrabber://probe?rect=x,y,w,h"` reads an area into that log without touching the clipboard.

To see what an app exposes at a screen point: `TextGrabber --ax-at 400,300` (the terminal you run it from needs Accessibility access).

## Build

```sh
swift test                 # layout engine tests
./scripts/build-app.sh     # builds, installs to /Applications and starts it
```

Run `./scripts/setup-signing.sh` once before the first build. It creates a self-signed signing identity in its own keychain, so rebuilt apps keep their macOS permissions. Without it the app is signed ad hoc, and macOS asks for Screen Recording and Accessibility again after every rebuild (and keeps asking until the stale entry is cleared with `tccutil reset ScreenCapture app.textgrabber.TextGrabber`).

## Tests

- `LayoutEngineTests`: the layout rules on synthetic fragments.
- `CaptureCorpusTests`: real recognition on every image in `Tests/TextGrabberCoreTests/Fixtures/captures`, compared with the text file beside it. Add real screenshots there; see its README.
- `ExactTextTests`: restoring emoji and symbols from an app's text, using misreads Apple's recognition really produced.

The first run in a fresh build can take about a minute while macOS prepares the recognition models; later runs take about a second.

Tests run before every commit. On a fresh clone, turn that on with `git config core.hooksPath scripts/hooks`.

## Automation

URL actions, for Shortcuts ("Open URL"), Raycast, Alfred or scripts:

| URL | Does |
|---|---|
| `textgrabber://capture` | Capture text |
| `textgrabber://capture-edit` | Capture text and open the editor |
| `textgrabber://capture-last-area` | Capture the last area again |
| `textgrabber://capture-keep-lines` | Capture text, keeping line breaks |
| `textgrabber://read-code` | Read a QR code or barcode |
| `textgrabber://clipboard` | Read the image on the clipboard |
| `textgrabber://open?path=/abs/file.png` | Read files (repeat `path` for several) |
| `textgrabber://edit-last` | Reopen the last capture in the editor |
| `textgrabber://history`, `textgrabber://settings` | Open those windows |

Add `edit=1` to any capture action to open the editor for that capture.

## Command line

The same binary reads files when given arguments:

```sh
/Applications/TextGrabber.app/Contents/MacOS/TextGrabber --mode paragraphs scan.png
/Applications/TextGrabber.app/Contents/MacOS/TextGrabber --barcode ticket.png
/Applications/TextGrabber.app/Contents/MacOS/TextGrabber --markdown --translate id table.png
/Applications/TextGrabber.app/Contents/MacOS/TextGrabber --help
```

## Layout

| Path | What it is |
|---|---|
| `Sources/TextGrabberCore/LayoutEngine.swift` | Turns OCR fragments into text: reading order, columns, tables, paragraphs, hyphenation |
| `Sources/TextGrabberCore/Recognizer.swift` | Vision text and barcode recognition, image upscaling, PDF pages |
| `Sources/TextGrabberCore/DocumentLayout.swift` | Lays recognised lines out with Apple's paragraph and table structure |
| `Sources/TextGrabberCore/StructuredText.swift` | Text as blocks and tables; writes plain text, Markdown, CSV |
| `Sources/TextGrabberCore/ExactText.swift` | Matches recognised lines against an app's real text to restore emoji and symbols |
| `Sources/TextGrabber/` | The menu bar app: capture, shortcuts, clipboard, HUD, history, settings, CLI |
| `Tests/TextGrabberCoreTests/` | Layout engine tests |
| `research/` | What other screen-text apps offer, from public sources |
