#!/usr/bin/env python3
"""Build a self-contained App Icon Generator page with your image already loaded.

Usage:
    python3 make_editor.py <image> [--name "My App"] [--out icon-editor.html] [--open]

Only the Python standard library is used. The page itself does all image work in the
browser and exports a ZIP with every iOS and Android icon size.
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import webbrowser
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parent.parent / "assets" / "editor.html"

MIME = {
    b"\x89PNG": "image/png",
    b"\xff\xd8\xff": "image/jpeg",
    b"RIFF": "image/webp",
}


def detect_mime(path: Path, head: bytes) -> str:
    for magic, mime in MIME.items():
        if head.startswith(magic):
            return mime
    if path.suffix.lower() == ".svg" or b"<svg" in head[:512]:
        return "image/svg+xml"
    sys.exit(f"error: {path} is not a PNG, JPEG, WebP or SVG image")


def js_string(value: str) -> str:
    # json.dumps gives a valid JS string literal; also keep "</script>" from closing the tag.
    return json.dumps(value).replace("</", "<\\/")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", type=Path, help="source icon (square, 1024x1024 recommended)")
    ap.add_argument("--name", default="My App", help="app name shown under the icon previews")
    ap.add_argument("--out", type=Path, default=Path("icon-editor.html"), help="output HTML file")
    ap.add_argument("--open", action="store_true", help="open the page in the default browser")
    args = ap.parse_args()

    if not args.image.is_file():
        sys.exit(f"error: {args.image} not found")
    data = args.image.read_bytes()
    uri = f"data:{detect_mime(args.image, data[:512])};base64,{base64.b64encode(data).decode()}"

    html = TEMPLATE.read_text(encoding="utf-8")
    for placeholder, value in (('"__ICON_SRC__"', uri), ('"__APP_NAME__"', args.name)):
        if html.count(placeholder) != 1:
            sys.exit(f"error: template placeholder {placeholder} missing or duplicated")
        html = html.replace(placeholder, js_string(value))

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(html, encoding="utf-8")
    out = args.out.resolve()
    print(out)

    if args.open:
        if sys.platform == "darwin":
            subprocess.run(["open", str(out)], check=False)
        elif os.name == "nt":
            os.startfile(str(out))  # noqa: S606
        else:
            webbrowser.open(out.as_uri())


if __name__ == "__main__":
    main()
