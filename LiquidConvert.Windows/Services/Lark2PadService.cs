using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace LiquidConvert.Windows.Services;

/// <summary>Converts clipboard or Markdown content to the two formats used by Lark2Pad.</summary>
public sealed partial class Lark2PadService
{
    public const string RootUrl = "https://pad.corp.ifanr.com/";
    private const string ImageUploadPadId = "lark2pad_upload";
    private const long UploadLimitBytes = 4_800_000;
    private static readonly HttpClient ImageHttpClient = CreateImageHttpClient();
    private const string CookieKey = "lark2pad.cookies";
    private const string PadIdsKey = "lark2pad.synced-pad-ids";

    public bool HasSession => LoadCookies().Count > 0;

    public void ClearSession() => SettingsStore.Remove(CookieKey);

    public async Task<string> ReadClipboardMarkdownAsync()
    {
        var view = Clipboard.GetContent();
        if (view.Contains(StandardDataFormats.Html))
        {
            var html = await view.GetHtmlFormatAsync();
            return HtmlToMarkdown(ExtractHtmlFragment(html));
        }

        if (view.Contains(StandardDataFormats.Text))
        {
            var text = await view.GetTextAsync();
            if (!string.IsNullOrWhiteSpace(text)) return NormalizeMarkdown(text);
        }

        throw new InvalidOperationException("剪贴板中没有可用内容。请在飞书文档中全选并复制后重试。");
    }

    public async Task<string> ImportMarkdownAsync(StorageFile input) =>
        NormalizeMarkdown(await FileIO.ReadTextAsync(input));

    /// <summary>
    /// Mirrors the macOS Lark2Pad pipeline: normalize Markdown, upload referenced
    /// images to the Etherpad image host, then turn image Markdown into safe img tags.
    /// </summary>
    public async Task<string> ConvertMarkdownAsync(string markdown, string? baseDirectory, Action<string>? reportProgress = null)
    {
        var normalized = StripMarkdownEscapes(NormalizeMarkdown(markdown));
        var matches = MarkdownImageRegex().Matches(normalized).Cast<Match>().ToList();
        if (matches.Count == 0) return ConvertMarkdownImagesToHtml(normalized);

        var sources = matches.Select(match => match.Groups["url"].Value.Trim())
            .Where(source => source.Length > 0 && !source.StartsWith("data:image/", StringComparison.OrdinalIgnoreCase))
            .Distinct(StringComparer.Ordinal)
            .ToList();
        LarkDiagnosticLog.Write($"Batch started: {sources.Count} distinct images, parallelism=5.");
        var replacements = await UploadImagesAsync(sources, baseDirectory, reportProgress);

        foreach (var replacement in replacements)
            normalized = normalized.Replace($"]({replacement.Key})", $"]({replacement.Value})", StringComparison.Ordinal);
        return ConvertMarkdownImagesToHtml(normalized);
    }

    private async Task<Dictionary<string, string>> UploadImagesAsync(IReadOnlyList<string> sources, string? baseDirectory, Action<string>? reportProgress)
    {
        var replacements = new Dictionary<string, string>(StringComparer.Ordinal);
        if (sources.Count == 0) return replacements;
        using var gate = new SemaphoreSlim(Math.Min(5, sources.Count));
        var completed = 0;
        await Task.WhenAll(sources.Select(async (source, position) =>
        {
            await gate.WaitAsync();
            try
            {
                LarkDiagnosticLog.Write($"Image {position + 1}/{sources.Count} entered upload slot.");
                reportProgress?.Invoke($"正在处理图片 {position + 1}/{sources.Count}（最多 5 张并行）…");
                var uploaded = await UploadImageWithRetryAsync(source, baseDirectory);
                lock (replacements) replacements[source] = uploaded;
                LarkDiagnosticLog.Write($"Image {position + 1}/{sources.Count} uploaded successfully.");
                var current = Interlocked.Increment(ref completed);
                reportProgress?.Invoke($"图片已处理 {current}/{sources.Count}（最多 5 张并行）…");
            }
            catch (Exception ex)
            {
                LarkDiagnosticLog.Write($"Image {position + 1}/{sources.Count} failed: {ex.GetType().Name}: {ex.Message}");
                throw;
            }
            finally { gate.Release(); }
        }));
        return replacements;
    }

