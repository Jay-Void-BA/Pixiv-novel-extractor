#!/usr/bin/env python3
"""Independently verify pagination and CJK text recovery with Poppler."""
import re
import subprocess

path = "build/test-exports/cjk-long.pdf"
info = subprocess.run(["pdfinfo", path], check=True, capture_output=True, text=True).stdout
pages = int(re.search(r"Pages:\s+(\d+)", info).group(1))
assert pages > 20, pages
text = subprocess.run(["pdftotext", path, "-"], check=True, capture_output=True, text=True).stdout
# Page numbers and soft wrapping can split phrases, so count distinctive glyphs.
assert text.count("長") == 4200, text.count("長")
assert text.count("普") == 600, text.count("普")
assert "物語" in text and "繁體中文" in text
print(f"Verified {pages} PDF pages; all long-paragraph and trailing-paragraph glyphs recovered.")
