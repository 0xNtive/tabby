#!/usr/bin/env python3
"""Render ../../TERMS.md into ../terms.html (text kept identical). Run after editing TERMS.md:
    python3 site/tools/terms-to-html.py
Handles the Markdown TERMS.md uses: headings, paragraphs, lists, blockquotes, **bold**, *italic*,
`code` and bare URLs."""
import html, re, pathlib

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE.parent.parent / "TERMS.md"
OUT = HERE.parent / "terms.html"
TEMPLATE = HERE / "terms.template.html"
LICENSE_URL = "https://github.com/0xNtive/tabby/blob/main/LICENSE"


def inline(text: str) -> str:
    out = html.escape(text, quote=False)
    out = re.sub(r"`LICENSE`", f'<a href="{LICENSE_URL}"><code>LICENSE</code></a>', out)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"(?<![\w*])\*([^*]+)\*(?![\w*])", r"<em>\1</em>", out)
    # bare URLs; keep a trailing period outside the link
    out = re.sub(r"(https?://[^\s<]+?)(\.?)(?=\s|$)", r'<a href="\1">\1</a>\2', out)
    return out


def render(md: str) -> tuple[str, str]:
    lines = md.splitlines()
    parts, title, i = [], "", 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if line.startswith("# "):
            title = line[2:].strip()
            parts.append(f"<h1>{inline(title)}</h1>")
            i += 1
        elif line.startswith("## "):
            text = line[3:].strip()
            slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
            parts.append(f'<h2 id="{slug}">{inline(text)}</h2>')
            i += 1
        elif line.startswith("> "):
            quote = []
            while i < len(lines) and lines[i].startswith(">"):
                quote.append(lines[i][1:].strip())
                i += 1
            parts.append(f"<blockquote><p>{inline(' '.join(quote))}</p></blockquote>")
        elif line.startswith("- "):
            items = []
            while i < len(lines) and lines[i].startswith("- "):
                items.append(lines[i][2:].strip())
                i += 1
            parts.append("<ul>\n" + "\n".join(f"  <li>{inline(t)}</li>" for t in items) + "\n</ul>")
        else:
            para = []
            while i < len(lines) and lines[i].strip() and not lines[i].startswith(("#", "> ", "- ")):
                para.append(lines[i].strip())
                i += 1
            parts.append(f"<p>{inline(' '.join(para))}</p>")
    return title, "\n".join(parts)


def main() -> None:
    title, body = render(SRC.read_text(encoding="utf-8"))
    page = TEMPLATE.read_text(encoding="utf-8").replace("{{BODY}}", body)
    OUT.write_text(page, encoding="utf-8")
    print(f"wrote {OUT.relative_to(HERE.parent.parent)} ({title})")


if __name__ == "__main__":
    main()
