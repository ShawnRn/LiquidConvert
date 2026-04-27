#!/usr/bin/env python3
"""
wechat_article_reader.py

A standalone WeChat article reader for agents.
Developed by Jonathan.
"""

import argparse
import html
import json
import re
import sys
import urllib.error
import urllib.request

UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'
NOISE_KEYWORDS = [
    '微信扫一扫', '继续滑动看下一个', '向上滑动看下一个', '轻触阅读原文', '预览时标签不可点',
    '使用小程序', '允许', '取消', '知道了', '分析', '打开此内容', '完整服务', '赞', '在看',
    '分享', '留言', '收藏', '听过', '关注该公众号', '我们正在招募伙伴', '简历投递邮箱', '邮件标题',
    '更多岗位信息请点击这里', '视频', '小程序'
]
HEADING_CANDIDATES = [
    '48 位科学家的答案', '门票消失了', 'AI 正在毁掉下一个 Hinton', '谁负责培养 AI 做不了的事的人？'
]
TAG_RULES = [
    ('AI', ['ai', '人工智能', '大模型', '模型', '智能体', 'agent', 'llm']),
    ('苹果', ['apple', 'iphone', 'ipad', 'mac', 'vision pro', 'siri']),
    ('微信文章', ['mp.weixin.qq.com']),
    ('科研', ['科研', '科学家', '实验室', '论文', 'nature', '研究']),
    ('人才', ['招聘', '岗位', '就业', '人才', '研究生']),
    ('公司组织', ['组织', '管理', '层级', '协作', '效率']),
    ('商业', ['商业', '公司', '增长', '市场', '竞争优势']),
    ('OpenAI', ['openai', 'sam altman', 'chatgpt']),
    ('Anthropic', ['anthropic', 'claude']),
    ('腾讯', ['腾讯', '微信', '元宝']),
    ('字节', ['字节', '豆包', '抖音']),
    ('小米', ['小米', '雷军']),
    ('华为', ['华为', '鸿蒙']),
    ('自动驾驶', ['自动驾驶', '智驾', 'robotaxi']),
    ('芯片', ['芯片', '英伟达', 'nvidia', 'gpu']),
]


def fetch_html(url: str) -> str:
    req = urllib.request.Request(url, headers={'User-Agent': UA})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.read().decode('utf-8', 'ignore')
    except urllib.error.HTTPError as e:
        raise RuntimeError(f'HTTP {e.code} 抓取失败: {url}') from e
    except urllib.error.URLError as e:
        raise RuntimeError(f'网络错误: {e.reason}') from e


def pick(page: str, patterns: list[str]) -> str:
    for pat in patterns:
        m = re.search(pat, page, re.S)
        if m:
            return m.group(1)
    return ''


def clean_title(raw: str) -> str:
    title = html.unescape(raw).replace("\\'", "'").strip()
    title = title.split("'.html(false);")[0].strip()
    title = re.sub(r'\s+', ' ', title)
    return title


def clean_markdown(lines: list[str]) -> str:
    out = []
    for line in lines:
        if line in HEADING_CANDIDATES:
            out.append(f'### {line}')
            continue
        if re.fullmatch(r'第?[一二三四五六七八九十0-9]+[、，.]?.{0,25}', line) and len(line) <= 20:
            out.append(f'### {line}')
            continue
        if line.startswith('- '):
            out.append(line)
            continue
        out.append(line)

    text = '\n\n'.join(out)
    text = re.sub(r'\n{3,}', '\n\n', text).strip()
    text = text.replace('——但谁来告诉它该写什么？', '，但谁来告诉它该写什么？')
    text = text.replace('如果我们适应——我认为我们必须适应——那我们就能存活', '如果我们适应，我认为我们必须适应，那我们就能存活')
    text = text.replace('李祀石', '李世石')
    return text


def infer_tags(url: str, title: str, author: str, desc: str, body: str) -> list[str]:
    haystack = ' '.join([url, title, author, desc, body]).lower()
    tags = []
    for tag, keywords in TAG_RULES:
        if any(k.lower() in haystack for k in keywords):
            tags.append(tag)
    if author and author not in {'未知'} and author not in tags:
        tags.append(author)
    if not tags:
        tags = ['微信文章']
    elif '微信文章' not in tags:
        tags.append('微信文章')
    return tags[:6]


def extract_article(url: str) -> dict:
    page = fetch_html(url)

    title = clean_title(pick(page, [r"var\s+msg_title\s*=\s*\'(.*?)\';", r'<meta property="og:title" content="(.*?)"']))
    if not title:
        raise RuntimeError('无法提取文章标题，页面结构可能已变化或触发了验证')

    summary = pick(page, [r'msg_desc = htmlDecode\("(.*?)"\);', r'<meta name="description" content="(.*?)"'])
    summary = html.unescape(summary).replace('\\x26quot;', '"').strip()

    author = pick(page, [r'nickname=\\x22(.*?)\\x22', r'var\s+nickname\s*=\s*htmlDecode\("(.*?)"\)'])
    author = html.unescape(author).strip() or '未知'

    body = ''
    m = re.search(r'<div[^>]+id="js_content"[^>]*>(.*)', page, re.S)
    if m:
        body = m.group(1)
    body = re.sub(r'<script.*?</script>', '', body, flags=re.S)
    body = re.sub(r'<style.*?</style>', '', body, flags=re.S)
    body = re.sub(r'<br\s*/?>', '\n', body, flags=re.I)
    body = re.sub(r'</p>|</section>|</li>|</h\d>|</div>', '\n', body, flags=re.I)
    body = re.sub(r'<li[^>]*>', '- ', body, flags=re.I)
    body = re.sub(r'<[^>]+>', '', body)
    body = html.unescape(body).replace('\xa0', ' ')

    lines = [x.strip() for x in body.splitlines()]
    clean = []
    for line in lines:
        if not line or line in {'×', '：', '，', '。'}:
            continue
        if any(k in line for k in NOISE_KEYWORDS):
            continue
        clean.append(line)

    markdown = clean_markdown(clean)
    tags = infer_tags(url, title, author, summary, markdown)

    return {
        'url': url,
        'title': title,
        'author': author,
        'summary': summary,
        'tags': tags,
        'markdown': markdown,
    }


def main():
    parser = argparse.ArgumentParser(description='Read and clean a WeChat article into Markdown')
    parser.add_argument('url', help='WeChat article URL, like https://mp.weixin.qq.com/s/...')
    parser.add_argument('--format', choices=['json', 'markdown'], default='json', help='Output format')
    parser.add_argument('--output', help='Write result to a local file instead of stdout')
    args = parser.parse_args()

    try:
        article = extract_article(args.url)
        if args.format == 'markdown':
            output = f"# {article['title']}\n\n> 作者：{article['author']}\n>\n> 摘要：{article['summary']}\n>\n> 标签：{', '.join(article['tags'])}\n\n{article['markdown']}\n"
        else:
            output = json.dumps(article, ensure_ascii=False, indent=2)

        if args.output:
            with open(args.output, 'w', encoding='utf-8') as f:
                f.write(output)
        else:
            print(output)
    except RuntimeError as e:
        print(f'错误: {e}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
