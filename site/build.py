#!/usr/bin/env python3
"""Build the static site: a landing page plus the documentation.

    pip install -r site/requirements.txt
    python site/build.py            # writes site/dist/
    python site/build.py --serve    # builds, then serves it on 127.0.0.1:8788

The pages under /docs/ are rendered from the Markdown files in docs/, which
stay the source: nothing is copied by hand. Links between them become links
between pages; links to other files of the repository go to GitHub. The build
fails if a link between pages points at a page or a heading that is not there.

The site makes no request to any other host: no fonts, scripts or analytics.
"""

import html
import re
import shutil
import sys
from pathlib import Path

from markdown_it import MarkdownIt
from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers import get_lexer_by_name
from pygments.util import ClassNotFound

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "site" / "src"
DIST = ROOT / "site" / "dist"
DOCS = ROOT / "docs"
REPO = "https://github.com/Legatia/omnigate"

# The order and grouping of the documentation menu. Every file in docs/ must
# appear here once; the build says so if one is missing.
MENU = [
    ("Start", [("README", "Overview"), ("quickstart", "Quickstart"), ("configuration", "Configuration"), ("api", "API reference"), ("providers", "Providers")]),
    ("Run it", [("deployment", "Deployment"), ("admin", "Admin"), ("operations", "Operations"), ("upgrading", "Upgrading"), ("security", "Security hardening")]),
    ("Privacy", [("privacy", "Privacy mode"), ("attestation", "Attested inference")]),
    ("Credit and payments", [("credits", "Prepaid credit"), ("payments", "Payments"), ("building-on-omnigate", "Building on omnigate")]),
    ("Reference", [("architecture", "Architecture"), ("migrating-from-litellm", "Migrating from LiteLLM"), ("releasing", "Releasing")]),
]


def url_of(name):
    return "/docs/" if name == "README" else f"/docs/{name}/"


def slug(text, seen):
    """The anchor GitHub gives a heading, so links written for GitHub hold."""
    s = re.sub(r"[^\w\- ]", "", text.strip().lower()).replace(" ", "-")
    n = seen.get(s, 0)
    seen[s] = n + 1
    return s if n == 0 else f"{s}-{n}"


def code_block(code, lang, _attrs):
    lang = (lang or "").strip().split()[0] if lang and lang.strip() else ""
    body = None
    if lang:
        try:
            body = highlight(code, get_lexer_by_name(lang), HtmlFormatter(nowrap=True))
        except ClassNotFound:
            body = None
    if body is None:
        body = html.escape(code)
    return f'<pre class="hl"><code>{body}</code></pre>\n'


def rewrite(href, page, problems, links):
    """Where a link in docs/<page>.md leads on the site."""
    if re.match(r"^[a-z][a-z0-9+.-]*:", href) or href.startswith("#"):
        if href.startswith("#"):
            links.append((page, page, href[1:]))
        return href
    path, _, anchor = href.partition("#")
    if path.startswith("../"):
        rest = path[3:]
        kind = "tree" if rest.endswith("/") or "." not in rest.rsplit("/", 1)[-1] else "blob"
        return f"{REPO}/{kind}/main/{rest}" + (f"#{anchor}" if anchor else "")
    if path.endswith(".md") and (DOCS / path).is_file():
        name = path[:-3]
        links.append((page, name, anchor))
        return url_of(name) + (f"#{anchor}" if anchor else "")
    problems.append(f"docs/{page}.md: link to {href!r} leads nowhere on the site")
    return href


def render(name, problems, links):
    """One Markdown file as (title, body html, table of contents, heading ids)."""
    md = MarkdownIt("commonmark", {"highlight": code_block, "html": True}).enable("table").enable("strikethrough")
    tokens = md.parse((DOCS / f"{name}.md").read_text(encoding="utf-8"))
    seen, toc, ids, title = {}, [], set(), None

    def walk(items):
        for t in items:
            if t.type in ("link_open",) and t.attrGet("href"):
                t.attrSet("href", rewrite(t.attrGet("href"), name, problems, links))
            if t.children:
                walk(t.children)

    walk(tokens)
    for i, t in enumerate(tokens):
        if t.type == "heading_open":
            text = "".join(c.content for c in tokens[i + 1].children if c.type in ("text", "code_inline"))
            level = int(t.tag[1])
            if level == 1 and title is None:
                title = text
                # GitHub counts the title too when it numbers repeated headings.
                slug(text, seen)
                continue
            anchor = slug(text, seen)
            ids.add(anchor)
            t.attrSet("id", anchor)
            if level in (2, 3):
                toc.append((level, anchor, text))

    body = md.renderer.render(tokens, md.options, {})
    body = body.replace("<table>", '<div class="table-wrap"><table>').replace("</table>", "</table></div>")
    # A heading links to itself, so its address can be copied.
    body = re.sub(r'<(h[2-4]) id="([^"]+)">(.*?)</\1>', r'<\1 id="\2"><a class="anchor" href="#\2">\3</a></\1>', body, flags=re.S)
    return title or name, body, toc, ids


