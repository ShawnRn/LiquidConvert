using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.Web.WebView2.Core;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using LiquidConvert.Windows.Services;

namespace LiquidConvert.Windows.Views;

public sealed partial class Lark2PadPage : Page
{
    private string? _currentMarkdown;
    private string? _currentEtherpadHtml;
    private string? _currentSourceDescription;

    public Lark2PadPage()
    {
        InitializeComponent();
        Loaded += Lark2PadPage_Loaded;
    }

    private void Lark2PadPage_Loaded(object sender, RoutedEventArgs e)
    {
        UpdateLoginStateUI();
    }

    private void UpdateLoginStateUI()
    {
        bool loggedIn = Lark2PadService.Instance.IsLoggedIn;
        LarkLoginIndicator.Fill = new Microsoft.UI.Xaml.Media.SolidColorBrush(
            loggedIn ? Windows.UI.Color.FromArgb(255, 16, 124, 65) : Windows.UI.Color.FromArgb(255, 148, 163, 184));
        LarkLoginStatus.Text = loggedIn ? $"已登录 ({Lark2PadService.Instance.UserDisplayName})" : "未登录";
        LarkLoginButton.Content = loggedIn ? "退出登录" : "登录 Etherpad";
    }

    private async void LarkLogin_Click(object sender, RoutedEventArgs e)
    {
        if (Lark2PadService.Instance.IsLoggedIn)
        {
            Lark2PadService.Instance.Logout();
            UpdateLoginStateUI();
            return;
        }

        var loginWin = new LarkLoginWindow();
        WinRT.Interop.InitializeWithWindow.Initialize(loginWin, App.MainWindowHandle);
        await loginWin.ShowDialogAsync(XamlRoot);
        UpdateLoginStateUI();
    }

    private void LarkDropTarget_DragOver(object sender, DragEventArgs e)
    {
        e.AcceptedOperation = DataPackageOperation.Copy;
    }

