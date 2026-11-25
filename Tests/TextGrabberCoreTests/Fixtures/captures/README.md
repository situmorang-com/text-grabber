# Capture corpus

Each `name.png` is a capture; the text files beside it say what TextGrabber should produce.

- `name.txt`: expected text in Smart Paragraphs mode.
- `name.keep.txt`: expected text in Keep Every Line Break mode.

To add a case, save a real screenshot here and write the text you want next to it. If TextGrabber cannot produce it yet, add the name to `known-gaps.txt`.

The first six images and the `table-digit-cell-*` tables are generated, not real screenshots. Real captures (chat windows, web pages, terminals, low-contrast text) are worth more.

Findings from real captures so far (the captures themselves held private screen content and were not kept):

- A 1x capture of a three-pane window: 10 of 25 known phrases read exactly at its own size, 18 of 25 enlarged 3x.
- Across real pane boundaries 11–19 % of rows line up closely; across real table columns 100 %.
- Lines read upside-down come back with confidence 0.3–0.5; correct lines with 1.0.