def menu_html(current):
    out = []
    for group, items in MENU:
        out.append(f'<p class="group">{html.escape(group)}</p><ul>')
        for name, label in items:
            here = ' aria-current="page"' if name == current else ""
            out.append(f'<li><a href="{url_of(name)}"{here}>{html.escape(label)}</a></li>')
        out.append("</ul>")
    return "\n".join(out)


def toc_html(toc):
    if len(toc) < 3:
        return ""
    out = ['<p class="group">On this page</p><ul>']
    for level, anchor, text in toc:
        out.append(f'<li class="l{level}"><a href="#{anchor}">{html.escape(text)}</a></li>')
    out.append("</ul>")
    return "\n".join(out)


def neighbours(name):
    flat = [item for _, items in MENU for item in items]
    i = [n for n, _ in flat].index(name)
    prev = flat[i - 1] if i > 0 else None
    nxt = flat[i + 1] if i + 1 < len(flat) else None
    out = ['<nav class="pager">']
    out.append(f'<a class="prev" href="{url_of(prev[0])}"><span>Previous</span>{html.escape(prev[1])}</a>' if prev else "<span></span>")
    out.append(f'<a class="next" href="{url_of(nxt[0])}"><span>Next</span>{html.escape(nxt[1])}</a>' if nxt else "<span></span>")
    out.append("</nav>")
    return "".join(out)


def fill(template, values):
    return re.sub(r"\{\{(\w+)\}\}", lambda m: values[m.group(1)], template)


def pygments_css():
    light = HtmlFormatter(style="default").get_style_defs(".hl")
    dark = HtmlFormatter(style="github-dark").get_style_defs(".hl")
    keep = lambda css: "\n".join(line for line in css.splitlines() if not line.startswith((".hl {", "pre {", "td.", "span.", ".hl .hll")))
    return keep(light) + "\n@media (prefers-color-scheme: dark) {\n" + keep(dark) + "\n}\n"


def build():
    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir(parents=True)
    shutil.copytree(SRC / "assets", DIST / "assets")
    (DIST / "assets" / "style.css").write_text((SRC / "style.css").read_text(encoding="utf-8") + "\n" + pygments_css(), encoding="utf-8")

    problems, links, anchors = [], [], {}
    listed = [name for _, items in MENU for name, _ in items]
    on_disk = sorted(p.stem for p in DOCS.glob("*.md"))
    for name in on_disk:
        if name not in listed:
            problems.append(f"docs/{name}.md is not in the menu in site/build.py")
    for name in listed:
        if name not in on_disk:
            problems.append(f"the menu names docs/{name}.md, which does not exist")

    page = (SRC / "doc.html").read_text(encoding="utf-8")
    labels = dict(item for _, items in MENU for item in items)
    for name in [n for n in listed if n in on_disk]:
        title, body, toc, ids = render(name, problems, links)
        anchors[name] = ids
        out = DIST / "docs" / ("" if name == "README" else name) / "index.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(
            fill(
                page,
                {
                    "title": html.escape(labels[name] if name != "README" else "Documentation"),
                    "menu": menu_html(name),
                    "toc": toc_html(toc),
                    "body": body,
                    "pager": neighbours(name),
                    "source": f"{REPO}/blob/main/docs/{name}.md",
                },
            ),
            encoding="utf-8",
        )

    for origin, target, anchor in links:
        if anchor and target in anchors and anchor not in anchors[target]:
            problems.append(f"docs/{origin}.md: no heading #{anchor} in docs/{target}.md")

    shutil.copy(SRC / "index.html", DIST / "index.html")
    shutil.copy(SRC / "404.html", DIST / "404.html")
    # Cloudflare Pages reads this: what a browser may do with these pages.
    (DIST / "_headers").write_text(
        "/*\n"
        "  X-Content-Type-Options: nosniff\n"
        "  X-Frame-Options: DENY\n"
        "  Referrer-Policy: strict-origin-when-cross-origin\n"
        "  Content-Security-Policy: default-src 'none'; img-src 'self' data:; style-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\n"
        "/assets/*\n"
        "  Cache-Control: public, max-age=3600\n",
        encoding="utf-8",
    )

    pages = len(list(DIST.rglob("index.html")))
    if problems:
        for p in problems:
            print("  " + p)
        print(f"{len(problems)} problem(s); the site was written to {DIST} anyway")
        return False
    print(f"{pages} pages written to {DIST}, {len(links)} links between pages checked")
    return True


if __name__ == "__main__":
    ok = build()
    if "--serve" in sys.argv and ok:
        import functools
        import http.server

        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(DIST))
        print("http://127.0.0.1:8788/  (Ctrl-C to stop)")
        http.server.ThreadingHTTPServer(("127.0.0.1", 8788), handler).serve_forever()
    sys.exit(0 if ok else 1)