    private async void LarkDropTarget_Drop(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            var items = await e.DataView.GetStorageItemsAsync();
            if (items.FirstOrDefault() is StorageFile file)
            {
                await ProcessFileAsync(file);
            }
        }
        else
        {
            await ProcessClipboardAsync();
        }
    }

    private async void LarkDropTarget_Tapped(object sender, TappedRoutedEventArgs e)
    {
        await ProcessClipboardAsync();
    }

    private async void LarkPaste_Click(object sender, RoutedEventArgs e)
    {
        await ProcessClipboardAsync();
    }

    private async void LarkImport_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.MainWindowHandle);
        picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
        picker.FileTypeFilter.Add(".md");
        picker.FileTypeFilter.Add(".markdown");
        picker.FileTypeFilter.Add(".txt");
        picker.FileTypeFilter.Add(".html");

        var file = await picker.PickSingleFileAsync();
        if (file != null)
        {
            await ProcessFileAsync(file);
        }
    }

    private async Task ProcessClipboardAsync()
    {
        try
        {
            LarkStatus.Text = "正在读取剪贴板...";
            var result = await Lark2PadService.Instance.ImportFromClipboardAsync();
            SetImportResult(result.Markdown, result.EtherpadHtml, "剪贴板富文本");
        }
        catch (Exception ex)
        {
            LarkStatus.Text = $"剪贴板读取失败: {ex.Message}";
        }
    }

    private async Task ProcessFileAsync(StorageFile file)
    {
        try
        {
            LarkStatus.Text = $"正在导入 {file.Name}...";
            var result = await Lark2PadService.Instance.ImportFromFileAsync(file);
            SetImportResult(result.Markdown, result.EtherpadHtml, file.Name);
        }
        catch (Exception ex)
        {
            LarkStatus.Text = $"文件导入失败: {ex.Message}";
        }
    }

    private void SetImportResult(string markdown, string etherpadHtml, string sourceDescription)
    {
        _currentMarkdown = markdown;
        _currentEtherpadHtml = etherpadHtml;
        _currentSourceDescription = sourceDescription;

        LarkPreviewSource.Text = $"来源: {sourceDescription}";
        LarkDropTarget.Visibility = Visibility.Collapsed;
        LarkPreviewPanel.Visibility = Visibility.Visible;
        LarkActions.Visibility = Visibility.Visible;

        LarkPreviewLoading.Visibility = Visibility.Visible;
        LarkPreview.Opacity = 0;

        string htmlDoc = $"<!DOCTYPE html><html><head><meta charset='utf-8'/><style>body{{font-family:sans-serif;padding:16px;line-height:1.6;color:#334155;}}img{{max-width:100%;}}</style></head><body>{etherpadHtml}</body></html>";
        LarkPreview.NavigateToString(htmlDoc);
    }

    private void LarkPreview_NavigationCompleted(WebView2 sender, CoreWebView2NavigationCompletedEventArgs args)
    {
        LarkPreviewLoading.Visibility = Visibility.Collapsed;
        LarkPreview.Opacity = 1;
    }

    private void LarkReset_Click(object sender, RoutedEventArgs e)
    {
        _currentMarkdown = null;
        _currentEtherpadHtml = null;
        LarkPreviewPanel.Visibility = Visibility.Collapsed;
        LarkActions.Visibility = Visibility.Collapsed;
        LarkDropTarget.Visibility = Visibility.Visible;
        LarkStatus.Text = "点击下方区域读取剪贴板，或将 Markdown 文件拖入。";
    }

    private void LarkCopyMarkdown_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_currentMarkdown)) return;
        var dp = new DataPackage();
        dp.SetText(_currentMarkdown);
        Clipboard.SetContent(dp);
        LarkStatus.Text = "Markdown 内容已复制！";
    }

    private void LarkCopyEtherpad_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_currentEtherpadHtml)) return;
        var dp = new DataPackage();
        dp.SetText(_currentEtherpadHtml);
        Clipboard.SetContent(dp);
        LarkStatus.Text = "Etherpad 内容已复制！";
    }

    private async void LarkExport_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_currentEtherpadHtml)) return;
        var picker = new FileSavePicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.MainWindowHandle);
        picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
        picker.FileTypeChoices.Add("HTML 文档", new System.Collections.Generic.List<string> { ".html" });
        picker.SuggestedFileName = "Lark2Pad-Export";

        var saveFile = await picker.PickSaveFileAsync();
        if (saveFile != null)
        {
            await FileIO.WriteTextAsync(saveFile, _currentEtherpadHtml);
            LarkStatus.Text = $"已导出 HTML 至 {saveFile.Path}";
        }
    }

    private void LarkCopyWeChat_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_currentEtherpadHtml)) return;
        var dp = new DataPackage();
        dp.SetHtmlFormat(DataPackageViewHelper.ToHtmlFormat(_currentEtherpadHtml));
        Clipboard.SetContent(dp);
        LarkStatus.Text = "已复制为微信公众号富文本样式！可以直接在公众号后台粘贴。";
    }

    private async void LarkSync_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_currentEtherpadHtml)) return;
        LarkStatus.Text = "正在同步到 Pad...";

        try
        {
            await Lark2PadService.Instance.SyncToPadAsync(_currentEtherpadHtml);
            LarkStatus.Text = "已成功同步到 Pad！";
            var dialog = new ContentDialog
            {
                Title = "同步成功",
                Content = "文档已成功同步至 Pad 站点与公众号草稿。",
                CloseButtonText = "确定",
                XamlRoot = XamlRoot
            };
            await dialog.ShowAsync();
        }
        catch (Exception ex)
        {
            LarkStatus.Text = $"同步失败: {ex.Message}";
        }
    }
}

internal static class DataPackageViewHelper
{
    public static string ToHtmlFormat(string html)
    {
        const string header = "Version:0.9\r\nStartHTML:0000000000\r\nEndHTML:0000000000\r\nStartFragment:0000000000\r\nEndFragment:0000000000\r\n";
        string startFragment = "<!--StartFragment-->";
        string endFragment = "<!--EndFragment-->";
        string fullHtml = $"<html><body>{startFragment}{html}{endFragment}</body></html>";
        return header + fullHtml;
    }
}