    private async Task<string> UploadImageWithRetryAsync(string source, string? baseDirectory)
    {
        Exception? lastError = null;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                LarkDiagnosticLog.Write($"Image upload attempt {attempt + 1}/3 started.");
                return await UploadImageAsync(source, baseDirectory);
            }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
            {
                lastError = ex;
                LarkDiagnosticLog.Write($"Image upload attempt {attempt + 1}/3 transient failure: {ex.GetType().Name}: {ex.Message}");
                if (attempt < 2) await Task.Delay(TimeSpan.FromSeconds(attempt + 1));
            }
        }
        throw new InvalidOperationException($"图片上传超时，已重试 3 次：{lastError?.Message}", lastError);
    }

    public async Task ExportEtherpadHtmlAsync(string markdown, StorageFolder folder)
    {
        var output = await folder.CreateFileAsync(DefaultFilename(), CreationCollisionOption.GenerateUniqueName);
        await FileIO.WriteTextAsync(output, BuildEtherpadHtml(markdown));
    }

    public void CopyMarkdown(string markdown)
    {
        var package = new DataPackage();
        package.SetText(markdown);
        Clipboard.SetContent(package);
    }

    public void CopyEtherpadHtml(string markdown) => CopyHtml(BuildEtherpadHtml(markdown));

    public void CopyWeChatHtml(string markdown)
    {
        var package = new DataPackage();
        package.SetHtmlFormat(BuildWeChatHtml(markdown));
        package.SetText(markdown);
        Clipboard.SetContent(package);
    }

    public async Task SaveCookiesAsync(IEnumerable<CookieRecord> cookies)
    {
        var records = cookies.Where(cookie => !string.IsNullOrWhiteSpace(cookie.Name) && !string.IsNullOrWhiteSpace(cookie.Value)).ToList();
        SettingsStore.Set(CookieKey, JsonSerializer.Serialize(records));
        await Task.CompletedTask;
    }

    public async Task<Uri> SyncToPadAsync(string markdown)
    {
        var cookies = LoadCookies();
        if (cookies.Count == 0) throw new InvalidOperationException("请先登录公司 Etherpad 并保存会话。");

        var basePadId = SuggestedPadId(markdown);
        var padId = NextAvailablePadId(basePadId);
        var padUrl = new Uri($"{RootUrl}p/{Uri.EscapeDataString(padId)}");
        var importUrl = new Uri($"{padUrl}/import");
        var boundary = "----LiquidConvertPadBoundary" + Guid.NewGuid().ToString("N")[..12];
        var body = BuildPadImportBody(BuildEtherpadHtml(markdown), padId + ".html", boundary);
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        using var request = new HttpRequestMessage(HttpMethod.Post, importUrl);
        request.Headers.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36");
        request.Headers.TryAddWithoutValidation("Origin", RootUrl.TrimEnd('/'));
        request.Headers.Referrer = padUrl;
        request.Headers.TryAddWithoutValidation("X-Requested-With", "XMLHttpRequest");
        request.Headers.TryAddWithoutValidation("Cookie", string.Join("; ", cookies.Select(cookie => $"{cookie.Name}={cookie.Value}")));
        request.Content = new ByteArrayContent(body);
        request.Content.Headers.ContentType = System.Net.Http.Headers.MediaTypeHeaderValue.Parse($"multipart/form-data; boundary={boundary}");
        var response = await client.SendAsync(request);
        var responseText = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Etherpad 同步失败（HTTP {(int)response.StatusCode}）：{responseText}");
        if (responseText.Contains("\"code\":", StringComparison.Ordinal) && !responseText.Contains("\"code\":0", StringComparison.Ordinal))
            throw new InvalidOperationException($"Etherpad 未接受导入：{responseText}");

        RecordPadId(padId);
        return padUrl;
    }

    private static byte[] BuildPadImportBody(string html, string filename, string boundary)
    {
        var payload = new StringBuilder();
        payload.Append("--").Append(boundary).Append("\r\n");
        payload.Append("Content-Disposition: form-data; name=\"file\"; filename=\"").Append(SanitizeFileName(filename)).Append("\"\r\n");
        payload.Append("Content-Type: text/html; charset=utf-8\r\n\r\n");
        payload.Append(html).Append("\r\n--").Append(boundary).Append("--\r\n");
        return Encoding.UTF8.GetBytes(payload.ToString());
    }

    public static string BuildEtherpadHtml(string markdown)
    {
        var rawLines = NormalizeMarkdown(markdown).Split('\n');
        var resultLines = new List<string>();
        int i = 0;
        const string captionStyle = "display: inline-block; width: 100%; font-family: PingFangSC-Regular; font-weight: 400; font-size: 12px; color: rgb(167, 167, 167); letter-spacing: 0px; text-align: center;";

        while (i < rawLines.Length)
        {
            var line = rawLines[i];
            var trimmed = line.Trim();

            if (IsSafeImageTag(trimmed))
            {
                resultLines.Add(trimmed);
                int nextIdx = i + 1;
                while (nextIdx < rawLines.Length && string.IsNullOrEmpty(rawLines[nextIdx].Trim()))
                {
                    nextIdx++;
                }

                if (nextIdx < rawLines.Length)
                {
                    var nextTrimmed = rawLines[nextIdx].Trim();
                    if (IsCaptionText(nextTrimmed))
                    {
                        var caption = NormalizeCaptionText(nextTrimmed);
                        resultLines.Add($"<span class=\"image-caption\" style=\"{captionStyle}\">{WebUtility.HtmlEncode(caption)}</span>");
                        i = nextIdx + 1;
                        continue;
                    }
                }
                i++;
                continue;
            }

            if (IsCaptionText(trimmed))
            {
                var caption = NormalizeCaptionText(trimmed);
                resultLines.Add($"<span class=\"image-caption\" style=\"{captionStyle}\">{WebUtility.HtmlEncode(caption)}</span>");
                i++;
                continue;
            }

            resultLines.Add(WebUtility.HtmlEncode(line));
            i++;
        }

        var body = string.Join("<br>\n", resultLines);
        return WrapHtml(body, "Lark2Pad Export", EtherpadStyle);
    }

    public static string BuildRenderedHtml(string markdown, bool darkPreview = false)
    {
        var builder = new StringBuilder();
        var inList = false;
        foreach (var line in NormalizeMarkdown(markdown).Split('\n'))
        {
            var trimmed = line.Trim();
            if (string.IsNullOrEmpty(trimmed))
            {
                if (inList) { builder.AppendLine("</ul>"); inList = false; }
                builder.AppendLine("<p><br></p>");
            }
            else if (Regex.Match(trimmed, "^(#{1,6})\\s+(.+)$") is { Success: true } heading)
            {
                if (inList) { builder.AppendLine("</ul>"); inList = false; }
                var level = heading.Groups[1].Value.Length;
                builder.AppendLine($"<h{level}>{InlineHtml(heading.Groups[2].Value)}</h{level}>");
            }
            else if (trimmed.StartsWith("- ") || trimmed.StartsWith("* "))
            {
                if (!inList) { builder.AppendLine("<ul>"); inList = true; }
                builder.AppendLine($"<li>{InlineHtml(trimmed[2..])}</li>");
            }
            else if (trimmed.StartsWith("> "))
            {
                if (inList) { builder.AppendLine("</ul>"); inList = false; }
                builder.AppendLine($"<blockquote>{InlineHtml(trimmed[2..])}</blockquote>");
            }
            else
            {
                if (inList) { builder.AppendLine("</ul>"); inList = false; }
                builder.AppendLine($"<p>{InlineHtml(line)}</p>");
            }
        }
        if (inList) builder.AppendLine("</ul>");
        var previewTheme = darkPreview
            ? "html, body { background: #202020; color: #f3f3f3; } a { color: #7db7ff; } blockquote { border-left: 3px solid #6ea8fe; color: #c8c8c8; }"
            : "html, body { background: #ffffff; color: #202020; } a { color: #0f6cbd; } blockquote { border-left: 3px solid #0f6cbd; color: #4a4a4a; }";
        return WrapHtml(LazyLoadPreviewImages(builder.ToString()) + PreviewLazyLoadScript, "Lark2Pad Export", EtherpadStyle + "\n" + previewTheme);
    }

    private const string DefaultHeaderBannerURL = "https://s3.ifanr.com/images/ep/uploads/lark2pad_upload/4eab7d0a-39f1-41ae-b014-ae2163db4c4c.png";

    private const string WeChatFooterBannerHtml = """
    <p style="white-space: normal;margin: 0px;padding: 0px;box-sizing: border-box;"><span leaf=""></span></p>
    <section style="text-align: center;line-height: 0;box-sizing: border-box;"><section style="max-width: 100%;vertical-align: middle;display: inline-block;line-height: 0;box-sizing: border-box;" nodeleaf=""><img src="https://mmbiz.qpic.cn/sz_mmbiz_png/fc90sFPPBCO5sTlJseFUfia8Hu5P9EWwc4YHFvbFXrYWWDVxISzy2Vl3HGU4ibnqLPR6U8BgFRGxhS86OwDH6OCMnIDr4UnyEhYy6dTib2qiaBA/640?wx_fmt=png" data-src="https://mmbiz.qpic.cn/sz_mmbiz_png/fc90sFPPBCO5sTlJseFUfia8Hu5P9EWwc4YHFvbFXrYWWDVxISzy2Vl3HGU4ibnqLPR6U8BgFRGxhS86OwDH6OCMnIDr4UnyEhYy6dTib2qiaBA/640?wx_fmt=png" class="rich_pages wxw-img" data-ratio="0.05804" data-s="300,640" data-w="1051" data-type="png" style="vertical-align:middle;max-width:100%;width:100%;box-sizing:border-box;" width="100%"></section></section>
    <p style="white-space: normal;margin: 0px;padding: 0px;box-sizing: border-box;"><span leaf=""></span></p>
    <p style="white-space: normal;margin: 0px;padding: 0px;box-sizing: border-box;"><span leaf=""></span></p>
    <section style="text-align: left;justify-content: flex-start;display: flex;flex-flow: row;box-sizing: border-box;"><section style="display: inline-block;width: 100%;vertical-align: top;align-self: flex-start;flex: 0 0 auto;background-repeat: repeat;background-attachment: scroll;border-radius: 10px;overflow: hidden;background-image: url(&quot;https://mmbiz.qpic.cn/mmbiz_png/fc90sFPPBCMRTjiay36FKj1KwiaibBpEPbK583nGuBnJjNNeR13rq3IA6sia1fzibcJKicGLZcIfTOVU00ATFq7mmDMSKd18TqTmZzT7EmGykuQbk/640?wx_fmt=png&quot;);box-sizing: border-box;background-position: 0% 0% !important;background-size: auto !important;"><section style="justify-content: flex-start;display: flex;flex-flow: row;margin: 50px 0px 0px;box-sizing: border-box;"><section style="display: inline-block;width: 100%;vertical-align: top;align-self: flex-start;flex: 0 0 auto;box-sizing: border-box;"><section style="text-align: center;line-height: 0;box-sizing: border-box;"><section style="max-width: 100%;vertical-align: middle;display: inline-block;line-height: 0;box-sizing: border-box;" nodeleaf=""><img src="https://mmbiz.qpic.cn/sz_mmbiz_png/fc90sFPPBCP8MG80wljJC4cT2s8YibQ2t5hoaVEAoIZ8ftGmllAI5ehMD28ExTwBdfsibfyOqZBmTyjhrdXklbqcCa3CeMiaAXdeyzjKY11lIE/640?wx_fmt=png" data-src="https://mmbiz.qpic.cn/sz_mmbiz_png/fc90sFPPBCP8MG80wljJC4cT2s8YibQ2t5hoaVEAoIZ8ftGmllAI5ehMD28ExTwBdfsibfyOqZBmTyjhrdXklbqcCa3CeMiaAXdeyzjKY11lIE/640?wx_fmt=png" class="rich_pages wxw-img" data-ratio="0.6003805899143673" data-s="300,640" data-w="1051" data-type="png" style="vertical-align: middle;max-width: 100%;width: 100%;box-sizing: border-box;"></section></section></section></section><section style="justify-content: flex-start;display: flex;flex-flow: row;box-sizing: border-box;"><section style="display: inline-block;width: 100%;vertical-align: top;align-self: flex-start;flex: 0 0 auto;box-sizing: border-box;"><section style="text-align: center;line-height: 0;box-sizing: border-box;"><section style="max-width: 100%;vertical-align: middle;display: inline-block;line-height: 0;box-sizing: border-box;"><a href="https://mp.weixin.qq.com/s?__biz=MjgzMTAwODI0MA==&amp;mid=2652396877&amp;idx=2&amp;sn=dfef25453a6bf0dca147b0adca3deaf7&amp;scene=21#wechat_redirect" target="_blank"><span style="width:100%" class="js_jump_icon h5_image_link"><img src="https://mmbiz.qpic.cn/sz_mmbiz_png/fc90sFPPBCPyDFWbJT8y9ibibmFbtvMJbwHxCAZQskte81K91q7QwkwXPevnDR7bvHUD9ntPN43bDibM6svwxrCkBaVruzvjKVBLnTwJYk5pOk/640?wx_fmt=png" data-src="https://mmbiz.qpic.cn/sz_mmbiz_png/fc90sFPPBCPyDFWbJT8y9ibibmFbtvMJbwHxCAZQskte81K91q7QwkwXPevnDR7bvHUD9ntPN43bDibM6svwxrCkBaVruzvjKVBLnTwJYk5pOk/640?wx_fmt=png" class="rich_pages wxw-img" data-ratio="0.14367269267364416" data-s="300,640" data-w="1051" data-type="png" style="vertical-align: middle;max-width: 100%;width: 100%;box-sizing: border-box;"></span></a></section></section><section style="text-align: justify;box-sizing: border-box;"><p style="white-space: normal;margin: 0px;padding: 0px;box-sizing: border-box;"></p></section></section></section></section></section>
    <p style="white-space: normal;margin: 0px;padding: 0px;box-sizing: border-box;"><span leaf=""></span></p>
    <section style="text-align: center;line-height: 0;box-sizing: border-box;margin-top: 16px;"><section style="max-width: 100%;vertical-align: middle;display: inline-block;line-height: 0;border-radius: 10px;overflow: hidden;box-sizing: border-box;" nodeleaf=""><img src="https://mmbiz.qpic.cn/mmbiz_png/fc90sFPPBCNnChuCqY5TK78KORbHN3ficOaIgpjRfNqQWMJqRxxNGpMb2Om3ebIfpJGIs7nfu2WrCYzYjLkH6qicYms1ibfJbFujmoNFYaavpw/640?wx_fmt=png" data-src="https://mmbiz.qpic.cn/mmbiz_png/fc90sFPPBCNnChuCqY5TK78KORbHN3ficOaIgpjRfNqQWMJqRxxNGpMb2Om3ebIfpJGIs7nfu2WrCYzYjLkH6qicYms1ibfJbFujmoNFYaavpw/640?wx_fmt=png" class="rich_pages wxw-img" data-ratio="1.3333333333333333" data-s="300,640" data-w="1080" data-type="png" style="vertical-align: middle;max-width: 100%;width: 100%;box-sizing: border-box;"></section></section>
    """;

    private static bool IsArticleMetaLine(string text)
    {
        var trimmed = text.Trim();
        string[] prefixes = ["作者", "编辑", "声明", "题图", "插图", "封面", "策划", "排版", "免责声明", "文"];
        foreach (var p in prefixes)
        {
            if (trimmed.StartsWith($"{p}｜") || trimmed.StartsWith($"{p}|") || trimmed.StartsWith($"{p}：") || trimmed.StartsWith($"{p}:"))
                return true;
        }
        return false;
    }

    private static bool HasNextArticleMetaLine(int index, string[] lines)
    {
        int nextIdx = index + 1;
        while (nextIdx < lines.Length)
        {
            var candidate = lines[nextIdx].Trim();
            if (string.IsNullOrEmpty(candidate))
            {
                nextIdx++;
                continue;
            }
            return IsArticleMetaLine(candidate);
        }
        return false;
    }

    private static bool IsCaptionText(string text)
    {
        var trimmed = text.Trim();
        if (!trimmed.StartsWith("图")) return false;
        var afterTu = trimmed[1..].Trim();
        if (afterTu.Length == 0) return false;
        var c = afterTu[0];
        return c == '｜' || c == '|' || c == '：' || c == ':';
    }

    private static string NormalizeCaptionText(string text)
    {
        var trimmed = text.Trim();
        if (!IsCaptionText(trimmed)) return text;
        var afterTu = trimmed[1..].Trim();
        var content = afterTu[1..].Trim();
        return $"图｜{content}";
    }

    private static bool HasNextCaptionLine(int index, string[] lines)
    {
        int nextIdx = index + 1;
        while (nextIdx < lines.Length)
        {
            var candidate = lines[nextIdx].Trim();
            if (string.IsNullOrEmpty(candidate))
            {
                nextIdx++;
                continue;
            }
            return IsCaptionText(candidate);
        }
        return false;
    }

    private static string? ExtractImageUrl(string line)
    {
        var trimmed = line.Trim();
        var mdMatch = Regex.Match(trimmed, @"^!\[(?<alt>[^\]]*)\]\((?<url>[^)]+)\)$");
        if (mdMatch.Success) return mdMatch.Groups["url"].Value;
        if (trimmed.Contains("<img", StringComparison.OrdinalIgnoreCase))
        {
            var srcMatch = Regex.Match(trimmed, @"\bsrc=(['""])(?<url>.*?)\1", RegexOptions.IgnoreCase);
            if (srcMatch.Success) return srcMatch.Groups["url"].Value;
        }
        return null;
    }

    private static string BuildHorizontalSliderHtml(List<string> imageUrls)
    {
        if (imageUrls.Count == 0) return string.Empty;
        var itemWidthPercent = (100.0 / imageUrls.Count).ToString("0.0000") + "%";
        var itemsBuilder = new StringBuilder();
        foreach (var url in imageUrls)
        {
            itemsBuilder.Append($"<section style=\"display: inline-block; width: {itemWidthPercent}; min-width: {itemWidthPercent}; max-width: {itemWidthPercent};\"><img src=\"{WebUtility.HtmlEncode(url)}\" style=\"min-width: 100%; max-width: 100%; padding-right: 5px;\"></section>");
        }
        return $"""
        <section style="margin-bottom: 32px; padding: 0 14px; box-sizing: border-box; font-size: 0px;" data-type="custom-block">
        <section class="overflow-scrolling" style="min-width: 100%; max-width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch;">
        <section style="min-width: {imageUrls.Count * 100}%; max-width: {imageUrls.Count * 100}%;">
        {itemsBuilder}
        </section>
        </section>
        <section style="margin: 6px 0px; font-size: 12px; line-height: 17px; color: rgb(167, 167, 167);">向左滑动查看更多内容</section>
        <img src="https://wxlayout.ifanrusercontent.com/yd2qr5ofbspk7y3smytx3514yidjgoc2.gif" style="width: 42px; max-height: 10px;">
        </section>
        """;
    }

    private static string BuildVerticalSliderHtml(List<string> imageUrls)
    {
        if (imageUrls.Count == 0) return string.Empty;
        var imgsBuilder = new StringBuilder();
        foreach (var url in imageUrls)
        {
            imgsBuilder.AppendLine($"<img src=\"{WebUtility.HtmlEncode(url)}\" style=\"display: block; width: 100%;\">");
        }
        return $"""
        <section style="margin: 26px 0; padding: 0 14px; box-sizing: border-box;" data-type="custom-block">
        <section style="width: 100%; height: 300px; overflow: hidden;">
        <section style="display: flex; flex-direction: column; height: 100%; overflow-y: auto;">
        {imgsBuilder}</section>
        </section>
        <section style="margin: 6px 0px; font-size: 12px; line-height: 17px; color: rgb(167, 167, 167); text-align: center;">上下滑动查看更多内容</section>
        </section>
        """;
    }

    private record SliderBlockInfo(int EndIndex, bool IsHorizontal, List<string> Urls);

    public static string BuildWeChatHtml(string markdown, bool roundImages = true, bool addHeaderBanner = false, bool addFooterBanner = false)
    {
        var imgRadius = roundImages ? "8px" : "0";
        var builder = new StringBuilder();
        const string pStyle = "margin: 26px 0; padding: 0 14px; font-size: 15px; color: #222222; text-align: justify; line-height: 27px; word-break: break-all; word-wrap: break-word; font-family: &quot;PingFangSC-Light&quot;;";
        var inWeChatList = false;

        if (addHeaderBanner)
        {
            builder.AppendLine($"<section style=\"text-align: left;justify-content: flex-start;display: flex;flex-flow: row;margin: 0px 0px 24px 0px;width: 100%;align-self: flex-start;background-color: rgb(255, 113, 20);border-radius: 10px;overflow: hidden;box-sizing: border-box;\"><section style=\"text-align: center;line-height: 0;width: 100%;box-sizing: border-box;\"><section style=\"max-width: 100%;vertical-align: middle;display: inline-block;line-height: 0;box-sizing: border-box;\" nodeleaf=\"\"><img src=\"{DefaultHeaderBannerURL}\" class=\"rich_pages wxw-img\" data-ratio=\"0.5333333333333333\" data-type=\"gif\" data-w=\"720\" style=\"vertical-align: middle;max-width: 100%;width: 100%;box-sizing: border-box;\"></section></section></section>");
        }

        var lines = NormalizeMarkdown(markdown).Split('\n');
        var sliderBlocks = new Dictionary<int, SliderBlockInfo>();
        var processedIndices = new HashSet<int>();

        for (int i = 0; i < lines.Length; i++)
        {
            if (processedIndices.Contains(i)) continue;
            var trimmedLine = lines[i].Trim();
            var stripped = trimmedLine.Replace("*", "").Replace(">", "").Replace("#", "").Trim();
            var isHoriz = stripped.Contains("左右滑动");
            var isVert = stripped.Contains("上下滑动");

            if (isHoriz || isVert)
            {
                int startIdx = i;
                int endIdx = i;
                var urls = new List<string>();

                // Look backwards
                int prevIdx = i - 1;
                var backUrls = new List<string>();
                while (prevIdx >= 0)
                {
                    var cTrimmed = lines[prevIdx].Trim();
                    if (string.IsNullOrEmpty(cTrimmed))
                    {
                        prevIdx--;
                        continue;
                    }
                    var u = ExtractImageUrl(lines[prevIdx]);
                    if (u != null)
                    {
                        backUrls.Insert(0, u);
                        startIdx = prevIdx;
                        prevIdx--;
                    }
                    else
                    {
                        break;
                    }
                }
                urls.AddRange(backUrls);

                // Look forwards
                int nextIdx = i + 1;
                while (nextIdx < lines.Length)
                {
                    var cTrimmed = lines[nextIdx].Trim();
                    if (string.IsNullOrEmpty(cTrimmed))
                    {
                        nextIdx++;
                        continue;
                    }
                    var u = ExtractImageUrl(lines[nextIdx]);
                    if (u != null)
                    {
                        urls.Add(u);
                        endIdx = nextIdx;
                        nextIdx++;
                    }
                    else
                    {
                        break;
                    }
                }

                if (urls.Count > 0)
                {
                    sliderBlocks[startIdx] = new SliderBlockInfo(endIdx, isHoriz, urls);
                    for (int k = startIdx; k <= endIdx; k++)
                    {
                        processedIndices.Add(k);
                    }
                }
            }
        }

        int index = 0;
        while (index < lines.Length)
        {
            if (sliderBlocks.TryGetValue(index, out var block))
            {
                if (inWeChatList)
                {
                    builder.AppendLine("</section>");
                    inWeChatList = false;
                }
                builder.AppendLine(block.IsHorizontal ? BuildHorizontalSliderHtml(block.Urls) : BuildVerticalSliderHtml(block.Urls));
                index = block.EndIndex + 1;
                continue;
            }

            var line = lines[index];
            var trimmed = line.Trim();
            if (string.IsNullOrEmpty(trimmed))
            {
                if (inWeChatList)
                {
                    builder.AppendLine("</section>");
                    inWeChatList = false;
                }
                index++;
                continue;
            }

            var isListItem = trimmed.StartsWith("- ") || trimmed.StartsWith("* ") || trimmed.StartsWith("▪ ") || trimmed.StartsWith("• ") || trimmed.StartsWith("■ ");
            if (isListItem)
            {
                if (!inWeChatList)
                {
                    builder.AppendLine("<section style=\"margin: 32px 0; padding: 0 11px;\">");
                    inWeChatList = true;
                }
                var rawText = trimmed[2..].Trim();
                var itemStyle = "display: flex; margin-bottom: 8px; font-family: &quot;PingFangSC-Light&quot;; font-size: 15px; color: #363636; letter-spacing: 0; text-align: justify; line-height: 27px;";
                var dotStyle = "margin-top: 10px; margin-right: 12px; width: 6px; height: 6px; background: #363636;";
                builder.AppendLine($"<section style=\"{itemStyle}\"><section style=\"{dotStyle}\"></section><section style=\"flex: 1;\">{InlineWeChatHtml(rawText, imgRadius)}</section></section>");
                index++;
                continue;
            }
            else if (inWeChatList)
            {
                builder.AppendLine("</section>");
                inWeChatList = false;
            }

            var hasCaption = HasNextCaptionLine(index, lines);
            if (Regex.Match(trimmed, @"^!\[(?<alt>[^\]]*)\]\((?<url>[^)]+)\)$") is { Success: true } mdImg)
            {
                var alt = mdImg.Groups["alt"].Value;
                var url = mdImg.Groups["url"].Value;
                var marginStyle = hasCaption ? "margin: 30px 0 0 0;" : "margin: 30px 0 26px 0;";
                var imageWrapperStyle = $"padding: 0 14px; {marginStyle} text-align: center; box-sizing: border-box;";
                var imgStyle = $"width: 100%; max-width: 100%; height: auto; display: block; margin: 0 auto; border-radius: {imgRadius};";
                builder.AppendLine($"<section style=\"{imageWrapperStyle}\" data-type=\"custom-block\"><img alt=\"{alt}\" src=\"{url}\" style=\"{imgStyle}\"></section>");
                index++;
                continue;
            }

            if (IsCaptionText(trimmed))
            {
                var caption = NormalizeCaptionText(trimmed);
                var captionStyle = "display: inline-block; width: 100%; font-family: &quot;PingFang SC&quot;, system-ui, -apple-system, BlinkMacSystemFont, &quot;Helvetica Neue&quot;, Helvetica, Tahoma, Arial, &quot;Heiti SC&quot;, STHeiti, SimHei, sans-serif; font-weight: 400; font-size: 12px; color: rgb(167, 167, 167); letter-spacing: 0px; text-align: left; margin-left: 16px; margin-right: 16px; margin-bottom: 24px;";
                builder.AppendLine($"<section style=\"{captionStyle}\" data-type=\"custom-block\">{InlineWeChatHtml(caption, imgRadius)}</section>");
                index++;
                continue;
            }

            if (Regex.Match(trimmed, "^(#{1,6})\\s+(.+)$") is { Success: true } heading)
            {
                var level = heading.Groups[1].Value.Length;
                var rawContent = heading.Groups[2].Value.Trim();
                if (rawContent.StartsWith("**") && rawContent.EndsWith("**") && rawContent.Length > 4)
                {
                    rawContent = rawContent[2..^2].Trim();
                }

                var (fontSize, lineHeight, margin) = level switch
                {
                    1 => ("24px", "32px", "62px 0 26px 0"),
                    2 => ("22px", "30px", "62px 0 26px 0"),
                    3 => ("20px", "28px", "62px 0 26px 0"),
                    _ => ("18px", "26px", "42px 0 22px 0")
                };
                var hStyle = $"font-family: &quot;PingFangSC-Semibold&quot;; font-weight: 600; color: #FD4606; text-align: justify; line-height: {lineHeight}; margin: {margin}; padding: 0 14px; font-size: {fontSize};";
                builder.AppendLine($"<h3 style=\"{hStyle}\">{InlineWeChatHtml(rawContent, imgRadius)}</h3>");
            }

            else if (trimmed.StartsWith("> "))
            {
                var bqStyle = "padding: 0 15px; border-left: 4px solid #D8D8D8; padding-left: 14px; font-family: &quot;PingFangSC-Light&quot;, sans-serif; font-weight: 600; font-size: 15px; color: #222222; text-align: justify; line-height: 27px; margin: 26px 0;";
                builder.AppendLine($"<section style=\"{bqStyle}\">{InlineWeChatHtml(trimmed[2..], imgRadius)}</section>");
            }
            else if (trimmed.StartsWith("<"))
            {
                if (trimmed.Contains("<img", StringComparison.OrdinalIgnoreCase))
                {
                    var imageWrapperStyle = "padding: 0 14px; margin: 30px 0 26px 0; text-align: center; box-sizing: border-box;";
                    var imgStyle = $"width: 100%; max-width: 100%; height: auto; display: block; margin: 0 auto; border-radius: {imgRadius};";
                    var styledLine = !trimmed.Contains("style=", StringComparison.OrdinalIgnoreCase)
                        ? trimmed.Replace("<img", $"<img style=\"{imgStyle}\"", StringComparison.OrdinalIgnoreCase)
                        : trimmed;
                    builder.AppendLine($"<section style=\"{imageWrapperStyle}\" data-type=\"custom-block\">{styledLine}</section>");
                }
                else
                {
                    builder.AppendLine(trimmed);
                }
            }
            else if (IsArticleMetaLine(trimmed))
            {
                var content = InlineWeChatHtml(trimmed, imgRadius);
                var hasNextMeta = HasNextArticleMetaLine(index, lines);
                var marginBottom = hasNextMeta ? "0px" : "24px";
                var authorStyle = $"margin-left: 16px;margin-right: 16px;margin-bottom: {marginBottom};";
                var spanStyle = "color: rgba(0, 0, 0, 0.9);font-size: 12px;font-weight: bold;font-family: mp-quote, &quot;PingFang SC&quot;, system-ui, -apple-system, BlinkMacSystemFont, &quot;Helvetica Neue&quot;, &quot;Hiragino Sans GB&quot;, &quot;Microsoft YaHei UI&quot;, &quot;Microsoft YaHei&quot;, Arial, sans-serif;line-height: 1.6;letter-spacing: 0.034em;";
                builder.AppendLine($"<p style=\"{authorStyle}\"><span style=\"{spanStyle}\">{content}</span></p>");
            }
            else
            {
                builder.AppendLine($"<section style=\"{pStyle}\">{InlineWeChatHtml(line, imgRadius)}</section>");
            }
            index++;
        }

        if (inWeChatList)
        {
            builder.AppendLine("</section>");
            inWeChatList = false;
        }

        if (addFooterBanner)
        {
            builder.AppendLine(WeChatFooterBannerHtml);
        }

        return $"""
            <!doctype html>
            <html lang="zh-CN">
            <head>
            <meta charset="utf-8">
            <title>Lark2Pad WeChat Export</title>
            </head>
            <body>
            <section style="font-family: &quot;PingFang SC&quot;, system-ui, -apple-system, BlinkMacSystemFont, &quot;Helvetica Neue&quot;, Helvetica, Tahoma, Arial, &quot;Heiti SC&quot;, STHeiti, SimHei, sans-serif; word-break: break-all; word-wrap: break-word;">
            {builder}
            </section>
            </body>
            </html>
            """;
    }

    private static string InlineWeChatHtml(string value, string imgRadius)
    {
        var trimmed = value.Trim();
        if (IsSafeImageTag(trimmed))
        {
            return trimmed.Contains("style=", StringComparison.OrdinalIgnoreCase)
                ? trimmed
                : trimmed.Replace("<img", $"<img style=\"max-width: 100%; height: auto; margin: 18px auto; display: block; border-radius: {imgRadius};\"", StringComparison.OrdinalIgnoreCase);
        }
        var encoded = WebUtility.HtmlEncode(value);
        var imgStyle = $"max-width: 100%; height: auto; margin: 18px auto; display: block; border-radius: {imgRadius};";
        encoded = Regex.Replace(encoded, @"!\[([^\]]*)\]\((https?://[^\s)]+)\)", $"<img src=\"$2\" alt=\"$1\" style=\"{imgStyle}\">");
        encoded = Regex.Replace(encoded, @"\[([^\]]+)\]\((https?://[^\s)]+)\)", "<a href=\"$2\" style=\"color: #576b95; text-decoration: none;\">$1</a>");
        encoded = Regex.Replace(encoded, @"\*\*(.+?)\*\*", "<strong style=\"font-weight: bold; color: #111111;\">$1</strong>");
        return Regex.Replace(encoded, @"(?<!\*)\*([^*]+)\*(?!\*)", "<em style=\"font-style: italic;\">$1</em>");
    }

    private static string InlineHtml(string value)
    {
        if (IsSafeImageTag(value.Trim())) return value.Trim();
        var encoded = WebUtility.HtmlEncode(value);
        encoded = Regex.Replace(encoded, @"!\[([^\]]*)\]\((https?://[^\s)]+)\)", "<img src=\"$2\" alt=\"$1\">");
        encoded = Regex.Replace(encoded, @"\[([^\]]+)\]\((https?://[^\s)]+)\)", "<a href=\"$2\">$1</a>");
        encoded = Regex.Replace(encoded, @"\*\*(.+?)\*\*", "<strong>$1</strong>");
        return Regex.Replace(encoded, @"(?<!\*)\*([^*]+)\*(?!\*)", "<em>$1</em>");
    }

    private async Task<string> UploadImageAsync(string source, string? baseDirectory)
    {
        LarkDiagnosticLog.Write("Downloading image.");
        var (data, originalFileName, mimeType) = await ReadImageAsync(source, baseDirectory);
        var fileName = CreateUploadFileName(mimeType, originalFileName);
        LarkDiagnosticLog.Write($"Image downloaded: {originalFileName}, {data.Length} bytes, {mimeType}; upload name {fileName}.");
        if (data.LongLength > UploadLimitBytes)
            throw new InvalidOperationException($"图片 {fileName} 超过 4.8 MB 上传限制，请先压缩后重试。");

        var cookies = LoadCookies();
        if (cookies.Count == 0)
            throw new InvalidOperationException("检测到图片。请先登录 Etherpad，以便上传图片并完成转换。");

        var cookieHeader = string.Join("; ", cookies.Select(cookie => $"{cookie.Name}={cookie.Value}"));
        using var form = new MultipartFormDataContent();
        using var content = new ByteArrayContent(data);
        content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue(mimeType);
        form.Add(content, "file", SanitizeFileName(fileName));
        using var request = new HttpRequestMessage(HttpMethod.Post, $"{RootUrl}p/{ImageUploadPadId}/pluginfw/ep_image_upload/upload") { Content = form };
        request.Headers.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36");
        request.Headers.TryAddWithoutValidation("Origin", RootUrl.TrimEnd('/'));
        request.Headers.Referrer = new Uri($"{RootUrl}p/{ImageUploadPadId}");
        request.Headers.TryAddWithoutValidation("X-Requested-With", "XMLHttpRequest");
        request.Headers.TryAddWithoutValidation("Cookie", cookieHeader);
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        LarkDiagnosticLog.Write($"Posting {fileName} to image host.");
        var response = await ImageHttpClient.SendAsync(request, HttpCompletionOption.ResponseContentRead, cancellation.Token);
        var payload = await response.Content.ReadAsStringAsync();
        LarkDiagnosticLog.Write($"Image host responded HTTP {(int)response.StatusCode}, {payload.Length} chars.");
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"图片上传失败（HTTP {(int)response.StatusCode}）：{payload}");

        try
        {
            using var document = JsonDocument.Parse(payload);
            if (document.RootElement.ValueKind == JsonValueKind.Object &&
                document.RootElement.TryGetProperty("url", out var url) &&
                url.GetString() is { Length: > 0 } uploaded)
                return uploaded;
            if (document.RootElement.ValueKind == JsonValueKind.String && document.RootElement.GetString() is { Length: > 0 } stringUrl)
                return stringUrl;
        }
        catch (JsonException) { }

        var plainUrl = payload.Trim().Trim('"');
        if (Uri.TryCreate(plainUrl, UriKind.Absolute, out _)) return plainUrl;
        throw new InvalidOperationException($"图片服务返回了无效地址：{payload}");
    }

    private static async Task<(byte[] Data, string FileName, string MimeType)> ReadImageAsync(string source, string? baseDirectory)
    {
        if (Uri.TryCreate(source, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https")
        {
            using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var response = await ImageHttpClient.GetAsync(uri, cancellation.Token);
            response.EnsureSuccessStatusCode();
            var mime = response.Content.Headers.ContentType?.MediaType ?? MimeTypeForPath(uri.AbsolutePath);
            return (await response.Content.ReadAsByteArrayAsync(), Path.GetFileName(uri.LocalPath) is { Length: > 0 } name ? name : "image.png", mime);
        }

        var localPath = Uri.TryCreate(source, UriKind.Absolute, out var fileUri) && fileUri.IsFile
            ? fileUri.LocalPath
            : Path.GetFullPath(Path.Combine(baseDirectory ?? Environment.CurrentDirectory, source));
        if (!File.Exists(localPath)) throw new InvalidOperationException($"找不到 Markdown 引用的图片：{source}");
        return (await File.ReadAllBytesAsync(localPath), Path.GetFileName(localPath), MimeTypeForPath(localPath));
    }

    private static string ConvertMarkdownImagesToHtml(string markdown)
    {
        var matches = MarkdownImageRegex().Matches(markdown);
        if (matches.Count == 0) return markdown;

        // Mirrors ConversionCoordinator.convertMarkdownImagesToHTML in the macOS app:
        // names are imga, imgb… and assigned while replacing from the end of the document.
        var result = new StringBuilder(markdown);
        for (var index = matches.Count - 1; index >= 0; index--)
        {
            var match = matches[index];
            var url = WebUtility.HtmlEncode(match.Groups["url"].Value.Trim());
            var name = "img" + IndexToLetters(matches.Count - 1 - index);
            result.Remove(match.Index, match.Length);
            result.Insert(match.Index, $"<img src=\"{url}\" name=\"{name}\">");
        }
        return result.ToString();
    }

    private static string IndexToLetters(int index)
    {
        var result = string.Empty;
        var value = index;
        do
        {
            result = (char)('a' + value % 26) + result;
            value = value / 26 - 1;
        } while (value >= 0);
        return result;
    }

    private static string LazyLoadPreviewImages(string body)
    {
        var imageIndex = 0;
        return Regex.Replace(body, "<img\\b(?<before>[^>]*?)\\bsrc=(?<quote>[\\\"'])(?<url>.*?)\\k<quote>(?<after>[^>]*)>", match =>
        {
            imageIndex++;
            if (imageIndex <= 3) return match.Value;
            var before = match.Groups["before"].Value;
            var quote = match.Groups["quote"].Value;
            var source = match.Groups["url"].Value;
            var after = match.Groups["after"].Value;
            const string placeholder = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='16'%3E%3C/svg%3E";
            return $"<img{before}src={quote}{placeholder}{quote} data-src={quote}{source}{quote} data-lazy-image=\"true\" loading=\"lazy\" decoding=\"async\"{after}>";
        }, RegexOptions.IgnoreCase);
    }

    private const string PreviewLazyLoadScript = """
        <script>
        (() => {
          const load = (image) => { const source = image.dataset.src; if (!source) return; image.src = source; image.removeAttribute('data-src'); image.removeAttribute('data-lazy-image'); };
          const images = Array.from(document.querySelectorAll('img[data-src]'));
          if (!('IntersectionObserver' in window)) { images.forEach(load); return; }
          const observer = new IntersectionObserver(entries => entries.forEach(entry => { if (entry.isIntersecting) { load(entry.target); observer.unobserve(entry.target); } }), { rootMargin: '900px 0px' });
          images.forEach(image => observer.observe(image));
        })();
        </script>
        """;

    private static string StripMarkdownEscapes(string markdown) => Regex.Replace(markdown, "\\\\([!\\\"#$%&'()*+,\\-./:;<=>?@\\[\\]^_`{|}~])", "$1");
    private static string MimeTypeForPath(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".jpg" or ".jpeg" => "image/jpeg", ".webp" => "image/webp", ".gif" => "image/gif", ".bmp" => "image/bmp", ".heic" or ".heif" => "image/heic", _ => "image/png"
    };
    private static string SanitizeFileName(string value) => Regex.Replace(value, "[\\\\/:*?\"<>|]", "_");
    private static string CreateUploadFileName(string mimeType, string fallbackName)
    {
        var extension = mimeType.ToLowerInvariant() switch
        {
            var value when value.Contains("jpeg") => "jpg",
            var value when value.Contains("webp") => "webp",
            var value when value.Contains("gif") => "gif",
            var value when value.Contains("heic") || value.Contains("heif") => "heic",
            _ => Path.GetExtension(fallbackName).TrimStart('.').ToLowerInvariant() is { Length: > 0 } existing ? existing : "png"
        };
        return $"l2p_{Guid.NewGuid():N}"[..12] + $".{extension}";
    }
    private static HttpClient CreateImageHttpClient()
    {
        var handler = new SocketsHttpHandler
        {
            MaxConnectionsPerServer = 6,
            PooledConnectionLifetime = TimeSpan.FromMinutes(2),
            ConnectTimeout = TimeSpan.FromSeconds(10)
        };
        return new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
    }
    [GeneratedRegex(@"!\[(?<alt>[^\]]*)\]\((?<url>[^)]+)\)", RegexOptions.Compiled)]
    private static partial Regex MarkdownImageRegex();

    private static string HtmlToMarkdown(string html)
    {
        var value = Regex.Replace(html, @"<(script|style)[^>]*>[\s\S]*?</\1>", "", RegexOptions.IgnoreCase);
        value = Regex.Replace(value, @"<br\s*/?>", "\n", RegexOptions.IgnoreCase);
        value = Regex.Replace(value, @"<h1[^>]*>([\s\S]*?)</h1>", "# $1\n", RegexOptions.IgnoreCase);
        value = Regex.Replace(value, @"<h2[^>]*>([\s\S]*?)</h2>", "## $1\n", RegexOptions.IgnoreCase);
        value = Regex.Replace(value, @"<h3[^>]*>([\s\S]*?)</h3>", "### $1\n", RegexOptions.IgnoreCase);
        value = Regex.Replace(value, @"<li[^>]*>([\s\S]*?)</li>", "- $1\n", RegexOptions.IgnoreCase);
        value = Regex.Replace(value, @"<blockquote[^>]*>([\s\S]*?)</blockquote>", "> $1\n", RegexOptions.IgnoreCase);
        value = Regex.Replace(value, @"<img[^>]*src=[""']([^""']+)[""'][^>]*>", "![]($1)", RegexOptions.IgnoreCase);
        value = Regex.Replace(value, @"<a[^>]*href=[""']([^""']+)[""'][^>]*>([\s\S]*?)</a>", "[$2]($1)", RegexOptions.IgnoreCase);
        value = Regex.Replace(value, @"<(strong|b)[^>]*>([\s\S]*?)</\1>", "**$2**", RegexOptions.IgnoreCase);
        value = Regex.Replace(value, @"<(em|i)[^>]*>([\s\S]*?)</\1>", "*$2*", RegexOptions.IgnoreCase);
        value = Regex.Replace(value, @"</(p|div|tr)\s*>", "\n", RegexOptions.IgnoreCase);
        value = Regex.Replace(value, @"<[^>]+>", "");
        return NormalizeMarkdown(WebUtility.HtmlDecode(value));
    }

    private static string ExtractHtmlFragment(string html)
    {
        const string start = "<!--StartFragment-->";
        const string end = "<!--EndFragment-->";
        var from = html.IndexOf(start, StringComparison.Ordinal);
        var to = html.IndexOf(end, StringComparison.Ordinal);
        return from >= 0 && to > from ? html[(from + start.Length)..to] : html;
    }

    private static string NormalizeMarkdown(string value) => Regex.Replace(value.Replace("\r\n", "\n").Replace('\r', '\n'), "\n{3,}", "\n\n").Trim();
    private static bool IsSafeImageTag(string value) => Regex.IsMatch(value, "^<img\\b[^>]*>$", RegexOptions.IgnoreCase);
    private const string EtherpadStyle = """
        body { font-family: sans-serif; line-height: 1.6; }
        h1, h2, h3, h4, h5, h6 { margin-top: 20px; margin-bottom: 10px; font-weight: bold; }
        h1 { font-size: 2em; }
        h2 { font-size: 1.5em; }
        h3 { font-size: 1.2em; }
        ol { counter-reset: item; padding-left: 20px; }
        ol > li { display: block; counter-increment: item; margin-bottom: 5px; }
        ol > li:before { content: counters(item, ".") ". "; font-weight: bold; }
        ul { padding-left: 20px; list-style-type: disc; margin-bottom: 15px; }
        li { margin-bottom: 5px; }
        img { max-width: 100%; margin: 10px 0; }
        strong, b { font-weight: bold; }
        """;
    private static string WrapHtml(string body, string title, string style) => $"<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>{title}</title>\n<meta name=\"generator\" content=\"Etherpad\">\n<style>\n{style}\n</style>\n</head>\n<body>\n{body}\n</body>\n</html>";
    private static string DefaultFilename() => "Lark2Pad_" + DateTime.Now.ToString("yyyyMMdd") + ".html";
    private static string SuggestedPadId(string markdown)
    {
        var title = NormalizeMarkdown(markdown).Split('\n').Select(line => Regex.Replace(line, "^#{1,6}\\s*", "").Trim()).FirstOrDefault(line => !string.IsNullOrWhiteSpace(line)) ?? "LiquidConvert_文档";
        title = Regex.Replace(title, "[\\\\/?#%&]+", "_");
        title = Regex.Replace(title, "\\s+", "_").Trim('.', '_', '-');
        return string.IsNullOrEmpty(title) ? "LiquidConvert_文档" : title[..Math.Min(80, title.Length)];
    }
    private static string NextAvailablePadId(string baseId)
    {
        var used = SettingsStore.Get(PadIdsKey) is string saved ? JsonSerializer.Deserialize<List<string>>(saved) ?? [] : [];
        for (var index = 0; ; index++)
        {
            var candidate = index == 0 ? baseId : $"{baseId}({index})";
            if (!used.Contains(candidate, StringComparer.Ordinal)) return candidate;
        }
    }
    private static void RecordPadId(string padId)
    {
        var used = SettingsStore.Get(PadIdsKey) is string saved ? JsonSerializer.Deserialize<List<string>>(saved) ?? [] : [];
        if (!used.Contains(padId, StringComparer.Ordinal)) used.Add(padId);
        SettingsStore.Set(PadIdsKey, JsonSerializer.Serialize(used));
    }
    private static List<CookieRecord> LoadCookies() => SettingsStore.Get(CookieKey) is string saved ? JsonSerializer.Deserialize<List<CookieRecord>>(saved) ?? [] : [];

    public sealed record CMSChannel(string Id, string Name);

    public static readonly List<CMSChannel> AvailableCMSChannels = new()
    {
        new CMSChannel("ifanr-morning-paper", "ifanr 早报"),
        new CMSChannel("ifanr", "ifanr 推文"),
        new CMSChannel("appso-morning-paper", "APPSO 早报"),
        new CMSChannel("appso", "APPSO 推文"),
        new CMSChannel("intelligentcar-morning-paper", "董车会早报"),
        new CMSChannel("intelligentcar", "董车会推文"),
        new CMSChannel("minapp", "知晓云"),
        new CMSChannel("wordpress", "WordPress")
    };

    private static readonly Dictionary<string, string> DataUriCache = new(StringComparer.OrdinalIgnoreCase);

    public async Task<string> ConvertImageUrlsToBase64DataUrisAsync(string html)
    {
        var result = html;
        var pattern = @"<img\b[^>]*?\bsrc=[""'](?<url>https?://[^""']+)[""']";
        var matches = Regex.Matches(html, pattern, RegexOptions.IgnoreCase);

        var urlsToFetch = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (Match match in matches)
        {
            if (match.Groups["url"].Success)
            {
                var url = match.Groups["url"].Value;
                lock (DataUriCache)
                {
                    if (DataUriCache.ContainsKey(url))
                    {
                        result = result.Replace(url, DataUriCache[url]);
                        continue;
                    }
                }
                urlsToFetch.Add(url);
            }
        }

        if (urlsToFetch.Count == 0) return result;

        using var client = new HttpClient();
        client.Timeout = TimeSpan.FromSeconds(15);
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");

        foreach (var urlStr in urlsToFetch)
        {
            try
            {
                var response = await client.GetAsync(urlStr);
                if (response.IsSuccessStatusCode)
                {
                    var data = await response.Content.ReadAsByteArrayAsync();
                    var mime = response.Content.Headers.ContentType?.MediaType ?? "image/png";
                    var base64 = Convert.ToBase64String(data);
                    var dataUri = $"data:{mime};base64,{base64}";

                    lock (DataUriCache)
                    {
                        DataUriCache[urlStr] = dataUri;
                    }
                    result = result.Replace(urlStr, dataUri);
                }
            }
            catch (Exception ex)
            {
                LarkDiagnosticLog.Write($"Base64 download failed for {urlStr}: {ex.Message}");
            }
        }

        return result;
    }

    public async Task<string> SendToCMSAsync(string padID, string channel)
    {
        var cookies = LoadCookies();
        if (cookies.Count == 0)
        {
            throw new InvalidOperationException("请先登录公司 Etherpad 账号，同步 Session。");
        }

        var cookieHeader = string.Join("; ", cookies.Select(c => $"{c.Name}={c.Value}"));
        var server = SettingsStore.LarkServer.TrimEnd('/');
        var encodedPadID = Uri.EscapeDataString(padID);
        var encodedChannel = Uri.EscapeDataString(channel);

        var cmsUrl = $"{server}/p/{encodedPadID}/send2cms/{encodedChannel}";
        var padUrl = $"{server}/p/{encodedPadID}";

        using var request = new HttpRequestMessage(HttpMethod.Post, cmsUrl);
        request.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
        request.Headers.Add("Origin", server);
        request.Headers.Add("Referer", padUrl);
        request.Headers.Add("X-Requested-With", "XMLHttpRequest");
        request.Headers.Add("Cookie", cookieHeader);

        using var client = new HttpClient();
        var response = await client.SendAsync(request);
        var responseText = await response.Content.ReadAsStringAsync();

        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"服务器拒绝发布 (HTTP {response.StatusCode}): {responseText}");
        }

        return responseText;
    }
}

public sealed record CookieRecord(string Name, string Value, string? Path);
