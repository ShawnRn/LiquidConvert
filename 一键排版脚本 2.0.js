// ==UserScript==
// @name         微信公众号滑动组件一键排版工具 (WXLayout Helper)
// @namespace    https://ifanr.com/
// @version      2.0
// @description  在微信公众号后台编辑器中，一键将平铺导入的图片及提示词自动重构为左右滑动/上下滑动组件。支持微信官方图床链接，避免直贴时发生 CORS 图片载入失败或图片丢失。
// @author       Antigravity (Gemini Team)
// @match        https://mp.weixin.qq.com/*
// @icon         https://res.wx.qq.com/a/wx_fed/assets/res/NTI4MWU5.ico
// @grant        none
// @allFrames    true
// @run-at       document-end
// ==/UserScript==

(function() {
    'use strict';

    // 顶级初始化日志
    console.log(`[WXLayout] v2.0 脚本载入！当前 URL: ${window.location.href}, 是否在 Iframe 内: ${window.self !== window.top}`);

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
        toast.style.zIndex = '999999';
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

    // 跨 iframe 全方位检索微信正文编辑器容器 (金刚防爆版)
    function getActiveEditor(isDiagnostic = false) {
        const editors = [];

        // 1. 收集当前 window 内的所有 ProseMirror 实例
        try {
            document.querySelectorAll('.ProseMirror').forEach(ed => {
                if (ed) editors.push({ node: ed, source: 'Current Frame (ProseMirror)' });
            });
        } catch (e) {
            if (isDiagnostic) console.error("[WXLayout] 搜寻当前 Frame 的 ProseMirror 报错:", e);
        }

        // 2. 收集所有子 iframe 内的 ProseMirror 实例及 Body
        try {
            document.querySelectorAll('iframe').forEach(iframe => {
                try {
                    if (iframe && iframe.contentDocument) {
                        const subEds = iframe.contentDocument.querySelectorAll('.ProseMirror');
                        subEds.forEach(ed => {
                            if (ed) editors.push({ node: ed, source: `Sub-Iframe (${iframe.id || 'anonymous'}) (ProseMirror)` });
                        });

                        if (subEds.length === 0 && iframe.contentDocument.body) {
                            editors.push({ node: iframe.contentDocument.body, source: `Sub-Iframe (${iframe.id || 'anonymous'}) (Body)` });
                        }
                    }
                } catch (innerEx) {
                    // 安全忽略跨域沙盒限制
                }
            });
        } catch (e) {
            // 安全忽略 iframe 查询报错
        }

        if (editors.length === 0) {
            if (isDiagnostic) {
                console.warn("[WXLayout] 轮询诊断：当前页面及 iframe 内没有找到任何编辑器候选实例(ProseMirror/Body)。");
            }
            return null;
        }

        // 3. 智能权重打分筛选机制
        let activeEditor = null;
        let maxWeight = -99999;

        if (isDiagnostic) {
            console.log(`[WXLayout] 轮询诊断：发现 ${editors.length} 个候选编辑器，开始权重打分：`);
        }

        editors.forEach((item, index) => {
            const ed = item.node;
            if (!ed) return;

            try {
                let weight = 0;

                // A. 图片特征 (正文专属，每有一张图权重加100分)
                let imgCount = 0;
                try {
                    imgCount = ed.querySelectorAll('img').length;
                } catch (ex) {}
                weight += imgCount * 100;

                // B. 文本特征 (正文较长，每字权重加1分)
                let len = 0;
                try {
                    len = ed.innerText ? ed.innerText.length : 0;
                } catch (ex) {}
                weight += len;

                // C. 标题/摘要黑名单降权
                let className = "";
                let id = "";
                try {
                    className = ed.className || "";
                    id = ed.id || "";
                } catch (ex) {}

                if (/title|digest|desc/i.test(className) || /title|digest|desc/i.test(id)) {
                    weight -= 1000;
                }

                let placeholder = "";
                try {
                    placeholder = ed.getAttribute('placeholder') || ed.getAttribute('data-placeholder') || "";
                } catch (ex) {}

                if (/标题|摘要|选填/i.test(placeholder)) {
                    weight -= 1000;
                }

                let rect = { width: 0, height: 0 };
                try {
                    rect = ed.getBoundingClientRect() || { width: 0, height: 0 };
                } catch (ex) {}

                const width = rect.width || ed.offsetWidth || 0;
                const height = rect.height || ed.offsetHeight || 0;

                if (isDiagnostic) {
                    console.log(`  [候选 #${index+1}] 来源: ${item.source}, 尺寸: ${width}x${height}, 字数: ${len}, 图片数: ${imgCount}, Placeholder: "${placeholder}", 得分: ${weight}`);
                }

                if (weight > maxWeight) {
                    maxWeight = weight;
                    activeEditor = ed;
                }
            } catch (forEachEx) {
                if (isDiagnostic) {
                    console.error(`  [候选 #${index+1}] 评估发生异常已被安全跳过:`, forEachEx);
                }
            }
        });

        if (isDiagnostic && activeEditor) {
            console.log("[WXLayout] 锁定最终胜出正文编辑器：", activeEditor);
        }

        return activeEditor;
    }

    // 扫描并重构编辑器里的滑动组件
    function convertSliders(editorElement) {
        console.log("[WXLayout] ================== 开始扫描滑动段落 (v2.0) ==================");
        console.log("[WXLayout] 目标编辑器内容长度:", editorElement.innerText.length);
        console.log("[WXLayout] 目标编辑器 class:", editorElement.className);
        console.log("[WXLayout] 目标编辑器 innerText 前400字预览:\n", editorElement.innerText.substring(0, 400));
        let count = 0;

        // 检索该编辑器里所有可能的标签
        const paragraphs = Array.from(editorElement.querySelectorAll('p, section, div, h1, h2, h3, h4, h5, h6, span'));
        console.log("[WXLayout] 扫描到子段落总数:", paragraphs.length);

        // 详细输出包含任意“滑动”或“左右/向左/上下”字样的节点
        console.log("[WXLayout] -------- 开始诊断扫描包含'滑动/向左/左右/上下'的段落节点 --------");
        paragraphs.forEach((p, idx) => {
            const txt = p.innerText.trim();
            if (/滑动|向左|左右|上下/i.test(txt)) {
                console.log(`  [匹配词节点 #${idx}] Tag: <${p.tagName.toLowerCase()}>, class: "${p.className}", text: "${txt}"`);
                console.log(`  [匹配词节点 #${idx} HTML]:`, p.outerHTML);
            }
        });
        console.log("[WXLayout] ----------------------------------------------------");

        for (let i = 0; i < paragraphs.length; i++) {
            const p = paragraphs[i];
            const text = p.innerText.trim();

            // 模糊检索提示词
            const isLeftSwipe = /向左滑动查看|左右滑动查看/i.test(text);
            const isUpDownSwipe = /上下滑动查看/i.test(text);

            if (isLeftSwipe || isUpDownSwipe) {
                console.log(`[WXLayout] 成功锁定目标滑动提示节点: "${text}" (Tag: <${p.tagName.toLowerCase()}>)`);

                // 1. 收集滑动提示词上方的兄弟图片节点
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

                // 2. 收集提示词下方的指引小手 GIF 节点
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

                if (imagesToGroup.length === 0) {
                    console.warn(`[WXLayout 诊断] 提示词 "${text}" (Tag: <${p.tagName.toLowerCase()}>) 上方未找到有效图片。开始输出上方前 5 个兄弟节点以供排查：`);
                    let diagSibling = p.previousElementSibling;
                    let step = 1;
                    while (diagSibling && step <= 5) {
                        let innerTextPreview = diagSibling.innerText ? diagSibling.innerText.trim().substring(0, 60) : "";
                        console.warn(`  [上方兄弟 #${step}] Tag: <${diagSibling.tagName.toLowerCase()}>, class: "${diagSibling.className}", text: "${innerTextPreview}", innerHTML(首200字): "${diagSibling.innerHTML.substring(0, 200)}"`);
                        diagSibling = diagSibling.previousElementSibling;
                        step++;
                    }
                    if (!p.previousElementSibling) {
                        console.warn("  [上方兄弟] 无！该提示词节点已经是其父容器的第一个子节点。其父节点为:", p.parentNode ? p.parentNode.tagName : "无");
                    }
                    continue;
                }

                console.log(`[WXLayout] 组装滑动图集：图片数量 = ${imagesToGroup.length}`);

                // 3. 构建新的滑动结构 HTML
                let newHtml = "";
                if (isLeftSwipe) {
                    const N = imagesToGroup.length;
                    const containerWidthPercent = N * 100;
                    const itemWidthPercent = (100 / N).toFixed(3);

                    let itemsHtml = "";
                    imagesToGroup.forEach(img => {
                        itemsHtml += `
                        <section style="display: inline-block; width: ${itemWidthPercent}%; min-width: ${itemWidthPercent}%; max-width: ${itemWidthPercent}%; box-sizing: border-box; vertical-align: top;">
                            <img src="${img.src}" style="min-width: 100%; max-width: 100%; padding-right: 5px; box-sizing: border-box; display: block;">
                        </section>
                        `.trim().replace(/\n/g, "");
                    });

                    newHtml = `
                    <section style="font-family: system-ui, -apple-system, sans-serif; margin: 20px 0;">
                        <section style="margin-bottom: 24px; font-size: 0px; line-height: 0;">
                            <section class="overflow-scrolling" style="min-width: 100%; max-width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch; display: block;">
                                <section style="min-width: ${containerWidthPercent}%; max-width: ${containerWidthPercent}%; display: block; font-size: 0; line-height: 0;">
                                    ${itemsHtml}
                                </section>
                            </section>
                            <section style="margin: 8px 0px; font-size: 12px; line-height: 17px; color: rgb(167, 167, 167); display: block;">向左滑动查看更多内容</section>
                            <img src="https://wxlayout.ifanrusercontent.com/yd2qr5ofbspk7y3smytx3514yidjgoc2.gif" style="width: 42px; height: auto; max-height: 10px; display: block; margin-top: 4px;">
                        </section>
                    </section>
                    `.trim();
                } else if (isUpDownSwipe) {
                    const targetImg = imagesToGroup[0];
                    newHtml = `
                    <section style="font-family: system-ui, -apple-system, sans-serif; margin: 20px 0;">
                        <section style="width: 100%; height: 320px; overflow: hidden; border: 1px solid #eeeeee; box-sizing: border-box; display: block;">
                            <section style="display: flex; flex-direction: column; height: 100%; overflow-y: auto; box-sizing: border-box; display: block;">
                                <img src="${targetImg.src}" style="display: block; width: 100%; height: auto;">
                            </section>
                        </section>
                        <section style="margin: 8px 0px; font-size: 12px; line-height: 17px; color: rgb(167, 167, 167); text-align: center; display: block;">上下滑动查看更多内容</section>
                    </section>
                    `.trim();
                }

                // 4. 将旧节点全部移除，插入新滑动组件节点
                const wrapper = document.createElement('section');
                wrapper.innerHTML = newHtml;

                const insertBeforeNode = imagesToGroup[0].node;
                insertBeforeNode.parentNode.insertBefore(wrapper, insertBeforeNode);

                imagesToGroup.forEach(img => img.node.remove());
                emptyNodesToRemove.forEach(node => node.remove());
                p.remove();
                if (fingerGifNode) {
                    fingerGifNode.remove();
                }

                count++;
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

            showToast(`成功一键排版 ${count} 个滑动图集！`, true);
        } else {
            console.error("[WXLayout 诊断] 转换失败！未在正文里搜寻到有效的滑动平铺图片匹配。");
            console.error("[WXLayout 诊断] 当前正文的完整 innerHTML 内容如下：\n", editorElement.innerHTML);
            showToast("未检测到未处理的平铺滑动段落（诊断详情请看 F12 控制台）", false);
        }
    }

    // 自动寻找并注入操作按钮
    let timerCount = 0;
    function injectUI() {
        timerCount++;
        // 每 3 秒（轮询 2 次）进行一次控制台诊断打印
        const isDiagnostic = (timerCount % 2 === 0);

        let editorElement = null;
        try {
            editorElement = getActiveEditor(isDiagnostic);
        } catch (ex) {
            if (isDiagnostic) {
                console.error("[WXLayout] 轮询执行 getActiveEditor 抛出未捕获异常:", ex);
            }
        }

        if (!editorElement) {
            if (isDiagnostic) {
                console.warn("[WXLayout] 轮询诊断：当前暂未成功锁定正文编辑器。将继续尝试...");
            }
            return;
        }

        // 避免重复注入按钮
        const existingBtn = document.getElementById('wxlayout-helper-btn');
        if (existingBtn) {
            if (!existingBtn.innerHTML.includes('v2.0')) {
                existingBtn.remove();
            } else {
                return;
            }
        }

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
            const btn = document.createElement('button');
            btn.id = 'wxlayout-helper-btn';
            btn.type = 'button';
            btn.style.position = 'fixed';
            btn.style.bottom = '80px';
            btn.style.right = '40px';
            btn.style.width = '80px';
            btn.style.height = '80px';
            btn.style.borderRadius = '50%';
            btn.style.backgroundColor = '#07c160';
            btn.style.color = '#ffffff';
            btn.style.border = 'none';
            btn.style.boxShadow = '0 6px 16px rgba(0, 0, 0, 0.2)';
            btn.style.cursor = 'pointer';
            btn.style.zIndex = '99999';
            btn.style.fontFamily = 'system-ui, -apple-system, sans-serif';
            btn.style.fontSize = '11px';
            btn.style.fontWeight = 'bold';
            btn.style.display = 'flex';
            btn.style.flexDirection = 'column';
            btn.style.alignItems = 'center';
            btn.style.justifyContent = 'center';
            btn.style.transition = 'all 0.2s ease';

            btn.innerHTML = `
                <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" style="margin-bottom:4px;">
                    <polyline points="15 3 21 3 21 9"></polyline>
                    <polyline points="9 21 3 21 3 15"></polyline>
                    <line x1="21" y1="3" x2="14" y2="10"></line>
                    <line x1="3" y1="21" x2="10" y2="14"></line>
                </svg>
                <span>一键滑动 v2.0</span>
            `;

            btn.addEventListener('mouseenter', () => {
                btn.style.transform = 'scale(1.08)';
                btn.style.backgroundColor = '#06ae56';
            });
            btn.addEventListener('mouseleave', () => {
                btn.style.transform = 'scale(1)';
                btn.style.backgroundColor = '#07c160';
            });

            btn.onclick = function() {
                let currentEditor = null;
                try {
                    currentEditor = getActiveEditor(true);
                } catch (ex) {
                    console.error("[WXLayout] 点击执行 getActiveEditor 报错:", ex);
                }

                if (currentEditor) {
                    try {
                        convertSliders(currentEditor);
                    } catch (ex) {
                        console.error("[WXLayout] 执行 convertSliders 发生严重崩溃:", ex);
                    }
                } else {
                    showToast("未找到活动编辑器，请确保公众号编辑器已完全载入", false);
                }
            };

            document.body.appendChild(btn);
            console.log("[WXLayout] WXLayout Helper 悬浮按钮 (v1.9) 已成功挂载！");
        }
    }

    // 启动轮询监视器
    setInterval(injectUI, 1500);

})();