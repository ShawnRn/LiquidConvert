#!/usr/bin/env python3
"""
wechat_article_reader_plus.py
Developed by Jonathan.
"""

import argparse
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

from wechat_article_reader import fetch_html, extract_article, UA

IMG_PATTERNS = [
    re.compile(r'<img[^>]+data-src="([^"]+)"', re.I),
    re.compile(r'<img[^>]+data-croporisrc="([^"]+)"', re.I),
    re.compile(r'<img[^>]+src="(https?://mmbiz\.qpic\.cn/[^"]+)"', re.I),
]


def extract_images(page: str) -> list:
    m = re.search(r'<div[^>]+id="js_content"[^>]*>(.*?)</div>\s*<script', page, re.S)
    body = m.group(1) if m else page
    urls = []
    seen = set()
    for pat in IMG_PATTERNS:
        for u in pat.findall(body):
            u = html.unescape(u).replace('&amp;', '&').strip()
            if u.startswith('//'):
                u = 'https:' + u
            u = urllib.parse.urljoin('https://mp.weixin.qq.com/', u)
            if u not in seen and 'mmbiz' in u:
                seen.add(u)
                urls.append(u)
    return urls


def text_density(md: str, n_img: int) -> float:
    chars = len(re.sub(r'\s+', '', md))
    return chars / max(n_img, 1)


def download(url: str, dst: str) -> None:
    parsed = urllib.parse.urlparse(url)
    no_query = urllib.parse.urlunparse(parsed._replace(query=''))
    candidates = [url]
    if no_query != url:
        candidates.append(no_query)

    last_error = None
    for candidate in candidates:
        for attempt in range(3):
            req = urllib.request.Request(candidate, headers={
                'User-Agent': UA,
                'Referer': 'https://mp.weixin.qq.com/',
            })
            try:
                with urllib.request.urlopen(req, timeout=30) as r, open(dst, 'wb') as f:
                    f.write(r.read())
                return
            except Exception as e:
                last_error = e
                time.sleep(0.5 * (attempt + 1))
    raise last_error


def image_ext(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    query = urllib.parse.parse_qs(parsed.query)
    fmt = (query.get('wx_fmt') or query.get('tp') or [''])[0].lower()
    path = parsed.path.lower()
    if fmt in {'png', 'gif', 'webp', 'jpeg', 'jpg'}:
        return '.jpg' if fmt == 'jpeg' else '.' + fmt
    if path.endswith(('.jpg', '.jpeg')):
        return '.jpg'
    if path.endswith('.webp'):
        return '.webp'
    if path.endswith('.gif'):
        return '.gif'
    return '.png'


def swift_bin() -> str:
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ocr', 'macocr')
    return p if os.path.exists(p) and os.access(p, os.X_OK) else ''


def ocr_one(path: str) -> str:
    sb = swift_bin()
    if sb:
        try:
            out = subprocess.run([sb, path], capture_output=True, text=True, timeout=60, check=True)
            return out.stdout.strip()
        except Exception as e:
            print('[ocr] swift error: ' + str(e), file=sys.stderr)
    try:
        out = subprocess.run(
            ['shortcuts', 'run', 'OCR', '--input-path', path],
            capture_output=True, text=True, timeout=60, check=True,
        )
        return out.stdout.strip()
    except Exception as e:
        print('[ocr] shortcuts error: ' + str(e), file=sys.stderr)
        return ''


def ocr_images(urls: list, limit: int) -> str:
    chunks = []
    targets = urls[:limit] if limit > 0 else urls
    with tempfile.TemporaryDirectory() as tmp:
        for i, u in enumerate(targets):
            ext = image_ext(u)
            p = os.path.join(tmp, '%03d%s' % (i, ext))
            try:
                download(u, p)
                text = ocr_one(p)
                if text:
                    label = '<!-- image %d -->' % (i + 1)
                    chunks.append(label + '\n' + text)
                    print('[ocr] img %d/%d: %d chars' % (i+1, len(targets), len(text)), file=sys.stderr)
                else:
                    print('[ocr] img %d/%d: no text' % (i+1, len(targets)), file=sys.stderr)
            except Exception as e:
                print('[ocr] img %d failed: %s' % (i+1, e), file=sys.stderr)
    if limit > 0 and len(urls) > limit:
        print('[ocr] skipped %d image(s) over --max-ocr-images=%d' % (len(urls) - limit, limit), file=sys.stderr)
    return '\n\n'.join(chunks)


def should_ocr(mode: str, n_img: int, density: float, threshold: float) -> bool:
    if mode == 'off':
        return False
    if mode == 'always':
        return n_img > 0
    return n_img > 0 and density <= threshold


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('url')
    ap.add_argument('--format', choices=['json', 'markdown'], default='markdown')
    ap.add_argument('--ocr', choices=['off', 'auto', 'always'], default='auto')
    ap.add_argument('--ocr-threshold', type=float, default=120.0,
                    help='Auto OCR when non-space text chars per image are at or below this value')
    ap.add_argument('--max-ocr-images', type=int, default=12,
                    help='Maximum images to OCR in auto/always mode; 0 means no limit')
    ap.add_argument('--output')
    args = ap.parse_args()

    article = extract_article(args.url)
    article['ocr_used'] = False
    page = fetch_html(args.url)
    imgs = extract_images(page)
    density = text_density(article['markdown'], len(imgs))

    text_chars = len(re.sub(r'\s+', '', article['markdown']))
    print('[info] imgs=%d text_chars=%d density=%.1f threshold=%.1f' % (
        len(imgs), text_chars, density, args.ocr_threshold), file=sys.stderr)

    if should_ocr(args.ocr, len(imgs), density, args.ocr_threshold):
        print('[ocr] starting (mode=%s)' % args.ocr, file=sys.stderr)
        ocr_text = ocr_images(imgs, args.max_ocr_images)
        if ocr_text:
            article['markdown'] += '\n\n---\n\n## 图片 OCR 提取\n\n' + ocr_text
            article['ocr_used'] = True
            article['ocr_image_count'] = min(len(imgs), args.max_ocr_images) if args.max_ocr_images > 0 else len(imgs)
        else:
            print('[ocr] no output from any image', file=sys.stderr)
    else:
        print('[info] OCR skipped', file=sys.stderr)

    if args.format == 'markdown':
        lines = [
            '# ' + article['title'],
            '',
            '> 作者：' + article['author'],
            '> 摘要：' + article['summary'],
            '> 标签：' + ', '.join(article['tags']),
            '',
            article['markdown'],
        ]
        out = '\n'.join(lines) + '\n'
    else:
        out = json.dumps(article, ensure_ascii=False, indent=2)

    if args.output:
        with open(args.output, 'w', encoding='utf-8') as f:
            f.write(out)
    else:
        print(out)


if __name__ == '__main__':
    main()
