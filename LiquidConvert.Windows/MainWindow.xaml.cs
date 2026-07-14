using LiquidConvert.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using System.Collections.ObjectModel;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace LiquidConvert.Windows;

public sealed partial class MainWindow : Window
{
    private static readonly SizeInt32 DefaultWindowSize = new(1376, 936);
    private readonly ObservableCollection<StorageFile> _files = [];
    private readonly ImageProcessingService _imageService = new();
    private readonly MediaProcessingService _mediaService = new();
    private readonly IconProcessingService _iconService = new();
    private readonly DocumentProcessingService _documentService = new();
    private readonly Lark2PadService _larkService = new();
    private string _larkHtml = string.Empty;
    private string _mode = "convert";
    private bool _isTransitioning;

    public MainWindow()
    {
        InitializeComponent();
        AppWindow.SetIcon("Assets\\AppIcon.ico");
        AppWindow.Resize(DefaultWindowSize);
        WindowSizeConstraint.Attach(WindowNative.GetWindowHandle(this), DefaultWindowSize);
        UserNameText.Text = Environment.UserName;
        FileList.ItemsSource = _files;
        RootLayout.ActualThemeChanged += (_, _) =>
        {
            SetSelectedNavigation(_mode);
            UpdateTitleBarColors();
        };
        ApplyTheme();
        RefreshLarkLoginState();
        SetSelectedNavigation("convert");
    }

