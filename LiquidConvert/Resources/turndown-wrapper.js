//
//  TurndownWrapper.js
//  Lark2Pad
//

// 存储全局变量
window.activeDoc = null;

// 将索引转换为纯字母字符串 (0 -> a, 1 -> b, ..., 25 -> z, 26 -> aa)
function indexToLetters(index) {
    let res = "";
    let n = index;
    do {
        res = String.fromCharCode(97 + (n % 26)) + res;
        n = Math.floor(n / 26) - 1;
    } while (n >= 0);
    return res;
}

// 初始化 Turndown
function initTurndown() {
    window.turndownService = new TurndownService({
        headingStyle: 'atx',
        codeBlockStyle: 'fenced',
        bulletListMarker: '-',
        emDelimiter: '*'
    });
    const gfm = turndownPluginGfm.gfm;
    turndownService.use(gfm);

    // 飞书复制出来的内容本身已经是结构化 HTML。Turndown 默认会为了
    // Markdown 源码安全转义 `>、#、-` 等字符，导致引用和标题变成
    // `\\>`、`\\#`，再同步到 Pad 时反斜杠会被当成正文显示。
    // 这里保留文本中的原始字符，把结构识别交给 Turndown 的规则处理。
    turndownService.escape = function (string) {
        return string;
    };

    // 针对 Etherpad 的定制图文规则
    turndownService.addRule('keepImages', {
        filter: 'img',
        replacement: function (content, node) {
            const src = node.getAttribute('src') || '';
            const name = node.getAttribute('name') || '';
            // 确保输出包含 name 属性
            return '<img src="' + src + '" name="' + name + '">';
        }
    });

    // 针对飞书/Lark 高亮块 (Callout) 的定制规则
    turndownService.addRule('feishuCallout', {
        filter: function (node) {
            if (!node) return false;
            const tagName = node.tagName ? node.tagName.toLowerCase() : '';
            if (tagName === 'callout') return true;
            const className = (node.className || '').toString().toLowerCase();
            const dataType = (node.getAttribute('data-type') || node.getAttribute('data-block-type') || '').toLowerCase();
            if (className.includes('callout') || dataType === 'callout' || dataType === 'highlight') return true;
            return false;
        },
        replacement: function (content, node) {
            const cleanContent = content.trim();
            return '\n\n<section data-type="callout">\n' + cleanContent + '\n</section>\n\n';
        }
    });

    // 针对列表项的定制规则，强制紧凑列表（移除多余空行）
    turndownService.addRule('listItems', {
        filter: 'li',
        replacement: function (content, node, options) {
            content = content
                .replace(/^\n+/, '') // 移除开头的换行
                .replace(/\n+$/, '\n') // 确保结尾只有一个换行
                .replace(/\n/gm, '\n    '); // 处理内部换行的缩进
            var prefix = options.bulletListMarker + ' ';
            var parent = node.parentNode;
            if (parent && parent.nodeName === 'OL') {
                var start = parent.getAttribute('start');
                var index = Array.prototype.indexOf.call(parent.children, node);
                prefix = (start ? Number(start) + index : index + 1) + '. ';
            }
            return (
                prefix + content + (node.nextSibling && !/\n$/.test(content) ? '' : '')
            );
        }
    });
}

