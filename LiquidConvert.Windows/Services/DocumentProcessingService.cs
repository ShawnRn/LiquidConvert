using System.Text.RegularExpressions;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace LiquidConvert.Windows.Services;

public sealed class DocumentProcessingService
{
    public async Task ExportMarkdownAsync(StorageFile input, StorageFolder outputFolder)
    {
        var text = await FileIO.ReadTextAsync(input);
        if (Path.GetExtension(input.Name).StartsWith(".htm", StringComparison.OrdinalIgnoreCase))
            text = HtmlToMarkdown(text);
        var output = await outputFolder.CreateFileAsync($"{Path.GetFileNameWithoutExtension(input.Name)}.md", CreationCollisionOption.GenerateUniqueName);
        await FileIO.WriteTextAsync(output, text);
    }

    public async Task ExportClipboardHtmlAsync(StorageFolder outputFolder)
    {
        var view = Clipboard.GetContent();
        if (!view.Contains(StandardDataFormats.Html))
            throw new InvalidOperationException("剪贴板中没有富文本 HTML，请先在飞书文档中复制内容。");
        var html = await view.GetHtmlFormatAsync();
        var output = await outputFolder.CreateFileAsync("Lark2Pad-export.html", CreationCollisionOption.GenerateUniqueName);
        await FileIO.WriteTextAsync(output, ExtractHtmlFragment(html));
    }

    private static string ExtractHtmlFragment(string html)
    {
        const string start = "<!--StartFragment-->";
        const string end = "<!--EndFragment-->";
        var from = html.IndexOf(start, StringComparison.Ordinal);
        var to = html.IndexOf(end, StringComparison.Ordinal);
        return from >= 0 && to > from ? html[(from + start.Length)..to] : html;
    }

    private static string HtmlToMarkdown(string html)
    {
        html = Regex.Replace(html, @"<h1[^>]*>(.*?)</h1>", "# $1\n\n", RegexOptions.IgnoreCase | RegexOptions.Singleline);
        html = Regex.Replace(html, @"<h2[^>]*>(.*?)</h2>", "## $1\n\n", RegexOptions.IgnoreCase | RegexOptions.Singleline);
        html = Regex.Replace(html, @"<br\s*/?>", "\n", RegexOptions.IgnoreCase);
        html = Regex.Replace(html, @"</?(p|div|li)[^>]*>", "\n", RegexOptions.IgnoreCase);
        html = Regex.Replace(html, @"<[^>]+>", string.Empty);
        return System.Net.WebUtility.HtmlDecode(html).Trim();
    }
}
