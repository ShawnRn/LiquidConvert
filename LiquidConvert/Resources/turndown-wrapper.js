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