    private async void ModeButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button || button.Tag is not string mode)
            return;
        if (_isTransitioning || mode == _mode) return;

        _isTransitioning = true;
        await AnimateContentAsync(0, 8, 100);
        ApplyMode(mode);
        await AnimateContentAsync(1, 0, 220);
        _isTransitioning = false;
    }

    private void ApplyMode(string mode)
    {
        _mode = mode;
        _files.Clear();
        (PageEyebrow.Text, PageTitle.Text, PageDescription.Text, WorkspaceTitle.Text, WorkspaceHint.Text, RunButton.Content) = mode switch
        {
            "compress" => ("IMAGE TOOLS", "图片压缩", "自动寻找低于 5 MB 的最佳 JPEG 质量与分辨率。", "将图片压缩到 5 MB 以下", "拖入或选择图片，LiquidConvert 会优先保留清晰度。", "开始压缩"),
            "stitch" => ("IMAGE TOOLS", "图片拼接", "按选择顺序纵向拼接图片，并智能统一宽度。", "选择多张图片进行拼接", "按选择顺序排列，输出一张连续长图。", "开始拼接"),
            "round" => ("IMAGE TOOLS", "图片圆角", "为图片生成精致的透明圆角 PNG。", "选择需要添加圆角的图片", "拖入或选择图片，调整下方圆角半径后立即导出。", "导出圆角 PNG"),
            "audio" => ("MEDIA TOOLS", "音频提取", "从视频或音频文件提取为 M4A 音频。", "选择音视频文件", "使用本地 FFmpeg 引擎处理，保留原始文件。", "提取音频"),
            "video" => ("MEDIA TOOLS", "视频 GIF", "将视频转换为高质量 GIF 动图。", "选择视频文件", "默认 15 FPS、最长边 720px，可用于快速分享。", "生成 GIF"),
            "icon" => ("ICON TOOLS", "Windows 图标", "将图片转换为 Windows .ico 图标。", "选择一张 PNG 或 JPEG", "输出包含 256px PNG 图层的现代 Windows 图标。", "生成 ICO"),
            "document" => ("DOCUMENT TOOLS", "AI 文档提取", "将文本或 HTML 文档导出为 Markdown。", "选择文本或 HTML 文件", "保留可读文本与基础段落结构，更多格式持续接入。", "导出 Markdown"),
            "lark" => ("DOCUMENT TOOLS", "Lark2Pad", "将飞书剪贴板内容导出为 Etherpad 兼容 HTML。", "复制飞书文档内容后开始", "直接读取剪贴板中的富文本 HTML 并导出；登录同步随后接入。", "导出剪贴板 HTML"),
            _ => ("IMAGE TOOLS", "图片转换", "快速将图片转换为常用格式，所有文件均在本机处理。", "选择需要转换的图片", "支持拖入文件，或从本地选择 PNG、JPEG、WebP、HEIC 等格式。", "转换为 PNG")
        };
        var larkMode = mode == "lark";
        GenericWorkspace.Visibility = larkMode ? Visibility.Collapsed : Visibility.Visible;
        LarkWorkspace.Visibility = larkMode ? Visibility.Visible : Visibility.Collapsed;
        RunButton.Visibility = Visibility.Visible;
        PickButton.Visibility = larkMode ? Visibility.Collapsed : Visibility.Visible;
        RoundCornerOptions.Visibility = mode == "round" ? Visibility.Visible : Visibility.Collapsed;
        WorkspaceIcon.Glyph = mode is "lark" or "document" ? "\uE8A5" : mode == "video" ? "\uE714" : mode == "audio" ? "\uE8D6" : mode == "icon" ? "\uE8A7" : mode == "stitch" ? "\uE8B9" : "\uE91B";
        SetSelectedNavigation(mode);
    }

    private async void PickFiles_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        picker.SuggestedStartLocation = PickerLocationId.PicturesLibrary;
        foreach (var extension in SupportedExtensionsForCurrentMode())
            picker.FileTypeFilter.Add(extension);

        var selected = await picker.PickMultipleFilesAsync();
        if (selected.Count == 0) return;
        _files.Clear();
        foreach (var file in selected) _files.Add(file);
        FileList.Visibility = Visibility.Visible;
        ShowStatus(InfoBarSeverity.Informational, $"已选择 {_files.Count} 个文件。");
    }

    private void Root_DragOver(object sender, DragEventArgs e)
    {
        if (_mode == "lark")
        {
            if (e.DataView.Contains(StandardDataFormats.StorageItems))
                e.AcceptedOperation = DataPackageOperation.Copy;
            return;
        }
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
            e.AcceptedOperation = DataPackageOperation.Copy;
    }

    private async void Root_Drop(object sender, DragEventArgs e)
    {
        var items = await e.DataView.GetStorageItemsAsync();
        if (_mode == "lark")
        {
            var markdown = items.OfType<StorageFile>().FirstOrDefault(file =>
                new[] { ".md", ".markdown", ".txt" }.Contains(Path.GetExtension(file.Name), StringComparer.OrdinalIgnoreCase));
            if (markdown is null)
            {
                LarkStatus.Text = "请拖入 .md、.markdown 或 .txt 文件。";
                return;
            }
            await ProcessLarkContentAsync(await _larkService.ImportMarkdownAsync(markdown), markdown.Name, Path.GetDirectoryName(markdown.Path));
            return;
        }
        var images = items.OfType<StorageFile>()
            .Where(file => ImageProcessingService.SupportedExtensions.Contains(Path.GetExtension(file.Name), StringComparer.OrdinalIgnoreCase))
            .ToList();
        if (images.Count == 0)
        {
            ShowStatus(InfoBarSeverity.Warning, "没有可处理的图片文件。");
            return;
        }

        _files.Clear();
        foreach (var image in images) _files.Add(image);
        FileList.Visibility = Visibility.Visible;
        ShowStatus(InfoBarSeverity.Informational, $"已接收 {_files.Count} 个图片文件。");
    }

    private async void Run_Click(object sender, RoutedEventArgs e)
    {
        if (_files.Count == 0 && _mode != "lark")
        {
            ShowStatus(InfoBarSeverity.Warning, "请先选择至少一个图片文件。");
            return;
        }

        try
        {
            RunButton.IsEnabled = false;
            var output = await PickOutputFolderAsync();
            if (output is null) return;

            if (_mode == "lark")
            {
                await _documentService.ExportClipboardHtmlAsync(output);
            }
            else switch (_mode)
            {
                case "compress":
                    foreach (var file in _files) await _imageService.CompressToTargetAsync(file, output, 5_000_000);
                    break;
                case "stitch":
                    await _imageService.StitchVerticallyAsync(_files, output, "LiquidConvert-stitched.png");
                    break;
                case "round":
                    foreach (var file in _files) await _imageService.AddRoundedCornersAsync(file, output, (int)Math.Round(CornerRadiusSlider.Value));
                    break;
                case "audio":
                    foreach (var file in _files) await _mediaService.ExtractAudioAsync(file, output);
                    break;
                case "video":
                    foreach (var file in _files) await _mediaService.ConvertVideoToGifAsync(file, output);
                    break;
                case "icon":
                    foreach (var file in _files) await _iconService.CreateIcoAsync(file, output);
                    break;
                case "document":
                    foreach (var file in _files) await _documentService.ExportMarkdownAsync(file, output);
                    break;
                default:
                    foreach (var file in _files) await _imageService.ConvertToPngAsync(file, output);
                    break;
            }
            ShowStatus(InfoBarSeverity.Success, "处理完成，结果已保存到所选文件夹。");
        }
        catch (Exception ex)
        {
            ShowStatus(InfoBarSeverity.Error, $"处理失败：{ex.Message}");
        }
        finally
        {
            RunButton.IsEnabled = true;
        }
    }

    private async Task<StorageFolder?> PickOutputFolderAsync()
    {
        if (SettingsStore.DefaultOutputFolder is { Length: > 0 } path)
        {
            try { return await StorageFolder.GetFolderFromPathAsync(path); }
            catch { SettingsStore.DefaultOutputFolder = null; }
        }
        var picker = new FolderPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add("*");
        return await picker.PickSingleFolderAsync();
    }

    private void ShowStatus(InfoBarSeverity severity, string message)
    {
        StatusBar.Severity = severity;
        StatusBar.Message = message;
        StatusBar.IsOpen = true;
    }

    private async void Settings_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new SettingsDialog(WindowNative.GetWindowHandle(this)) { XamlRoot = RootLayout.XamlRoot };
        await dialog.ShowAsync();
        ApplyTheme();
        RefreshLarkLoginState();
    }

    private void ApplyTheme()
    {
        RootLayout.RequestedTheme = SettingsStore.Theme switch
        {
            "Light" => ElementTheme.Light,
            "Dark" => ElementTheme.Dark,
            _ => ElementTheme.Default
        };

        UpdateTitleBarColors();
    }

    private void UpdateTitleBarColors()
    {
        var dark = SettingsStore.Theme == "Dark" || (SettingsStore.Theme == "System" && RootLayout.ActualTheme == ElementTheme.Dark);
        var titleBar = AppWindow.TitleBar;
        titleBar.BackgroundColor = dark ? global::Windows.UI.Color.FromArgb(255, 28, 28, 28) : global::Windows.UI.Color.FromArgb(255, 248, 249, 251);
        titleBar.ForegroundColor = dark ? global::Windows.UI.Color.FromArgb(255, 244, 244, 245) : global::Windows.UI.Color.FromArgb(255, 32, 32, 32);
        titleBar.ButtonBackgroundColor = titleBar.BackgroundColor;
        titleBar.ButtonForegroundColor = titleBar.ForegroundColor;
        titleBar.ButtonHoverBackgroundColor = dark ? global::Windows.UI.Color.FromArgb(255, 62, 62, 62) : global::Windows.UI.Color.FromArgb(255, 232, 235, 239);
        titleBar.ButtonHoverForegroundColor = titleBar.ForegroundColor;
        titleBar.ButtonPressedBackgroundColor = dark ? global::Windows.UI.Color.FromArgb(255, 78, 78, 78) : global::Windows.UI.Color.FromArgb(255, 216, 220, 224);
        titleBar.ButtonPressedForegroundColor = titleBar.ForegroundColor;
    }

    private void LarkLogin_Click(object sender, RoutedEventArgs e)
    {
        var loginWindow = new LarkLoginWindow();
        loginWindow.Closed += (_, _) => RefreshLarkLoginState();
        loginWindow.Activate();
    }

    private async void LarkPaste_Click(object sender, RoutedEventArgs e)
    {
        await LoadClipboardIntoLarkAsync();
    }

    private async void LarkDropTarget_Tapped(object sender, Microsoft.UI.Xaml.Input.TappedRoutedEventArgs e) => await LoadClipboardIntoLarkAsync();

    private void LarkDropTarget_DragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.Handled = true;
        }
    }

    private async void LarkDropTarget_Drop(object sender, DragEventArgs e)
    {
        e.Handled = true;
        var file = (await e.DataView.GetStorageItemsAsync()).OfType<StorageFile>()
            .FirstOrDefault(item => new[] { ".md", ".markdown", ".txt" }.Contains(Path.GetExtension(item.Name), StringComparer.OrdinalIgnoreCase));
        if (file is null) { LarkStatus.Text = "请拖入 .md、.markdown 或 .txt 文件。"; return; }
        await ProcessLarkContentAsync(await _larkService.ImportMarkdownAsync(file), file.Name, Path.GetDirectoryName(file.Path));
    }

    private async Task LoadClipboardIntoLarkAsync()
    {
        try { await ProcessLarkContentAsync(await _larkService.ReadClipboardMarkdownAsync(), "剪贴板内容"); }
        catch (Exception ex) { LarkStatus.Text = ex.Message; }
    }

    private async Task ProcessLarkContentAsync(string markdown, string sourceName, string? baseDirectory = null)
    {
        LarkStatus.Text = "正在解析文档…";
        LarkDropTarget.Visibility = Visibility.Collapsed;
        LarkPreviewPanel.Visibility = Visibility.Visible;
        LarkPreviewLoading.Visibility = Visibility.Visible;
        LarkPreview.Opacity = 0;
        LarkActions.Visibility = Visibility.Collapsed;
        LarkPreviewSource.Text = sourceName;

        try
        {
            _larkHtml = await _larkService.ConvertMarkdownAsync(markdown, baseDirectory, message =>
                DispatcherQueue.TryEnqueue(() => { LarkStatus.Text = message; LarkLoadingText.Text = message; }));
            LarkStatus.Text = "正在生成预览…";
            LarkLoadingText.Text = "正在渲染预览…";
            await LarkPreview.EnsureCoreWebView2Async();
            LarkPreview.NavigateToString(Lark2PadService.BuildRenderedHtml(_larkHtml, RootLayout.ActualTheme == ElementTheme.Dark));
        }
        catch (Exception ex)
        {
            LarkPreviewPanel.Visibility = Visibility.Collapsed;
            LarkPreviewLoading.Visibility = Visibility.Collapsed;
            LarkDropTarget.Visibility = Visibility.Visible;
            LarkStatus.Text = $"预览生成失败：{ex.Message}";
        }
    }

    private void LarkReset_Click(object sender, RoutedEventArgs e)
    {
        _larkHtml = string.Empty;
        LarkPreviewPanel.Visibility = Visibility.Collapsed;
        LarkPreviewLoading.Visibility = Visibility.Collapsed;
        LarkActions.Visibility = Visibility.Collapsed;
        LarkDropTarget.Visibility = Visibility.Visible;
        LarkStatus.Text = "点击下方区域读取剪贴板，或将 Markdown 文件拖入。";
    }

    private async void LarkPreview_NavigationCompleted(WebView2 sender, Microsoft.Web.WebView2.Core.CoreWebView2NavigationCompletedEventArgs e)
    {
        if (!e.IsSuccess)
        {
            LarkStatus.Text = "预览页面加载失败，请重新导入。";
            return;
        }

        LarkPreviewLoading.Visibility = Visibility.Collapsed;
        await AnimateElementOpacityAsync(LarkPreview, 1, 180);
        LarkActions.Visibility = Visibility.Visible;
        LarkStatus.Text = "转换与预览已完成，请选择下方导出目标。";
    }

    private void RefreshLarkLoginState()
    {
        var loggedIn = _larkService.HasSession;
        LarkLoginStatus.Text = loggedIn ? "已登录 Etherpad" : "未登录";
        LarkLoginIndicator.Fill = new SolidColorBrush(loggedIn
            ? global::Windows.UI.Color.FromArgb(255, 16, 185, 129)
            : global::Windows.UI.Color.FromArgb(255, 148, 163, 184));
        LarkLoginButton.Content = loggedIn ? "管理登录" : "登录 Etherpad";
    }

    private async void LarkImport_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add(".md"); picker.FileTypeFilter.Add(".markdown"); picker.FileTypeFilter.Add(".txt");
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        await ProcessLarkContentAsync(await _larkService.ImportMarkdownAsync(file), file.Name, Path.GetDirectoryName(file.Path));
    }

    private void CornerRadiusSlider_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (CornerRadiusText is not null)
            CornerRadiusText.Text = $"{Math.Round(e.NewValue):0} px";
    }

    private bool EnsureLarkContent()
    {
        if (!string.IsNullOrWhiteSpace(_larkHtml)) return true;
        LarkStatus.Text = "请先读取剪贴板或导入 Markdown。";
        return false;
    }

    private void LarkCopyMarkdown_Click(object sender, RoutedEventArgs e)
    {
        if (!EnsureLarkContent()) return;
        _larkService.CopyMarkdown(_larkHtml);
        LarkStatus.Text = "Markdown 已复制到剪贴板。";
    }

    private void LarkCopyEtherpad_Click(object sender, RoutedEventArgs e)
    {
        if (!EnsureLarkContent()) return;
        _larkService.CopyEtherpadHtml(_larkHtml);
        LarkStatus.Text = "Etherpad 可编辑格式已复制，可直接粘贴到 Pad。";
    }

    private void LarkCopyWeChat_Click(object sender, RoutedEventArgs e)
    {
        if (!EnsureLarkContent()) return;
        _larkService.CopyWeChatHtml(_larkHtml);
        LarkStatus.Text = "公众号富文本已复制，可直接在公众号编辑器中粘贴。";
    }

    private async void LarkExport_Click(object sender, RoutedEventArgs e)
    {
        if (!EnsureLarkContent()) return;
        var folder = await PickOutputFolderAsync(); if (folder is null) return;
        await _larkService.ExportEtherpadHtmlAsync(_larkHtml, folder); LarkStatus.Text = "Etherpad HTML 已保存。";
    }

    private async void LarkSync_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (!EnsureLarkContent()) return;
            var url = await _larkService.SyncToPadAsync(_larkHtml);
            LarkStatus.Text = "已同步到 Pad，正在打开网页…";
            await global::Windows.System.Launcher.LaunchUriAsync(url);
        }
        catch (Exception ex) { LarkStatus.Text = ex.Message; }
    }

    private void SetSelectedNavigation(string mode)
    {
        SetNavigationAppearance(NavConvert, mode == "convert");
        SetNavigationAppearance(NavCompress, mode == "compress");
        SetNavigationAppearance(NavStitch, mode == "stitch");
        SetNavigationAppearance(NavRound, mode == "round");
        SetNavigationAppearance(NavAudio, mode == "audio");
        SetNavigationAppearance(NavVideo, mode == "video");
        SetNavigationAppearance(NavIcon, mode == "icon");
        SetNavigationAppearance(NavDocument, mode == "document");
        SetNavigationAppearance(NavLark, mode == "lark");
    }

    private void SetNavigationAppearance(Button button, bool selected)
    {
        var dark = RootLayout.ActualTheme == ElementTheme.Dark;
        button.Background = new SolidColorBrush(selected
            ? dark ? global::Windows.UI.Color.FromArgb(255, 58, 58, 58) : global::Windows.UI.Color.FromArgb(255, 232, 242, 252)
            : global::Windows.UI.Color.FromArgb(0, 0, 0, 0));
        button.Foreground = new SolidColorBrush(selected
            ? dark ? global::Windows.UI.Color.FromArgb(255, 245, 245, 245) : global::Windows.UI.Color.FromArgb(255, 15, 108, 189)
            : dark ? global::Windows.UI.Color.FromArgb(255, 232, 236, 242) : global::Windows.UI.Color.FromArgb(255, 38, 42, 48));
        button.BorderBrush = new SolidColorBrush(selected
            ? dark ? global::Windows.UI.Color.FromArgb(255, 15, 108, 189) : global::Windows.UI.Color.FromArgb(255, 15, 108, 189)
            : global::Windows.UI.Color.FromArgb(0, 0, 0, 0));
        button.BorderThickness = selected ? new Thickness(3, 0, 0, 0) : new Thickness(0);
    }

    private Task AnimateContentAsync(double opacity, double offsetY, int durationMilliseconds)
    {
        var completion = new TaskCompletionSource();
        var storyboard = new Storyboard();
        var fade = new DoubleAnimation { To = opacity, Duration = TimeSpan.FromMilliseconds(durationMilliseconds) };
        Storyboard.SetTarget(fade, ContentSurface);
        Storyboard.SetTargetProperty(fade, "Opacity");
        var translate = new DoubleAnimation { To = offsetY, Duration = TimeSpan.FromMilliseconds(durationMilliseconds) };
        Storyboard.SetTarget(translate, ContentTranslate);
        Storyboard.SetTargetProperty(translate, "Y");
        storyboard.Children.Add(fade);
        storyboard.Children.Add(translate);
        storyboard.Completed += (_, _) => completion.SetResult();
        storyboard.Begin();
        return completion.Task;
    }

    private static Task AnimateElementOpacityAsync(UIElement element, double opacity, int durationMilliseconds)
    {
        var completion = new TaskCompletionSource();
        var animation = new DoubleAnimation { To = opacity, Duration = TimeSpan.FromMilliseconds(durationMilliseconds) };
        Storyboard.SetTarget(animation, element);
        Storyboard.SetTargetProperty(animation, "Opacity");
        var storyboard = new Storyboard();
        storyboard.Children.Add(animation);
        storyboard.Completed += (_, _) => completion.SetResult();
        storyboard.Begin();
        return completion.Task;
    }

    private IEnumerable<string> SupportedExtensionsForCurrentMode() => _mode switch
    {
        "audio" or "video" => [".mp4", ".mov", ".mkv", ".webm", ".avi", ".mp3", ".m4a", ".wav", ".flac"],
        "document" => [".txt", ".md", ".markdown", ".html", ".htm"],
        "icon" => [".png", ".jpg", ".jpeg", ".bmp"],
        _ => ImageProcessingService.SupportedExtensions
    };
}
