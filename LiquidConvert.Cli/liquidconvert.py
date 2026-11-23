"""Windows command-line document extraction."""

import argparse
import json
import os
from pathlib import Path
import sys
from tempfile import NamedTemporaryFile
import time
from urllib.parse import unquote, urljoin, urlsplit

import requests
from bs4 import BeautifulSoup
from markdownify import markdownify
from markitdown import FileConversionException, MarkItDown, UnsupportedFormatException


VERSION = "0.1.0"
DOCUMENT_TYPES = {".docx", ".pdf", ".pptx", ".xlsx", ".xls", ".csv", ".json", ".xml"}
TEXT_TYPES = {".txt", ".md", ".markdown"}
HTML_TYPES = {".html", ".htm"}
MAX_DOWNLOAD_BYTES = 64 * 1024 * 1024
DOWNLOAD_TIMEOUT = 25
CONVERSION_ERRORS = (
    OSError, ValueError, requests.RequestException, FileConversionException, UnsupportedFormatException
)


def web_url(source):
    parts = urlsplit(source)
    return parts.scheme.lower() in {"http", "https"} and bool(parts.hostname)


def html_markdown(data, url=None, encoding=None):
    soup = BeautifulSoup(data, "html.parser", from_encoding=encoding)
    wechat = bool(url and urlsplit(url).hostname == "mp.weixin.qq.com")
    article = soup.select_one("#js_content") if wechat else soup.select_one("main article, article, main, [role=main]")
    if wechat and (article is None or not article.get_text(strip=True)):
        raise ValueError("WeChat did not return a readable article")
    content = article or soup.body or soup
    title = soup.select_one("#activity-name") if wechat else None
    if title is None:
        title = soup.title
    heading = title.get_text(" ", strip=True) if title else ""
    for node in content.select("script, style, noscript, template, nav, footer, aside, form, [hidden]"):
        node.decompose()
    for image in content.select("img[data-src]"):
        image["src"] = image["data-src"]
    if url:
        for element, attribute in (("a", "href"), ("img", "src")):
            for node in content.select(f"{element}[{attribute}]"):
                resolved = urljoin(url, node[attribute])
                if web_url(resolved):
                    node[attribute] = resolved
                else:
                    del node[attribute]
    markdown = markdownify(str(content), heading_style="ATX").strip()
    if not markdown:
        raise ValueError("No text could be extracted from the HTML")
    if heading and content.find("h1") is None:
        markdown = f"# {heading}\n\n{markdown}"
    return markdown


def extract_local(path):
    suffix = path.suffix.lower()
    if suffix in TEXT_TYPES:
        with path.open("rb") as file:
            bom = file.read(2)
        return path.read_text(encoding="utf-16" if bom in {b"\xff\xfe", b"\xfe\xff"} else "utf-8-sig")
    if suffix in HTML_TYPES:
        return html_markdown(path.read_bytes())
    if suffix not in DOCUMENT_TYPES:
        raise ValueError(f"Unsupported file type: {suffix or '(none)'}")
    return MarkItDown(enable_plugins=False).convert_local(str(path)).text_content


def extract_url(url):
    deadline = time.monotonic() + DOWNLOAD_TIMEOUT
    with requests.get(url, stream=True, timeout=(8, 8), headers={"User-Agent": f"LiquidConvert/{VERSION}"}) as response:
        response.raise_for_status()
        content_type = response.headers.get("Content-Type", "").partition(";")[0].strip().lower()
        suffix = Path(unquote(urlsplit(response.url).path)).suffix.lower()
        is_document = content_type == "application/pdf" or (
            suffix in DOCUMENT_TYPES and content_type not in {"text/html", "application/xhtml+xml"}
        )
        temporary_suffix = ".pdf" if content_type == "application/pdf" else suffix
        with NamedTemporaryFile(suffix=temporary_suffix, delete=False) as file:
            path = Path(file.name)
            try:
                for chunk in response.iter_content(chunk_size=64 * 1024):
                    if time.monotonic() > deadline:
                        raise ValueError("Download timed out")
                    if file.tell() + len(chunk) > MAX_DOWNLOAD_BYTES:
                        raise ValueError("Download exceeds 64 MiB")
                    file.write(chunk)
                file.close()
                if is_document:
                    return extract_local(path)
                declared_encoding = response.encoding if "charset=" in response.headers.get("Content-Type", "").lower() else None
                if content_type == "text/plain" or suffix in TEXT_TYPES:
                    return path.read_text(encoding=declared_encoding or "utf-8-sig")
                return html_markdown(path.read_bytes(), response.url, declared_encoding)
            finally:
                file.close()
                path.unlink(missing_ok=True)


