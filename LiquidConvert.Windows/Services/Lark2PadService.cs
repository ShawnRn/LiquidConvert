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

    public void CopyWeChatHtml(string markdown) => CopyHtml(BuildRenderedHtml(markdown));

    public void CopyHtml(string html)
    {
        var package = new DataPackage();
        package.SetHtmlFormat(html);
        package.SetText(html);
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
        var body = string.Join("<br>\n", NormalizeMarkdown(markdown).Split('\n').Select(line =>
        {
            var trimmed = line.Trim();
            return IsSafeImageTag(trimmed) ? trimmed : WebUtility.HtmlEncode(line);
        }));
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
}

public sealed record CookieRecord(string Name, string Value, string? Path);
