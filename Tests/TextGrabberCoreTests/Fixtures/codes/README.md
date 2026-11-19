# Code corpus

Captures with QR codes and barcodes, drawn by `scripts/make-code-fixtures.swift` (system fonts at 2x, codes
pixel-exact). Each `name.txt` is what should reach the clipboard: the code alone when the capture is about the
code, or the text followed by the code when the text was wanted too (`CodeTriage`).

| Capture | Expect |
|---|---|
| code-caption, code-url-below, code-wifi, code-two-stores, code-product-barcode | the code only |
| code-clipped-text | the code only: the text around it was cut by the selection |
| code-poster, code-invoice, code-dark-pairing | text, then the code |

Add a real capture that came out wrong here, with the text you wanted beside it.
