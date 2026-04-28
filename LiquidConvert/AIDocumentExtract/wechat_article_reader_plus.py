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
import html
import tempfile
import time
import urllib.parse
import urllib.request

from wechat_article_reader import fetch_html, extract_article, UA

IMG_PATTERNS = [
    re.compile(r'<img[^>]+data-src="([^"]+)"', re.I),
    re.compile(r'<img[^>]+data-croporisrc="([^"]+)"', re.I),
    re.compile(r'<img[^>]+src="(https?://[^"]+qpic\.cn[^"]*)"', re.I),
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
            if u not in seen and 'qpic.cn' in u:
                seen.add(u)
                urls.append(u)
                
    # Extract WeChat Picture Post (图文动态) images
    pic_post_imgs = re.findall(r"cdn_url:\s*(?:JsDecode\()?['\"](https?://[^'\"]+(?:qpic\.cn)[^'\"]*)['\"]", page)
    for u in pic_post_imgs:
        u = html.unescape(u).replace('&amp;', '&').replace('\\x26amp;', '&').replace('\\x26', '&').strip()
        if u not in seen:
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
    if os.path.exists(p) and os.access(p, os.X_OK): return p
    p2 = os.path.expanduser('~/.local/share/wechat-article-reader-skill/ocr/macocr')
    if os.path.exists(p2) and os.access(p2, os.X_OK): return p2
    return ''


def get_image_size(path: str) -> tuple[int, int]:
    try:
        out = subprocess.run(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', path], capture_output=True, text=True)
        w = re.search(r'pixelWidth: (\d+)', out.stdout)
        h = re.search(r'pixelHeight: (\d+)', out.stdout)
        if w and h:
            return int(w.group(1)), int(h.group(1))
    except:
        pass
    return 0, 0


def crop_image(path: str, y: int, h: int, out: str) -> bool:
    try:
        # sips --cropToHeightWidth h w --cropOffset y x
        # Note: sips crop is centered by default, but --cropOffset can shift it.
        # However, sips crop logic is a bit tricky. 
        # A simpler way to crop from top is: sips -c h <width> --padToHeightWidth h <width> --padColor 000000
        # Actually, let's use: sips --cropToHeightWidth <h> <w> --cropOffset <offsetY_from_center> <offsetX_from_center>
        # Even better, use: sips -p <new_h> <w> -a <top_offset> (not exactly)
        # Let's use the most reliable way: sips -c <h> <w> (crops from center)
        # To crop from a specific Y, it's easier to use: 
        # sips --cropToHeightWidth <h> <w> --cropOffset <vertical_offset_from_center> 0
        w, total_h = get_image_size(path)
        if w == 0: return False
        
        center_y = total_h / 2
        slice_center_y = y + (h / 2)
        offset_y = slice_center_y - center_y
        
        subprocess.run([
            'sips', '--cropToHeightWidth', str(h), str(w),
            '--cropOffset', str(offset_y), '0',
            path, '--out', out
        ], capture_output=True)
        return True
    except:
        return False


def ocr_one_raw(path: str) -> str:
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


def ocr_one(path: str) -> str:
    w, h = get_image_size(path)
    max_h = 3200
    if h > max_h * 1.2:
        print('[ocr] long image detected (%dx%d), slicing...' % (w, h), file=sys.stderr)
        slices = []
        overlap = 200
        curr_y = 0
        with tempfile.TemporaryDirectory() as tmp:
            while curr_y < h:
                slice_h = min(max_h + overlap, h - curr_y)
                p = os.path.join(tmp, 'slice_%d.jpg' % curr_y)
                if crop_image(path, curr_y, slice_h, p):
                    text = ocr_one_raw(p)
                    if text: slices.append(text)
                curr_y += max_h
        return '\n'.join(slices)
    else:
        return ocr_one_raw(path)


def convert_to_jpg(input_path: str, output_path: str) -> bool:
    try:
        subprocess.run(['sips', '-s', 'format', 'jpeg', input_path, '--out', output_path], capture_output=True, check=True)
        return True
    except:
        return False


def ocr_images(urls: list, limit: int) -> dict:
    ocr_results = {}
    targets = urls[:limit] if limit > 0 else urls
    with tempfile.TemporaryDirectory() as tmp:
        for i, u in enumerate(targets):
            ext = image_ext(u)
            p = os.path.join(tmp, '%03d%s' % (i, ext))
            try:
                download(u, p)
                
                ocr_path = p
                if ext in {'.gif', '.webp'}:
                    jpg_path = os.path.join(tmp, '%03d_conv.jpg' % i)
                    if convert_to_jpg(p, jpg_path):
                        ocr_path = jpg_path
                
                text = ocr_one(ocr_path)
                if text:
                    ocr_results[u] = text
                    print('[ocr] img %d/%d: %d chars' % (i+1, len(targets), len(text)), file=sys.stderr)
                else:
                    print('[ocr] img %d/%d: no text' % (i+1, len(targets)), file=sys.stderr)
            except Exception as e:
                print('[ocr] img %d failed: %s' % (i+1, e), file=sys.stderr)
    if limit > 0 and len(urls) > limit:
        print('[ocr] skipped %d image(s) over --max-ocr-images=%d' % (len(urls) - limit, limit), file=sys.stderr)
    return ocr_results


def integrate_ocr(md: str, ocr_results: dict) -> str:
    def replacer(match):
        full = match.group(0)
        url = match.group(1)
        if url in ocr_results:
            text = ocr_results[url]
            # Wrap in blockquote for better presentation
            quoted = '\n'.join(['> ' + l for l in text.splitlines()])
            return full + '\n\n' + quoted + '\n'
        return full

    # Match ![...](url)
    return re.sub(r'!\[.*?\]\((https?://[^)]+)\)', replacer, md)


def should_ocr(mode: str, n_img: int, density: float, threshold: float) -> bool:
    if mode == 'off':
        return False
    if mode == 'always':
        return n_img > 0
    return n_img > 0 and density <= threshold


def extract_weibo(url: str) -> dict:
    swift_code = """import Cocoa
import WebKit

class HeadlessBrowser: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let url: URL
    
    init(url: URL) {
        self.url = url
        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        self.webView.navigationDelegate = self
    }
    
    func start() {
        let req = URLRequest(url: url)
        webView.load(req)
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            webView.evaluateJavaScript("document.documentElement.outerHTML") { result, error in
                if let html = result as? String {
                    print(html)
                    exit(0)
                } else {
                    print("Error: \\(String(describing: error))")
                    exit(1)
                }
            }
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("Failed: \\(error)")
        exit(1)
    }
}

let args = CommandLine.arguments
if args.count < 2 {
    print("Usage: swift weibo_fetch.swift <url>")
    exit(1)
}

guard let url = URL(string: args[1]) else {
    print("Invalid URL")
    exit(1)
}

let app = NSApplication.shared
let browser = HeadlessBrowser(url: url)
browser.start()

DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
    print("Timeout fetching Weibo URL")
    exit(1)
}

app.run()
"""
    print('[info] fetching weibo via WebKit (takes ~3s)...', file=sys.stderr)
    
    with tempfile.NamedTemporaryFile(mode='w', suffix='.swift', delete=False) as tmp:
        tmp.write(swift_code)
        tmp_path = tmp.name
        
    try:
        res = subprocess.run(['/usr/bin/swift', tmp_path, url], capture_output=True, text=True)
        if res.returncode != 0:
            raise Exception(f"Weibo fetch failed: {res.stderr}\\n{res.stdout}")
        html_content = res.stdout
    finally:
        os.unlink(tmp_path)
    
    author = "Weibo User"
    author_match = re.search(r'<div class="[^"]*woo-box-justifyCenter[^"]*_cut_[^"]*">([^<]+)</div>', html_content)
    if author_match:
        author = author_match.group(1).strip()
        
    text_content = ""
    text_match = re.search(r'<div class="[^"]*_wbtext_[^"]*">(.*?)</div>', html_content, re.S)
    if text_match:
        raw_text = text_match.group(1)
        raw_text = re.sub(r'<br\s*/?>', '\n', raw_text)
        raw_text = re.sub(r'<[^>]+>', '', raw_text)
        text_content = html.unescape(raw_text).strip()
        
    md = f"{text_content}\n\n"
    
    return {
        'url': url,
        'title': 'Weibo Post',
        'author': author,
        'summary': text_content[:100].replace('\n', ' ') + '...' if len(text_content) > 100 else text_content,
        'tags': ['Weibo'],
        'markdown': md,
        'html': html_content
    }

def extract_weibo_images(html_content: str) -> list:
    urls = []
    seen = set()
    imgs = re.findall(r'<img[^>]+src="(https?://[^/]+\.sinaimg\.cn/(orj360|bmiddle|large|mw690|oslarge)/[^"]+)"', html_content)
    for i in imgs:
        u = i[0].replace(f"/{i[1]}/", "/large/")
        u = re.sub(r'https?://[^/]+\.sinaimg\.cn', 'https://tva1.sinaimg.cn', u)
        if u not in seen:
            seen.add(u)
            urls.append(u)
    return urls

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('url')
    ap.add_argument('--format', choices=['json', 'markdown'], default='markdown')
    ap.add_argument('--ocr', choices=['off', 'auto', 'always'], default='always')
    ap.add_argument('--ocr-threshold', type=float, default=120.0,
                    help='Auto OCR when non-space text chars per image are at or below this value')
    ap.add_argument('--max-ocr-images', type=int, default=20,
                    help='Maximum images to OCR in auto/always mode; 0 means no limit')
    ap.add_argument('--output')
    args = ap.parse_args()

    is_weibo = 'weibo.com' in args.url or 'weibo.cn' in args.url

    try:
        if is_weibo:
            article = extract_weibo(args.url)
            page = article['html']
            imgs = extract_weibo_images(page)
            for img_url in imgs:
                article['markdown'] += f"\n\n![]({img_url})\n\n"
        else:
            article = extract_article(args.url)
            page = fetch_html(args.url)
            imgs = extract_images(page)
            
            # For WeChat Image Posts, images are not embedded in article['markdown']
            # We append them manually so integrate_ocr can replace them with text
            for img_url in imgs:
                if img_url not in article['markdown']:
                    article['markdown'] += f"\n\n![]({img_url})\n"
            
        article['ocr_used'] = False
        density = text_density(article['markdown'], len(imgs))
    except Exception as e:
        err_msg = f"Extraction failed: {str(e)}"
        if args.output:
            with open(args.output, 'w', encoding='utf-8') as f:
                if args.format == 'json':
                    import json
                    json.dump({"error": err_msg}, f, ensure_ascii=False)
                else:
                    f.write(err_msg)
        else:
            if args.format == 'json':
                import json
                print(json.dumps({"error": err_msg}))
            else:
                print(err_msg)
        sys.exit(1)

    text_chars = len(re.sub(r'\s+', '', article['markdown']))
    print('[info] imgs=%d text_chars=%d density=%.1f threshold=%.1f' % (
        len(imgs), text_chars, density, args.ocr_threshold), file=sys.stderr)

    if should_ocr(args.ocr, len(imgs), density, args.ocr_threshold):
        print('[ocr] starting (mode=%s)' % args.ocr, file=sys.stderr)
        ocr_results = ocr_images(imgs, args.max_ocr_images)
        if ocr_results:
            article['markdown'] = integrate_ocr(article['markdown'], ocr_results)
            article['ocr_used'] = True
            article['ocr_image_count'] = len(ocr_results)
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