// 接收 HTML、清理并返回需下载的图片列表
function loadHtmlAndGetImages(htmlStr) {
    if (!window.turndownService) {
        initTurndown();
    }
    const parser = new DOMParser();
    window.activeDoc = parser.parseFromString(htmlStr, 'text/html');

    // 多余空行清理
    const blocks = window.activeDoc.querySelectorAll('p, div');
    blocks.forEach(node => {
        const text = node.textContent.replace(/[\s\u200B-\u200D\uFEFF]/g, '');
        if (text === '' && !node.querySelector('img, video, iframe')) {
            node.remove();
        }
    });

    // 扩展飞书云文档多图画廊组件 (仅在 DOM 中的 img 数量少于 JSON 列表时补全缺失项)
    const galleries = window.activeDoc.querySelectorAll('[data-ace-gallery-json], [data-gallery-json]');
    galleries.forEach(gallery => {
        const jsonStr = gallery.getAttribute('data-ace-gallery-json') || gallery.getAttribute('data-gallery-json');
        if (!jsonStr) return;
        try {
            const data = JSON.parse(jsonStr);
            const items = data.items || data.file_list || [];
            if (Array.isArray(items) && items.length > 0) {
                const existingImgs = Array.from(gallery.querySelectorAll('img'));
                if (existingImgs.length < items.length) {
                    const existingSrcs = existingImgs.map(i => i.getAttribute('src') || '');
                    const firstImg = existingImgs[0];
                    const firstSrc = firstImg ? (firstImg.getAttribute('src') || '') : '';
                    const firstToken = items[0] ? items[0].file_token : null;

                    items.forEach((item) => {
                        const token = item.file_token || '';
                        const alreadyPresent = existingSrcs.some(src => (token && src.includes(token)) || (item.src && src.includes(decodeURIComponent(item.src))));
                        if (alreadyPresent) return;

                        let newSrc = '';
                        if (item.file_token && firstToken && firstSrc) {
                            newSrc = firstSrc.replace(firstToken, item.file_token);
                        }
                        if (!newSrc && item.src) {
                            newSrc = decodeURIComponent(item.src);
                        }
                        if (!newSrc && item.file_token) {
                            newSrc = 'https://internal-api-drive-stream.feishu.cn/space/api/box/stream/download/preview/' + item.file_token + '/?preview_type=16';
                        }

                        if (newSrc) {
                            const newImg = window.activeDoc.createElement('img');
                            newImg.setAttribute('src', newSrc);
                            gallery.appendChild(newImg);
                        }
                    });
                }
            }
        } catch (e) {
            console.error('Failed to parse Feishu gallery JSON', e);
        }
    });

    // 过滤与防重：去除隐藏/无效 img 标签及紧邻的重复 src
    const rawImages = Array.from(window.activeDoc.querySelectorAll('img'));
    let seenSrcs = new Set();
    rawImages.forEach(img => {
        const style = (img.getAttribute('style') || '').toLowerCase();
        if (style.includes('display: none') || style.includes('display:none') || style.includes('visibility: hidden') || style.includes('visibility:hidden')) {
            img.remove();
            return;
        }
        let src = img.getAttribute('src') || '';
        if (!src || src.startsWith('data:image/svg+xml')) {
            return;
        }
        let cleanSrc = src.split('?')[0];

        // 检查非滑动卡片容器内紧邻的完全相同 src 图片重复
        let isInsideSlider = img.closest('[class*="slider"], [data-type*="slider"], [class*="gallery"]');
        if (!isInsideSlider) {
            let prev = img.previousElementSibling;
            if (prev && prev.tagName && prev.tagName.toLowerCase() === 'img') {
                let prevSrc = (prev.getAttribute('src') || '').split('?')[0];
                if (prevSrc === cleanSrc) {
                    img.remove();
                    return;
                }
            }
            seenSrcs.add(cleanSrc);
        }
    });

    const images = Array.from(window.activeDoc.querySelectorAll('img'));
    let urls = [];
    images.forEach((img, index) => {
        // 给每个图片分配一个纯字母的 name
        const letterName = "img" + indexToLetters(index);
        img.setAttribute('name', letterName);
        img.dataset.l2pid = index.toString();
        
        const src = img.getAttribute('src');
        if (src && !src.startsWith('data:')) {
            urls.push({ id: index, url: src });
        }
    });
    
    return JSON.stringify(urls);
}

function replaceImageAndConvertToMarkdown(replacementsJson) {
    const replacements = JSON.parse(replacementsJson);
    
    // 批量替换图片 src
    replacements.forEach(rep => {
        const img = window.activeDoc.querySelector('img[data-l2pid="' + rep.id + '"]');
        if (img) {
            img.setAttribute('src', rep.base64);
        }
    });
    
    // 直接传入 body 节点而不是 innerHTML 字符串，性能更佳
    let markdown = window.turndownService.turndown(window.activeDoc.body);
    
    // 后置清理额外换行
    markdown = markdown.replace(/\n{3,}/g, '\n\n').trim();
    return markdown;
}

// 直接将加载的 HTML 转为 Markdown，保留原始图片 URL（不替换为 Base64）
function convertToMarkdownDirectly() {
    let markdown = window.turndownService.turndown(window.activeDoc.body);
    markdown = markdown.replace(/\n{3,}/g, '\n\n').trim();
    return markdown;
}
