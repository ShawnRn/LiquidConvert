// ==UserScript==
// @name         微信公众号滑动组件一键排版工具 (WXLayout Helper)
// @namespace    https://ifanr.com/
// @version      2.2.2
// @description  在微信公众号后台编辑器中，一键将平铺导入的图片及提示词自动重构为左右滑动/上下滑动组件。支持微信官方图床链接，避免直贴时发生 CORS 图片载入失败或图片丢失。同时支持纯前端免后端的 HTML/Markdown 本地文件选择导入并自动转存微信图床。
// @author       Antigravity (Gemini Team)
// @match        https://mp.weixin.qq.com/*
// @icon         https://res.wx.qq.com/a/wx_fed/assets/res/NTI4MWU5.ico
// @grant        GM_xmlhttpRequest
// @connect      *
// @allFrames    true
// @run-at       document-end
// ==/UserScript==

(function() {
    'use strict';
    
    // 顶级初始化日志
    console.log(`[WXLayout] v2.2.5 脚本载入！当前 URL: ${window.location.href}, 是否在 Iframe 内: ${window.self !== window.top}`);

    // 动态注入精美 CSS 样式系统 (Glassmorphism & Rich Aesthetics)
    const styleElement = document.createElement('style');
    styleElement.innerHTML = `
        /* 浮动控制面板 */
        .l2p-panel {
            position: fixed;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            width: 480px;
            background: rgba(22, 22, 25, 0.88);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            border: 1px solid rgba(255, 255, 255, 0.12);
            border-radius: 16px;
            box-shadow: 0 20px 50px rgba(0, 0, 0, 0.45);
            color: #ffffff;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            z-index: 1000000;
            overflow: hidden;
            display: none;
        }
        .l2p-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 16px 20px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.08);
            background: rgba(255, 255, 255, 0.02);
        }
        .l2p-title {
            font-size: 15px;
            font-weight: 700;
            letter-spacing: 0.5px;
            background: linear-gradient(135deg, #07c160, #10b981);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .l2p-close {
            cursor: pointer;
            color: rgba(255, 255, 255, 0.5);
            font-size: 22px;
            line-height: 20px;
            transition: color 0.2s;
        }
        .l2p-close:hover {
            color: #fa5151;
        }
        .l2p-body {
            padding: 20px;
            min-height: 200px;
            max-height: 480px;
            overflow-y: auto;
        }
        
        /* 功能卡片样式 */
        .l2p-card {
            background: rgba(255, 255, 255, 0.04);
            border: 1px solid rgba(255, 255, 255, 0.06);
            border-radius: 12px;
            padding: 18px;
            margin-bottom: 14px;
            cursor: pointer;
            transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1);
            display: flex;
            align-items: center;
            justify-content: space-between;
        }
        .l2p-card:hover {
            background: rgba(255, 255, 255, 0.08);
            border-color: rgba(7, 193, 96, 0.6);
            transform: translateY(-2px);
            box-shadow: 0 4px 12px rgba(7, 193, 96, 0.15);
        }
        .l2p-card-content {
            flex: 1;
        }
        .l2p-card-title {
            font-size: 14px;
            font-weight: 600;
            margin-bottom: 4px;
            color: #ffffff;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .l2p-card-desc {
            font-size: 11px;
            color: rgba(255, 255, 255, 0.45);
            line-height: 1.5;
        }
        .l2p-card-icon {
            color: #07c160;
            margin-right: 12px;
            display: flex;
            align-items: center;
        }

        /* 输入区 / 文件选择器 */
        .l2p-textarea-container {
            display: none;
            flex-direction: column;
        }
        
        /* 进度条与日志 */
        .l2p-progress-container {
            display: none;
            flex-direction: column;
        }
        .l2p-progress-info {
            display: flex;
            justify-content: space-between;
            font-size: 12px;
            margin-bottom: 8px;
            color: rgba(255, 255, 255, 0.8);
        }
        .l2p-progress-bg {
            width: 100%;
            height: 6px;
            background: rgba(255, 255, 255, 0.1);
            border-radius: 3px;
            overflow: hidden;
            margin-bottom: 16px;
        }
        .l2p-progress-bar {
            height: 100%;
            background: linear-gradient(90deg, #07c160, #10b981);
            width: 0%;
            transition: width 0.2s ease;
        }
        .l2p-log {
            background: rgba(0, 0, 0, 0.4);
            border: 1px solid rgba(255, 255, 255, 0.08);
            border-radius: 8px;
            height: 160px;
            overflow-y: auto;
            padding: 10px 14px;
            font-family: monospace;
            font-size: 11px;
            color: rgba(255, 255, 255, 0.7);
            margin-bottom: 16px;
            box-sizing: border-box;
        }
        .l2p-log-item {
            margin-bottom: 4px;
            line-height: 1.5;
        }
        .log-info { color: #57b3ff; }
        .log-success { color: #07c160; }
        .log-warning { color: #ffc300; }
        .log-error { color: #fa5151; }

        /* 按钮底栏 */
        .l2p-action-bar {
            display: flex;
            justify-content: flex-end;
            gap: 10px;
        }
        .l2p-btn {
            padding: 8px 16px;
            border-radius: 6px;
            font-size: 12px;
            font-weight: 600;
            cursor: pointer;
            border: none;
            transition: all 0.2s;
        }
        .btn-primary {
            background: #07c160;
            color: #ffffff;
        }
        .btn-primary:hover {
            background: #06ae56;
        }
        .btn-secondary {
            background: rgba(255, 255, 255, 0.1);
            color: #ffffff;
        }
        .btn-secondary:hover {
            background: rgba(255, 255, 255, 0.15);
        }
        .btn-disabled {
            background: rgba(255, 255, 255, 0.05) !important;
            color: rgba(255, 255, 255, 0.2) !important;
            cursor: not-allowed !important;
        }
    `;
    document.head.appendChild(styleElement);

    // 提示 Toast
    function showToast(message, isSuccess = true) {
        const toast = document.createElement('div');
        toast.style.position = 'fixed';
        toast.style.top = '20px';
        toast.style.left = '50%';
        toast.style.transform = 'translateX(-50%)';
        toast.style.padding = '12px 24px';
        toast.style.borderRadius = '8px';
        toast.style.color = '#ffffff';
        toast.style.backgroundColor = isSuccess ? '#07c160' : '#fa5151';
        toast.style.boxShadow = '0 4px 12px rgba(0, 0, 0, 0.15)';
        toast.style.zIndex = '9999999';
        toast.style.fontFamily = 'system-ui, -apple-system, sans-serif';
        toast.style.fontSize = '14px';
        toast.style.fontWeight = 'bold';
        toast.style.transition = 'opacity 0.3s ease';
        toast.innerText = message;

        document.body.appendChild(toast);
        
        setTimeout(() => {
            toast.style.opacity = '0';
            setTimeout(() => toast.remove(), 300);
        }, 3000);
    }

    // 跨 iframe 检索正文编辑器容器 (ProseMirror/Body)
    // 搜寻当前 document 中所有候选编辑器节点（兼容微信 v1/v2 及 ProseMirror）
    function findEditorsInDoc(doc, sourcePrefix) {
        const found = [];
        try {
            // 微信 v2 编辑器特定选择器（优先级最高，先匹配）
            const wxV2Selectors = [
                '#js_editor_content',
                '.js_editor_content',
                '[data-role="editor"]',
                '#edui1_iframeholder [body]',
                '.edui-body-container',
                '#editor'
            ];
            for (const sel of wxV2Selectors) {
                try {
                    doc.querySelectorAll(sel).forEach(ed => {
                        if (ed) found.push({ node: ed, source: `${sourcePrefix} (WX-V2: ${sel})`, priority: 200 });
                    });
                } catch (ex) {}
            }

            // ProseMirror（v1 旧版编辑器）
            doc.querySelectorAll('.ProseMirror').forEach(ed => {
                if (ed) found.push({ node: ed, source: `${sourcePrefix} (ProseMirror)`, priority: 150 });
            });

            // 通用 contenteditable（捕捉任何富文本区域）
            doc.querySelectorAll('[contenteditable="true"], [contenteditable=""]').forEach(ed => {
                if (ed) found.push({ node: ed, source: `${sourcePrefix} (contenteditable)`, priority: 100 });
            });
        } catch (ex) {}
        return found;
    }

    function getActiveEditor(isDiagnostic = false) {
        const candidates = [];

        // 1. 搜寻当前 frame
        findEditorsInDoc(document, 'Current Frame').forEach(c => candidates.push(c));

        // 2. 递归搜寻所有子 iframe（微信编辑器经常嵌套多层）
        try {
            document.querySelectorAll('iframe').forEach(iframe => {
                try {
                    const iDoc = iframe.contentDocument || (iframe.contentWindow && iframe.contentWindow.document);
                    if (iDoc) {
                        findEditorsInDoc(iDoc, `Iframe[${iframe.id || iframe.className || 'anon'}]`).forEach(c => candidates.push(c));
                    }
                } catch (ex) { /* 跨域忽略 */ }
            });
        } catch (ex) {}

        if (candidates.length === 0) {
            if (isDiagnostic) console.warn('[WXLayout] 搜寻编辑器：没有找到任何有效编辑器实例。');
            return null;
        }

        if (isDiagnostic) {
            console.log('[WXLayout] 候选编辑器列表:',
                candidates.map(c => `${c.source} id=${c.node.id} class=${c.node.className}`));
        }

        // 加权选出最佳编辑器节点
        let best = null;
        let bestScore = -Infinity;

        for (const c of candidates) {
            const ed = c.node;
            let score = c.priority || 0;

            try {
                score += (ed.querySelectorAll('img').length || 0) * 50;
                score += Math.min(ed.innerText ? ed.innerText.length : 0, 3000);

                const cls = (ed.className || '') + ' ' + (ed.id || '');
                // 过滤标题/摘要/描述等非正文区域
                if (/title|digest|desc|author|source_name/i.test(cls)) score -= 2000;
                // 过滤 placeholder 提示为标题/摘要的节点
                const ph = ed.getAttribute('placeholder') || ed.getAttribute('data-placeholder') || '';
                if (/标题|摘要|选填|作者|来源/i.test(ph)) score -= 2000;
            } catch (ex) {}

            if (score > bestScore) {
                bestScore = score;
                best = ed;
            }
        }

        if (isDiagnostic && best) {
            console.log(`[WXLayout] 已选最佳编辑器: id=${best.id} class=${best.className} score=${bestScore}`);
        }

        return best;
    }

    // 扫描并重构正文中的滑动提示段落
    function convertSliders(editorElement) {
        console.log("[WXLayout] ================== 开始扫描滑动段落 (v2.2.5) ==================");
        let count = 0;

        const paragraphs = Array.from(editorElement.querySelectorAll('p, section, div, h1, h2, h3, h4, h5, h6, span'));
        
        for (let i = 0; i < paragraphs.length; i++) {
            const p = paragraphs[i];
            if (!p || !p.parentNode || !editorElement.contains(p)) continue;
            const text = p.innerText.trim();
            
            const isLeftSwipe = /向左滑动查看|左右滑动查看/i.test(text);
            const isUpDownSwipe = /上下滑动查看/i.test(text);

            if (isLeftSwipe || isUpDownSwipe) {
                console.log(`[WXLayout] 锁定滑动提示段落: "${text}"`);
                
                // 1. 收集滑动提示上方所有的平铺图片
                const imagesToGroup = [];
                let sibling = p.previousElementSibling;
                const emptyNodesToRemove = [];
                
                while (sibling) {
                    let img = null;
                    if (sibling.tagName === 'IMG') {
                        const src = sibling.getAttribute('data-src') || sibling.src || "";
                        if (src.startsWith('http') && !src.includes('data:image')) {
                            img = sibling;
                        }
                    } else {
                        const subImgs = sibling.querySelectorAll('img');
                        const realImgs = Array.from(subImgs).filter(i => {
                            const src = i.getAttribute('data-src') || i.src || "";
                            return src.startsWith('http') && !src.includes('data:image');
                        });
                        if (realImgs.length >= 1) {
                            img = realImgs[0];
                        }
                    }

                    if (img) {
                        if (img.src.includes('yd2qr5ofbspk7y3smytx3514yidjgoc2.gif')) {
                            break;
                        }
                        imagesToGroup.unshift({
                            node: sibling,
                            src: img.getAttribute('data-src') || img.src
                        });
                        sibling = sibling.previousElementSibling;
                    } else {
                        const siblingText = sibling.innerText.trim();
                        let subImgsCount = 0;
                        try {
                            subImgsCount = Array.from(sibling.querySelectorAll('img')).filter(i => {
                                const src = i.getAttribute('data-src') || i.src || "";
                                return src.startsWith('http') && !src.includes('data:image');
                            }).length;
                        } catch(ex) {}
                        
                        if (subImgsCount === 0 && (siblingText === "" || siblingText === "\u200b" || sibling.innerHTML.trim() === "<br>")) {
                            emptyNodesToRemove.push(sibling);
                            sibling = sibling.previousElementSibling;
                        } else {
                            break;
                        }
                    }
                }

                // 2. 收集下方的滑动小手指指引
                let fingerGifNode = null;
                if (isLeftSwipe) {
                    let nextSibling = p.nextElementSibling;
                    while (nextSibling) {
                        let nextImg = null;
                        if (nextSibling.tagName === 'IMG') {
                            const src = nextSibling.getAttribute('data-src') || nextSibling.src || "";
                            if (src.startsWith('http') && !src.includes('data:image')) {
                                nextImg = nextSibling;
                            }
                        } else {
                            const subImgs = nextSibling.querySelectorAll('img');
                            const realImgs = Array.from(subImgs).filter(i => {
                                const src = i.getAttribute('data-src') || i.src || "";
                                return src.startsWith('http') && !src.includes('data:image');
                            });
                            if (realImgs.length >= 1) {
                                nextImg = realImgs[0];
                            }
                        }
                        
                        if (nextImg) {
                            if (nextImg.src.includes('yd2qr5ofbspk7y3smytx3514yidjgoc2.gif')) {
                                fingerGifNode = nextSibling;
                            }
                            break;
                        } else {
                            const nextText = nextSibling.innerText.trim();
                            const nextImgsCount = nextSibling.querySelectorAll('img').length;
                            if (nextImgsCount === 0 && (nextText === "" || nextText === "\u200b" || nextSibling.innerHTML.trim() === "<br>")) {
                                emptyNodesToRemove.push(nextSibling);
                                nextSibling = nextSibling.nextElementSibling;
                            } else {
                                break;
                            }
                        }
                    }
                }

                if (imagesToGroup.length === 0) continue;

                // 3. 构造新的滑动组件 HTML 代码（严格对齐参考文件格式）
                let newHtml = "";
                if (isLeftSwipe) {
                    // 参考：向左滑动图片.html
                    // 外层容器 section -> margin-bottom:32px 容器和小字提示 & gif都在内部
                    const N = imagesToGroup.length;
                    const containerWidthPercent = N * 100;
                    const itemWidthPercent = (100 / N).toFixed(3);

                    let itemsHtml = "";
                    imagesToGroup.forEach(img => {
                        itemsHtml += `<section style="display: inline-block; width: ${itemWidthPercent}%; min-width: ${itemWidthPercent}%; max-width: ${itemWidthPercent}%;"><img src="${img.src}" style="min-width: 100%; max-width: 100%; padding-right: 5px;"></section>`;
                    });

                    newHtml = `<section style="font-family: system-ui, -apple-system, &quot;Segoe UI&quot;, Roboto, &quot;Helvetica Neue&quot;, Arial, sans-serif;"><section style="margin-bottom: 32px; font-size: 0px;"><section class="overflow-scrolling" style="min-width: 100%; max-width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch;"><section style="min-width: ${containerWidthPercent}%; max-width: ${containerWidthPercent}%;">${itemsHtml}</section></section><section style="margin: 6px 0px; font-size: 12px; line-height: 17px; color: rgb(167, 167, 167);">向左滑动查看更多内容</section><img src="https://wxlayout.ifanrusercontent.com/yd2qr5ofbspk7y3smytx3514yidjgoc2.gif" style="width: 42px; max-height: 10px;"></section></section>`;

                } else if (isUpDownSwipe) {
                    // 参考：上下滑动.html
                    // height:300px 无边框，内容粀子
                    const targetImg = imagesToGroup[0];
                    newHtml = `<section style="font-family: system-ui, -apple-system, &quot;Segoe UI&quot;, Roboto, &quot;Helvetica Neue&quot;, Arial, sans-serif;"><section style="width: 100%; height: 300px; overflow: hidden;"><section style="display: flex; flex-direction: column; height: 100%; overflow-y: auto;"><img src="${targetImg.src}" style="display: block; width: 100%;"></section></section><section style="margin: 6px 0px; font-size: 12px; line-height: 17px; color: rgb(167, 167, 167); text-align: center;">上下滑动查看更多内容</section></section>`;
                }

                // 4. 利用 Range 替换段落 (防 ProseMirror 回滚)
                const range = document.createRange();
                const lastNode = fingerGifNode || p;

                try {
                    editorElement.focus();
                    range.setStartBefore(imagesToGroup[0].node);
                    range.setEndAfter(lastNode);

                    const sel = window.getSelection();
                    sel.removeAllRanges();
                    sel.addRange(range);

                    const success = document.execCommand('insertHTML', false, newHtml);
                    if (success) {
                        count++;
                    } else {
                        throw new Error("execCommand 返回 false");
                    }
                } catch (err) {
                    // Fallback 物理删除及插入
                    const wrapper = document.createElement('section');
                    wrapper.innerHTML = newHtml;
                    const insertBeforeNode = imagesToGroup[0].node;
                    insertBeforeNode.parentNode.insertBefore(wrapper, insertBeforeNode);

                    imagesToGroup.forEach(img => img.node.remove());
                    emptyNodesToRemove.forEach(node => node.remove());
                    p.remove();
                    if (fingerGifNode) fingerGifNode.remove();
                    count++;
                }
            }
        }

        if (count > 0) {
            editorElement.dispatchEvent(new Event('input', { bubbles: true }));
            
            setTimeout(() => {
                editorElement.focus();
                const range = document.createRange();
                const sel = window.getSelection();
                range.selectNodeContents(editorElement);
                range.collapse(false);
                sel.removeAllRanges();
                sel.addRange(range);
            }, 100);
            
            showToast(`成功重构并排版 ${count} 个滑动图集！`);
        } else {
            console.log("[WXLayout] 未检测到未处理的滑动提示段落。");
        }
        return count;
    }

    // 跨域下载图片为 Blob
    function fetchImageBlob(url) {
        return new Promise((resolve, reject) => {
            if (typeof GM_xmlhttpRequest === 'undefined') {
                fetch(url)
                    .then(res => {
                        if (!res.ok) throw new Error(`HTTP ${res.status}`);
                        return res.blob();
                    })
                    .then(resolve)
                    .catch(reject);
                return;
            }
            
            GM_xmlhttpRequest({
                method: 'GET',
                url: url,
                responseType: 'blob',
                onload: function(response) {
                    if (response.status >= 200 && response.status < 300) {
                        resolve(response.response);
                    } else {
                        reject(new Error(`下载失败，HTTP状态码: ${response.status}`));
                    }
                },
                onerror: function(err) {
                    reject(err);
                }
            });
        });
    }

    // 递归深度遍历 JSON，寻找以 mmbiz.qpic.cn 开头的微信图床链接
    function findWechatImageUrl(obj) {
        if (typeof obj === 'string') {
            if (obj.includes('mmbiz.qpic.cn')) {
                return obj;
            }
            return null;
        }
        if (obj && typeof obj === 'object') {
            for (const key in obj) {
                if (Object.prototype.hasOwnProperty.call(obj, key)) {
                    const res = findWechatImageUrl(obj[key]);
                    if (res) return res;
                }
            }
        }
        return null;
    }

    // 模拟微信上传图片接口，返回微信图床 URL
    function uploadToWechat(blob, filename, mimeType, token) {
        return new Promise((resolve, reject) => {
            const file = new File([blob], filename, { type: mimeType });
            const formData = new FormData();
            // 兼容可能的多字段名，确保微信服务端百分百接收
            formData.append('uploadfile', file, filename);
            formData.append('file', file, filename);
            formData.append('media', file, filename);
            
            const uploadUrl = `https://mp.weixin.qq.com/cgi-bin/filetransfer?action=upload_material&f=json&writetype=doublewrite&has_preview=1&token=${token}&lang=zh_CN`;
            
            GM_xmlhttpRequest({
                method: 'POST',
                url: uploadUrl,
                data: formData,
                onload: function(response) {
                    if (response.status >= 200 && response.status < 300) {
                        try {
                            const result = JSON.parse(response.responseText);
                            if (result.base_resp && result.base_resp.ret === 0) {
                                // 深度搜索微信图床 URL，完美匹配字段变化
                                const wechatUrl = findWechatImageUrl(result);
                                if (wechatUrl) {
                                    resolve(wechatUrl);
                                } else {
                                    reject(new Error("上传成功，但在返回的 JSON 中未找到微信图床 URL (mmbiz.qpic.cn)"));
                                }
                            } else {
                                const errMsg = result.base_resp ? result.base_resp.err_msg : '未知返回';
                                reject(new Error(`微信接口报错: ${errMsg} (代码 ${result.base_resp ? result.base_resp.ret : '-'})`));
                            }
                        } catch (e) {
                            reject(new Error(`JSON解析失败: ${response.responseText}`));
                        }
                    } else {
                        reject(new Error(`上传失败，HTTP状态码: ${response.status}`));
                    }
                },
                onerror: function(err) {
                    reject(err);
                }
            });
        });
    }

    // 物理清空编辑器并插入极清 HTML（兼容微信 v1/v2 编辑器）
    function writeToEditor(htmlContent, showToastOnError = true) {
        const editor = getActiveEditor();
        if (!editor) {
            if (showToastOnError) showToast('未找到活动编辑器，无法导入', false);
            return false;
        }

        console.log(`[WXLayout] 准备写入编辑器: id=${editor.id} class=${editor.className}`);

        // 路径 0：微信私有 JSAPI（最符合内部状态同步）
        try {
            const jsapi = window.__MP_Editor_JSAPI__ ||
                (window.top && window.top.__MP_Editor_JSAPI__);
            if (jsapi) {
                console.log('[WXLayout] 应用微信内部 JSAPI 路径写入...');
                if (typeof jsapi.setContent === 'function') {
                    jsapi.setContent(htmlContent);
                    console.log('[WXLayout] JSAPI setContent 调用成功');
                    return true;
                }
                if (typeof jsapi.insertHTML === 'function') {
                    jsapi.clear && jsapi.clear();
                    jsapi.insertHTML(htmlContent);
                    console.log('[WXLayout] JSAPI insertHTML 调用成功');
                    return true;
                }
                console.warn('[WXLayout] JSAPI 存在但无 setContent/insertHTML 方法，内部方法:', Object.keys(jsapi));
            }
        } catch (jsapiErr) {
            console.warn('[WXLayout] JSAPI 路径失败:', jsapiErr);
        }

        try {
            // 1. 先聚焦 & 全选 & 尝试 execCommand 删除现有内容
            editor.focus();
            document.execCommand('selectAll', false, null);
            document.execCommand('delete', false, null);

            // 2. 尝试 insertHTML
            const sel = window.getSelection();
            if (!sel || sel.rangeCount === 0) {
                const r = document.createRange();
                r.selectNodeContents(editor);
                r.collapse(false);
                sel && sel.removeAllRanges();
                sel && sel.addRange(r);
            }

            const insertOk = document.execCommand('insertHTML', false, htmlContent);
            if (insertOk) {
                console.log('[WXLayout] execCommand insertHTML 成功');
                // 触发微信框架感知内容变更的事件链
                editor.dispatchEvent(new InputEvent('input', { bubbles: true, cancelable: true }));
                editor.dispatchEvent(new Event('change', { bubbles: true }));
                return true;
            }
        } catch (e) {
            console.warn('[WXLayout] execCommand 路径失败，回退到 innerHTML:', e);
        }

        // 3. innerHTML 直接覆盖 fallback（保底方案）
        try {
            editor.innerHTML = htmlContent;
            editor.dispatchEvent(new InputEvent('input', { bubbles: true, cancelable: true }));
            editor.dispatchEvent(new Event('change', { bubbles: true }));
            console.log('[WXLayout] innerHTML fallback 写入完成');
            return true;
        } catch (e2) {
            console.error('[WXLayout] innerHTML 写入也失败:', e2);
            return false;
        }
    }

    // 监听主窗口发来的写入和排版请求 (多 Frame 协同处理)
    window.addEventListener('message', function(event) {
        if (event.data && event.data.type === 'L2P_WRITE_EDITOR') {
            console.log("[WXLayout] 子 Frame 收到写入编辑器请求，开始执行本地物理写入...");
            const htmlContent = event.data.html;
            
            const editor = getActiveEditor();
            if (editor) {
                const ok = writeToEditor(htmlContent, false);
                if (ok) {
                    console.log("[WXLayout] 子 Frame 物理写入成功，开始重构滑动排版组件...");
                    const sliderCount = convertSliders(editor);
                    console.log(`[WXLayout] 子 Frame 滑动组件重构完毕: ${sliderCount} 组`);
                    
                    // 向父窗口回传协同写入成功的确认消息
                    if (window.parent && window.parent !== window) {
                        window.parent.postMessage({
                            type: 'L2P_WRITE_SUCCESS',
                            sliderCount: sliderCount
                        }, '*');
                    }
                }
            } else {
                console.warn("[WXLayout] 子 Frame 收到导入消息，但未在本地检测到活动编辑器，忽略之。");
            }
        }
    });

    // 纯前端一键图床转换与整篇 HTML 导入核心流程
    async function startHtmlImport(htmlInput, token, addLog, setProgress) {
        addLog("开始分析极清 HTML 源码...", "info");
        
        const parser = new DOMParser();
        const doc = parser.parseFromString(htmlInput, 'text/html');
        const images = Array.from(doc.querySelectorAll('img'));
        
        // 提取所有唯一的外链图片 (忽略微信自带图床、base64及相对地址)
        const urlToNodeMap = [];
        images.forEach(img => {
            const dataSrc = img.getAttribute('data-src') || '';
            const src = img.getAttribute('src') || '';
            const targetUrl = dataSrc.startsWith('http') ? dataSrc : (src.startsWith('http') ? src : '');
            
            if (targetUrl && !targetUrl.includes('mmbiz.qpic.cn') && !targetUrl.startsWith('data:image')) {
                urlToNodeMap.push({
                    node: img,
                    url: targetUrl
                });
            }
        });

        const uniqueUrls = Array.from(new Set(urlToNodeMap.map(x => x.url)));
        addLog(`分析完毕！共发现 ${images.length} 张图片，其中有 ${uniqueUrls.length} 张需要转存的外链图片。`, "info");

        // 统一处理替换方法
        const writeAndReconstruct = async (processedHtmlString) => {
            addLog("正在写入微信编辑器 (ProseMirror)...", "info");
            let writeDone = false;
            
            // 1. 尝试在主 frame 本地直接写入
            if (writeToEditor(processedHtmlString, false)) {
                writeDone = true;
                addLog("✅ 极清 HTML 文档已完美导入到微信草稿 (本地直接写入)！", "success");
                const editorEl = getActiveEditor();
                if (editorEl) {
                    const count = convertSliders(editorEl);
                    addLog(`🎉 全流程大功告成！滑动组件已自动排版渲染 (${count} 组)。`, "success");
                }
            }

            // 2. 广播 postMessage 给所有子 iframe 协同写入
            const iframes = Array.from(document.querySelectorAll('iframe'));
            if (iframes.length > 0) {
                iframes.forEach(iframe => {
                    try {
                        if (iframe.contentWindow) {
                            iframe.contentWindow.postMessage({
                                type: 'L2P_WRITE_EDITOR',
                                html: processedHtmlString
                            }, '*');
                        }
                    } catch (e) {}
                });
            }

            // 3. 如果本地没有成功写入，等待子 iframe 确认回执
            if (!writeDone) {
                addLog("主窗口找不到直接编辑器，已向子编辑 Iframe 广播协同写入，等待应答...", "info");
                await new Promise((resolve) => {
                    const successListener = (event) => {
                        if (event.data && event.data.type === 'L2P_WRITE_SUCCESS') {
                            writeDone = true;
                            addLog("✅ 极清 HTML 文档已完美导入到微信草稿 (子编辑器写入成功)！", "success");
                            addLog(`🎉 全流程大功告成！滑动组件已自动排版渲染 (${event.data.sliderCount} 组)。`, "success");
                            window.removeEventListener('message', successListener);
                            resolve();
                        }
                    };
                    window.addEventListener('message', successListener);
                    
                    // 5秒超时 fallback
                    setTimeout(() => {
                        if (!writeDone) {
                            addLog("⚠️ 协同写入超时，请确保微信公众号编辑器已完全处于聚焦或可编辑状态！", "warning");
                        }
                        window.removeEventListener('message', successListener);
                        resolve();
                    }, 5000);
                });
            }
        };

        if (uniqueUrls.length === 0) {
            addLog("未发现任何需要转存的外链图片，直接导入 HTML 正文...", "warning");
            await writeAndReconstruct(htmlInput);
            return;
        }

        const urlMappings = new Map();
        let successCount = 0;
        let failCount = 0;
        let processedCount = 0;

        // 构建并发上传任务队列
        const tasks = uniqueUrls.map((originalUrl, index) => {
            return async () => {
                const displayIndex = index + 1;
                addLog(`[${displayIndex}/${uniqueUrls.length}] 开始下载图片并转存微信...`, "info");
                
                try {
                    // 1. 下载图片为 Blob
                    const blob = await fetchImageBlob(originalUrl);
                    
                    // 2. 推算后缀名及文件名
                    let ext = 'png';
                    if (blob.type) {
                        if (blob.type.includes('jpeg') || blob.type.includes('jpg')) ext = 'jpg';
                        else if (blob.type.includes('gif')) ext = 'gif';
                        else if (blob.type.includes('webp')) ext = 'webp';
                    }
                    const filename = `l2p_wechat_upload_${Date.now()}_${displayIndex}.${ext}`;
                    
                    // 3. 上传到微信网页端私有接口
                    const wechatUrl = await uploadToWechat(blob, filename, blob.type || 'image/png', token);
                    
                    urlMappings.set(originalUrl, wechatUrl);
                    successCount++;
                    addLog(`[${displayIndex}/${uniqueUrls.length}] 转存微信图床成功！`, "success");
                } catch (err) {
                    failCount++;
                    addLog(`[${displayIndex}/${uniqueUrls.length}] ⚠️ 转存失败: ${err.message} (保留原图链接)`, "error");
                }
                
                processedCount++;
                setProgress(Math.round((processedCount / uniqueUrls.length) * 100));
            };
        });

        // 限制并发数为 5 进行并发上传，兼顾效率与防风控频率限制
        const concurrencyLimit = 5;
        const pool = [];
        for (const task of tasks) {
            const p = task();
            pool.push(p);
            const clean = () => {
                const idx = pool.indexOf(p);
                if (idx > -1) pool.splice(idx, 1);
            };
            p.then(clean, clean);
            
            if (pool.length >= concurrencyLimit) {
                await Promise.race(pool);
            }
        }
        await Promise.all(pool);

        addLog(`外链处理完成！成功: ${successCount} 张，失败: ${failCount} 张。正在重构文档结构...`, "info");
        
        // 4. 遍历节点做批量替换
        urlToNodeMap.forEach(item => {
            const newUrl = urlMappings.get(item.url);
            if (newUrl) {
                item.node.setAttribute('src', newUrl);
                item.node.setAttribute('data-src', newUrl);
            }
        });

        // 5. 将处理好的 HTML 广播并协同写入微信 ProseMirror 编辑器
        const processedHtml = doc.body.innerHTML;
        await writeAndReconstruct(processedHtml);
    }

    // 控制面板 UI 交互与构建
    let isUiCreated = false;
    let mainBtn = null;
    let panel = null;
    let menuView = null;
    let inputView = null;
    let progressView = null;
    let fileInput = null;
    let dropzone = null;
    let selectedFileContent = "";
    let progressText = null;
    let progressBar = null;
    let logBox = null;
    let startBtn = null;
    let doneBtn = null;

    function createPanelUI() {
        if (isUiCreated) return;
        
        // 创建浮空面板
        panel = document.createElement('div');
        panel.className = 'l2p-panel';
        panel.innerHTML = `
            <div class="l2p-header">
                <div class="l2p-title">LiquidConvert 微信助手</div>
                <div class="l2p-close" title="最小化">&times;</div>
            </div>
            <div class="l2p-body">
                <!-- 菜单视图 -->
                <div id="l2p-view-menu" style="display: block;">
                    <div class="l2p-card" id="l2p-action-slide">
                        <div class="l2p-card-icon">
                            <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                                <rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect>
                                <line x1="9" y1="3" x2="9" y2="21"></line>
                                <line x1="15" y1="3" x2="15" y2="21"></line>
                            </svg>
                        </div>
                        <div class="l2p-card-content">
                            <div class="l2p-card-title">一键滑动排版</div>
                            <div class="l2p-card-desc">自动扫描正文中带有提示词的平铺图片，快速拼装为左右或上下滑动组件。</div>
                        </div>
                        <div class="l2p-card-arrow">&rarr;</div>
                    </div>
                    
                    <div class="l2p-card" id="l2p-action-import">
                        <div class="l2p-card-icon">
                            <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                                <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path>
                                <polyline points="17 8 12 3 7 8"></polyline>
                                <line x1="12" y1="3" x2="12" y2="15"></line>
                            </svg>
                        </div>
                        <div class="l2p-card-content">
                            <div class="l2p-card-title">导入 Lark2Pad 草稿</div>
                            <div class="l2p-card-desc">选择或拖拽 HTML 文件，自动跨域下载外链原图并转存官方图床，微信排版无缝闭环。</div>
                        </div>
                        <div class="l2p-card-arrow">&rarr;</div>
                    </div>

                    <div class="l2p-card" id="l2p-action-diagnose" style="opacity: 0.7;">
                        <div class="l2p-card-icon">
                            <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                                <circle cx="12" cy="12" r="10"></circle>
                                <line x1="12" y1="8" x2="12" y2="12"></line>
                                <line x1="12" y1="16" x2="12.01" y2="16"></line>
                            </svg>
                        </div>
                        <div class="l2p-card-content">
                            <div class="l2p-card-title">🔍 诊断编辑器</div>
                            <div class="l2p-card-desc">检测并在控制台打印所有候选编辑器节点。导入空白时点这里查看调试信息。</div>
                        </div>
                        <div class="l2p-card-arrow">&rarr;</div>
                    </div>
                </div>
                
                <!-- HTML 文件输入视图 -->
                <div id="l2p-view-input" class="l2p-textarea-container">
                    <div style="font-size: 12px; color: rgba(255, 255, 255, 0.7); margin-bottom: 12px; line-height: 1.4;">
                        选择由 Lark2Pad 导出的本地极清 HTML 文件：
                    </div>
                    <div style="margin-bottom: 16px; position: relative;">
                        <input type="file" id="l2p-file-input" accept=".html,.htm" style="display: none;">
                        <div id="l2p-file-dropzone" style="border: 2px dashed rgba(255, 255, 255, 0.25); border-radius: 10px; padding: 32px 20px; text-align: center; cursor: pointer; transition: all 0.2s ease; background: rgba(255,255,255,0.02);">
                            <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="#07c160" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="margin: 0 auto 10px; display: block;">
                                <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path>
                                <polyline points="17 8 12 3 7 8"></polyline>
                                <line x1="12" y1="3" x2="12" y2="15"></line>
                            </svg>
                            <span style="font-size: 12px; color: rgba(255, 255, 255, 0.7); display: block;" id="l2p-file-name">点击选择或拖入 HTML 文件</span>
                        </div>
                    </div>
                    <div class="l2p-action-bar">
                        <button class="l2p-btn btn-secondary" id="l2p-btn-input-back">返回</button>
                        <button class="l2p-btn btn-primary btn-disabled" id="l2p-btn-input-submit" disabled>开始上传并导入</button>
                    </div>
                </div>
                
                <!-- 进度与日志视图 -->
                <div id="l2p-view-progress" class="l2p-progress-container">
                    <div class="l2p-progress-container">
                        <div class="l2p-progress-text">
                            <span id="l2p-progress-status">准备就绪</span>
                            <span id="l2p-progress-percent">0%</span>
                        </div>
                        <div class="l2p-progress-bg">
                            <div class="l2p-progress-bar"></div>
                        </div>
                    </div>
                    <div class="l2p-log"></div>
                    <div class="l2p-action-bar">
                        <button class="l2p-btn btn-primary btn-disabled" id="l2p-btn-progress-done" disabled>完成</button>
                    </div>
                </div>
            </div>
        `;
        document.body.appendChild(panel);

        // 获取面板元素句柄
        menuView = panel.querySelector('#l2p-view-menu');
        inputView = panel.querySelector('#l2p-view-input');
        progressView = panel.querySelector('#l2p-view-progress');
        fileInput = panel.querySelector('#l2p-file-input');
        dropzone = panel.querySelector('#l2p-file-dropzone');
        progressText = panel.querySelector('#l2p-progress-percent');
        progressBar = panel.querySelector('.l2p-progress-bar');
        logBox = panel.querySelector('.l2p-log');
        startBtn = panel.querySelector('#l2p-btn-input-submit');
        doneBtn = panel.querySelector('#l2p-btn-progress-done');

        // 关闭/最小化按钮事件
        panel.querySelector('.l2p-close').onclick = () => {
            panel.style.display = 'none';
        };

        // 一键滑动卡片点击事件
        panel.querySelector('#l2p-action-slide').onclick = () => {
            const ed = getActiveEditor(true);
            if (ed) {
                convertSliders(ed);
                panel.style.display = 'none';
            } else {
                showToast("未找到活动编辑器，请确保公众号编辑器已完全载入", false);
            }
        };

        // 导入草稿卡片点击事件
        panel.querySelector('#l2p-action-import').onclick = () => {
            menuView.style.display = 'none';
            inputView.style.display = 'flex';
            
            // 重置文件选择状态
            selectedFileContent = "";
            fileInput.value = "";
            const fileNameSpan = dropzone.querySelector('#l2p-file-name');
            fileNameSpan.innerText = "点击选择或拖入 HTML 文件";
            fileNameSpan.style.color = "rgba(255, 255, 255, 0.7)";
            dropzone.style.borderColor = "rgba(255, 255, 255, 0.25)";
            dropzone.style.background = "rgba(255, 255, 255, 0.02)";
            
            startBtn.disabled = true;
            startBtn.classList.add('btn-disabled');
        };

        // 诊断编辑器卡片点击事件
        panel.querySelector('#l2p-action-diagnose').onclick = () => {
            const ed = getActiveEditor(true); // true = isDiagnostic: 在控制台印全部候选节点
            if (ed) {
                const info = `小素id=${ed.id} class=${ed.className} 内容长度=${ed.innerText ? ed.innerText.length : 0}`;
                showToast(`✅ 找到编辑器: ${info}`, true);
                console.log('[WXLayout 诊断] 最佳匹配编辑器:', ed);
            } else {
                showToast('❌ 未找到任何编辑器节点！请确保平台编辑器已完全载入', false);
                console.log('[WXLayout 诊断] 未找到任何编辑器。DOM contenteditable 节点:',
                    document.querySelectorAll('[contenteditable]'));
                console.log('[WXLayout 诊断] 常见 iframe:', document.querySelectorAll('iframe'));
                const jsapi = window.__MP_Editor_JSAPI__ || (window.top && window.top.__MP_Editor_JSAPI__);
                console.log('[WXLayout 诊断] __MP_Editor_JSAPI__:', jsapi);
            }
        };

        // 处理所选文件并利用 FileReader 读取内容
        function handleFile(file) {
            if (!file) return;
            if (!file.name.endsWith('.html') && !file.name.endsWith('.htm')) {
                showToast("只支持导入 .html / .htm 格式文件", false);
                return;
            }

            const reader = new FileReader();
            reader.onload = function(e) {
                selectedFileContent = e.target.result;
                const fileNameSpan = dropzone.querySelector('#l2p-file-name');
                fileNameSpan.innerText = `已选: ${file.name}`;
                fileNameSpan.style.color = '#07c160';
                dropzone.style.borderColor = '#07c160';
                dropzone.style.background = 'rgba(7, 193, 96, 0.06)';
                
                // 启用提交按钮
                startBtn.disabled = false;
                startBtn.classList.remove('btn-disabled');
            };
            reader.readAsText(file, "UTF-8");
        }

        // 文件拖拽/点击事件绑定
        dropzone.onclick = () => fileInput.click();
        
        fileInput.onchange = (e) => {
            if (e.target.files && e.target.files.length > 0) {
                handleFile(e.target.files[0]);
            }
        };

        dropzone.ondragover = (e) => {
            e.preventDefault();
            dropzone.style.borderColor = '#07c160';
            dropzone.style.background = 'rgba(7, 193, 96, 0.1)';
        };

        dropzone.ondragleave = (e) => {
            e.preventDefault();
            if (selectedFileContent) {
                dropzone.style.borderColor = '#07c160';
                dropzone.style.background = 'rgba(7, 193, 96, 0.06)';
            } else {
                dropzone.style.borderColor = 'rgba(255, 255, 255, 0.25)';
                dropzone.style.background = 'rgba(255, 255, 255, 0.02)';
            }
        };

        dropzone.ondrop = (e) => {
            e.preventDefault();
            if (e.dataTransfer.files && e.dataTransfer.files.length > 0) {
                handleFile(e.dataTransfer.files[0]);
            }
        };

        // 输入视图 - 返回按钮
        panel.querySelector('#l2p-btn-input-back').onclick = () => {
            inputView.style.display = 'none';
            menuView.style.display = 'block';
        };

        // 输入视图 - 提交开始上传并导入
        startBtn.onclick = async () => {
            if (!selectedFileContent) {
                showToast("请先选择 HTML 文件", false);
                return;
            }
            
            const urlParams = new URLSearchParams(window.location.search);
            const token = urlParams.get('token');
            if (!token) {
                showToast("未在当前页面 URL 中找到 token，请刷新页面重试", false);
                return;
            }

            // 切换到进度视图
            inputView.style.display = 'none';
            progressView.style.display = 'flex';
            
            // 初始化日志和进度
            logBox.innerHTML = '';
            progressText.innerText = '0%';
            progressBar.style.width = '0%';
            panel.querySelector('#l2p-progress-status').innerText = '准备就绪';
            doneBtn.disabled = true;
            doneBtn.classList.add('btn-disabled');

            const addLog = (msg, type = "info") => {
                const item = document.createElement('div');
                item.className = `l2p-log-item log-${type}`;
                item.innerText = `[${new Date().toLocaleTimeString()}] ${msg}`;
                logBox.appendChild(item);
                logBox.scrollTop = logBox.scrollHeight;
            };

            const setProgress = (val) => {
                progressText.innerText = `${val}%`;
                progressBar.style.width = `${val}%`;
                panel.querySelector('#l2p-progress-status').innerText = `已处理 ${val}%`;
            };

            try {
                await startHtmlImport(selectedFileContent, token, addLog, setProgress);
            } catch (err) {
                addLog(`导入发生异常中断: ${err.message}`, "error");
            } finally {
                doneBtn.disabled = false;
                doneBtn.classList.remove('btn-disabled');
                addLog("任务结束。点击「完成」返回。", "info");
            }
        };

        // 进度视图 - 完成并返回主页
        doneBtn.onclick = () => {
            progressView.style.display = 'none';
            menuView.style.display = 'block';
        };

        isUiCreated = true;
    }

    // 自动寻找并注入悬浮主按钮
    let timerCount = 0;
    function injectUI() {
        timerCount++;
        
        let editorElement = null;
        try {
            editorElement = getActiveEditor(timerCount % 2 === 0);
        } catch (ex) {}

        // 只在主 window（非 iframe）渲染悬浮控制按钮即可，避免各子 Iframe 重复悬浮
        if (window.self !== window.top) return;

        // 避免重复注入按钮
        const existingBtn = document.getElementById('wxlayout-helper-btn');
        if (existingBtn) {
            if (!existingBtn.innerHTML.includes('v2.2.5')) {
                existingBtn.remove();
            } else {
                return;
            }
        }

        // 创建面板 UI 树
        createPanelUI();

        // 寻找微信后台编辑器顶部的操作栏
        const toolbars = [
            document.querySelector('.tool_area_wrp'),
            document.querySelector('.media_edit_area'),
            document.querySelector('#js_main'),
            document.body
        ];

        let toolbar = null;
        for (let t of toolbars) {
            if (t) { toolbar = t; break; }
        }

        if (toolbar) {
            mainBtn = document.createElement('button');
            mainBtn.id = 'wxlayout-helper-btn';
            mainBtn.type = 'button';
            mainBtn.style.position = 'fixed';
            mainBtn.style.bottom = '80px';
            mainBtn.style.right = '40px';
            mainBtn.style.width = '80px';
            mainBtn.style.height = '80px';
            mainBtn.style.borderRadius = '50%';
            mainBtn.style.backgroundColor = '#07c160';
            mainBtn.style.color = '#ffffff';
            mainBtn.style.border = 'none';
            mainBtn.style.boxShadow = '0 6px 16px rgba(0, 0, 0, 0.2)';
            mainBtn.style.cursor = 'pointer';
            mainBtn.style.zIndex = '999999';
            mainBtn.style.fontFamily = 'system-ui, -apple-system, sans-serif';
            mainBtn.style.fontSize = '11px';
            mainBtn.style.fontWeight = 'bold';
            mainBtn.style.display = 'flex';
            mainBtn.style.flexDirection = 'column';
            mainBtn.style.alignItems = 'center';
            mainBtn.style.justifyContent = 'center';
            mainBtn.style.transition = 'all 0.2s ease';
            
            mainBtn.innerHTML = `
                <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" style="margin-bottom:4px;">
                    <polyline points="15 3 21 3 21 9"></polyline>
                    <polyline points="9 21 3 21 3 15"></polyline>
                    <line x1="21" y1="3" x2="14" y2="10"></line>
                    <line x1="3" y1="21" x2="10" y2="14"></line>
                </svg>
                <span>微信助手 v2.2.5</span>
            `;

            mainBtn.addEventListener('mouseenter', () => {
                mainBtn.style.transform = 'scale(1.08)';
                mainBtn.style.backgroundColor = '#06ae56';
            });
            mainBtn.addEventListener('mouseleave', () => {
                mainBtn.style.transform = 'scale(1)';
                mainBtn.style.backgroundColor = '#07c160';
            });

            mainBtn.onclick = function() {
                if (panel) {
                    if (panel.style.display === 'none' || !panel.style.display) {
                        panel.style.display = 'block';
                        // 重置为菜单视图
                        menuView.style.display = 'block';
                        inputView.style.display = 'none';
                        progressView.style.display = 'none';
                    } else {
                        panel.style.display = 'none';
                    }
                }
            };

            document.body.appendChild(mainBtn);
            console.log("[WXLayout] WXLayout Helper 悬浮按钮 (v2.2.5) 已成功挂载！");
        }
    }

    // 启动轮询监视器（每 1.5s 检测一次，确保编辑器加载后能挂载）
    setInterval(injectUI, 1500);

})();
