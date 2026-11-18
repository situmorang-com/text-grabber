# TextGrabber

`README.md` covers features, URL actions, the build and the tests. For signing, permissions and checking how windows look, load the `macos-app-build` skill.

- **Try a change in the real app:** `scripts/build-app.sh --fast` (installs to /Applications and restarts it). `swift build` and `swift test` are enough for logic; their binaries carry the real SDK version too, so Translation works from `.build/debug/TextGrabber`.
- **Drive the installed app:** `scripts/drive.sh "<action>"` runs a `textgrabber://` action and prints the capture log it writes. `probe?rect=x,y,w,h` reads a screen area; `snapshot?window=setup|settings|history|editor` draws a window to a PNG. Every action is in `handle(_:)` in `Sources/TextGrabber/AppMain.swift`.
- **A capture came out wrong:** first reproduce it in `Tests/TextGrabberCoreTests/Fixtures/captures` (see its README) or as a unit test with the recorded OCR lines, then change the layout code.
- **Commits:** the pre-commit hook runs the tests and a content check; on a fresh clone enable it with `git config core.hooksPath scripts/hooks`. This repository holds our own requirements and public research only.
