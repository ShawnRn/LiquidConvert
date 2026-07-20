---
name: lark2pad-cms-sync
description: 记录了将飞书文档转换并同步给 Pad 后，如何利用 Node 后端 send2cms 插件进行微信公众号、APPSO、WordPress 一键发布的技术方案和接口细节。
---

# Lark2Pad CMS 同步分发引擎

本 Skill 沉淀了 Lark2Pad 在同步和分发文章到多平台（包含微信公众号、APPSO、董车会、WordPress 等）时的技术架构和 API 规范。

## 1. 闭环发布流程

由于微信公众号的防盗链规则，直接通过客户端剪贴板直贴含有 `s3.ifanr.com` 的 HTML 图文，在微信后台会由于跨域和拦截而发生 **403 图片下载错误**。
正确的闭环工作流应基于 **"App 同步至 Pad -> 自动 POST 触发 Pad 后端 CMS 发送接口 -> 微信官方图床重绘与草稿箱建立"**。

## 2. 发布通道 API 映射表

POST 请求 URL：`${etherpadBaseURL}/p/${encodedPadID}/send2cms/${channel}`

| 平台及分发通道 | Channel Name (API 路由参数) |
| :--- | :--- |
| **ifanr 推文** | `ifanr` |
| **ifanr 早报** | `ifanr-morning-paper` |
| **APPSO 推文** | `appso` |
| **APPSO 早报** | `appso-morning-paper` |
| **董车会推文** | `intelligentcar` |
| **董车会日报** | `intelligentcar-morning-paper` |
| **知晓云** | `minapp` |
| **WordPress** | `wordpress` |

## 3. 滑动组件技术规范

### 3.1 核心原理
微信公众号的左右/上下滑动组件**不使用 SVG**，而是纯 CSS `overflow` 滚动实现。

### 3.2 左右滑动模板（参考 `/Users/shawnrain/Desktop/参考/向左滑动图片.html`）
```html
<section style="font-family: system-ui, -apple-system, ...;">
  <section style="margin-bottom: 32px; font-size: 0px;">
    <section class="overflow-scrolling" style="min-width: 100%; max-width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch;">
      <section style="min-width: 400%; max-width: 400%;">
        <section style="display: inline-block; width: 25%; min-width: 25%; max-width: 25%;">
          <img src="..." style="min-width: 100%; max-width: 100%; padding-right: 5px;">
        </section>
        <!-- 更多图片... -->
      </section>
    </section>
    <section style="margin: 6px 0px; font-size: 12px; line-height: 17px; color: rgb(167, 167, 167);">向左滑动查看更多内容</section>
    <img src="https://wxlayout.ifanrusercontent.com/yd2qr5ofbspk7y3smytx3514yidjgoc2.gif" style="width: 42px; max-height: 10px;">
  </section>
</section>
```

### 3.3 上下滑动模板（参考 `/Users/shawnrain/Desktop/参考/上下滑动.html`）
```html
<section style="font-family: system-ui, -apple-system, ...;">
  <section style="width: 100%; height: 300px; overflow: hidden;">
    <section style="display: flex; flex-direction: column; height: 100%; overflow-y: auto;">
      <img src="..." style="display: block; width: 100%;">
    </section>
  </section>
  <section style="margin: 6px 0px; font-size: 12px; line-height: 17px; color: rgb(167, 167, 167); text-align: center;">上下滑动查看更多内容</section>
</section>
```

### 3.4 关键约束

- **必须在 Raw HTML 导出中也使用完整的滑动 HTML 结构**。之前使用的"平铺 `<img>` + `<br>`"格式在 Pad 的 HTML→Atext→HTML 往返中会被解构为独立的 section block，**完全丢失滑动容器结构**。
- **严禁**在滑动组件的 `<img>` 上附带 `name`、`border-radius` 等非标准属性，因为参考模板中不包含这些属性。
- **严禁**使用 `data-type="slider-container"` 等自定义属性，Pad 后端不识别。
- 图片链接必须为微信图床或 `wxlayout.ifanrusercontent.com` 的正式链接。
- 所有样式必须使用行内 `style="..."`，不能使用 `id` 或 `class`（微信编辑器会过滤）。
