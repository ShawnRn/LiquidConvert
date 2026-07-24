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

        _isInitializing = true;
        AutoUploadToggle.IsOn = SettingsStore.LarkAutoUpload;
        RoundImagesToggle.IsOn = SettingsStore.LarkRoundImages;
        AddHeaderToggle.IsOn = SettingsStore.LarkAddHeader;
        AddFooterToggle.IsOn = SettingsStore.LarkAddFooter;
        _isInitializing = false;
    }

    private void Settings_Toggled(object sender, RoutedEventArgs e)
    {
        if (_isInitializing) return;
        SettingsStore.LarkAutoUpload = AutoUploadToggle.IsOn;
        SettingsStore.LarkRoundImages = RoundImagesToggle.IsOn;
        SettingsStore.LarkAddHeader = AddHeaderToggle.IsOn;
        SettingsStore.LarkAddFooter = AddFooterToggle.IsOn;
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

    private async void LarkCopyWeChat_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_currentMarkdown)) return;
        CopyWeChatButton.IsEnabled = false;
        CopyWeChatButton.Content = "排版生成中...";
        LarkStatus.Text = "正在下载外部图床图片并转换 Base64 排版，请稍候...";

        try
        {
            var baseWeChatHtml = Lark2PadService.BuildWeChatHtml(
                _currentMarkdown,
                roundImages: SettingsStore.LarkRoundImages,
                addHeaderBanner: SettingsStore.LarkAddHeader,
                addFooterBanner: SettingsStore.LarkAddFooter
            );

            var base64Html = await Lark2PadService.Instance.ConvertImageUrlsToBase64DataUrisAsync(baseWeChatHtml);

            var dp = new DataPackage();
            dp.SetHtmlFormat(DataPackageViewHelper.ToHtmlFormat(base64Html));
            dp.SetText(_currentMarkdown);
            Clipboard.SetContent(dp);
            LarkStatus.Text = "已复制公众号排版！若出现加载缓慢，推荐使用一键同步至公众号草稿箱。";
        }
        catch (Exception ex)
        {
            LarkStatus.Text = $"排版失败: {ex.Message}";
        }
        finally
        {
            CopyWeChatButton.IsEnabled = true;
            CopyWeChatButton.Content = "复制到公众号";
        }
    }

    private async void LarkSync_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_currentMarkdown)) return;
        LarkStatus.Text = "正在同步到 Pad...";

        try
        {
            await Lark2PadService.Instance.SyncToPadAsync(_currentMarkdown);
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

    private async void CmsPublish_Click(object sender, RoutedEventArgs e)
    {
        if (sender is MenuFlyoutItem item && item.Tag is string channel)
        {
            if (string.IsNullOrEmpty(_currentMarkdown)) return;

            if (!Lark2PadService.Instance.IsLoggedIn)
            {
                LarkStatus.Text = "发布失败：请先登录 Etherpad 账号。";
                var warningDialog = new ContentDialog
                {
                    Title = "需要登录",
                    Content = "请先在右上角点击“登录 Etherpad”，并输入公司账号密码同步 Session。",
                    CloseButtonText = "确定",
                    XamlRoot = XamlRoot
                };
                await warningDialog.ShowAsync();
                return;
            }

            SyncSplitButton.IsEnabled = false;
            LarkStatus.Text = $"正在同步并一键发布至 {item.Text} 草稿箱...";

            try
            {
                var padUrl = await Lark2PadService.Instance.SyncToPadAsync(_currentMarkdown);
                var padId = padUrl.Segments.Last();

                await Lark2PadService.Instance.SendToCMSAsync(padId, channel);
                LarkStatus.Text = $"成功同步并发布至 {item.Text} 草稿箱！";

                var successDialog = new ContentDialog
                {
                    Title = "发布成功",
                    Content = $"文档已成功同步转存至 {item.Text} 微信草稿箱。\n同步 Pad ID: {padId}",
                    CloseButtonText = "确定",
                    XamlRoot = XamlRoot
                };
                await successDialog.ShowAsync();

                await Windows.System.Launcher.LaunchUriAsync(padUrl);
            }
            catch (Exception ex)
            {
                LarkStatus.Text = $"一键发布失败: {ex.Message}";
                var errDialog = new ContentDialog
                {
                    Title = "转存失败",
                    Content = ex.Message,
                    CloseButtonText = "确定",
                    XamlRoot = XamlRoot
                };
                await errDialog.ShowAsync();
            }
            finally
            {
                SyncSplitButton.IsEnabled = true;
            }
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