def extract(source):
    text = extract_url(source) if web_url(source) else extract_local(Path(source))
    if not text.strip():
        raise ValueError("No extractable text was found")
    return text.rstrip() + "\n"


def write_markdown(path, text, *, exclusive=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n", dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
        try:
            file.write(text)
            file.close()
            if exclusive:
                # On Windows rename fails if another process already owns this name.
                temporary.rename(path)
            else:
                temporary.replace(path)
        finally:
            file.close()
            temporary.unlink(missing_ok=True)


def output_stem(source):
    if web_url(source):
        parts = urlsplit(source)
        stem = Path(unquote(parts.path)).stem or parts.hostname
    else:
        stem = Path(source).stem
    stem = "".join(c if c not in '<>:"/\\|?*' and ord(c) >= 32 else "_" for c in stem).strip(" .")[:120] or "document"
    return f"_{stem}" if os.path.isreserved(stem + ".md") else stem


def batch(args):
    directory = args.output_dir.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    exported, failures = [], []
    for source in dict.fromkeys(args.sources):
        try:
            text = extract(source)
            stem = output_stem(source)
            destination = directory / f"{stem}.md"
            counter = 2
            while True:
                try:
                    write_markdown(destination, text, exclusive=True)
                    break
                except FileExistsError:
                    destination = directory / f"{stem}-{counter}.md"
                    counter += 1
            exported.append({"source": source, "output": str(destination)})
            if not args.json:
                print(destination)
        except CONVERSION_ERRORS as error:
            failures.append({"source": source, "error": str(error)})
            print(f"LiquidConvert: {source}: {error}", file=sys.stderr)
    if args.json:
        print(json.dumps({"ok": not failures, "output_dir": str(directory), "ocr_enabled": False,
                          "exported": exported, "failures": failures}, ensure_ascii=False))
    return int(bool(failures))


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    is_batch = argv[:1] == ["--batch"]
    if is_batch or argv[:1] == ["--extract-markdown"]:
        argv.pop(0)
    parser = argparse.ArgumentParser(prog="liquidconvert", description=__doc__)
    parser.add_argument("--version", action="version", version=f"LiquidConvert CLI {VERSION}")
    parser.add_argument("--no-ocr", action="store_true", help="accepted for compatibility; this build uses text extraction")
    if is_batch:
        parser.add_argument("sources", metavar="URL-or-file", nargs="+")
        parser.add_argument("--output-dir", required=True, type=Path)
        parser.add_argument("--json", action="store_true")
    else:
        parser.add_argument("source", metavar="URL-or-file")
        parser.add_argument("--output", "-o", type=Path, help="write UTF-8 Markdown to a file instead of stdout")
        parser.epilog = "Batch usage: liquidconvert --batch URL-or-file ... --output-dir DIR [--json] [--no-ocr]"
    args = parser.parse_args(argv)
    try:
        if is_batch:
            return batch(args)
        text = extract(args.source)
        if args.output:
            if not web_url(args.source) and Path(args.source).resolve() == args.output.resolve():
                raise ValueError("--output must differ from the input file")
            write_markdown(args.output, text)
        else:
            sys.stdout.write(text)
        return 0
    except CONVERSION_ERRORS as error:
        print(f"LiquidConvert: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    raise SystemExit(main())
