using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using LiquidConvert.Windows.Services;

namespace LiquidConvert.Windows.Views;

public sealed partial class AIDocumentPage : Page
{
    private StorageFile? _currentFile;

    public AIDocumentPage()
    {
        InitializeComponent();
    }

    private async void PickFile_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.MainWindowHandle);
        picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
        picker.FileTypeFilter.Add(".txt");
        picker.FileTypeFilter.Add(".md");
        picker.FileTypeFilter.Add(".markdown");
        picker.FileTypeFilter.Add(".html");
        picker.FileTypeFilter.Add(".htm");
        picker.FileTypeFilter.Add(".png");
        picker.FileTypeFilter.Add(".jpg");
        picker.FileTypeFilter.Add(".pdf");

        var file = await picker.PickSingleFileAsync();
        if (file != null)
        {
            await ProcessFileAsync(file);
        }
    }

    private async Task ProcessFileAsync(StorageFile file)
    {
        _currentFile = file;
        StatusText.Text = $"正在处理并提取 Markdown 内容 ({file.Name})...";

        try
        {
            string md = await DocumentProcessingService.Instance.ExtractDocumentMarkdownAsync(file);
            MarkdownResultBox.Text = md;
            DocTitleText.Text = file.Name;

            EmptyZone.Visibility = Visibility.Collapsed;
            ResultZone.Visibility = Visibility.Visible;
            SaveButton.IsEnabled = true;
            StatusText.Text = $"提取完成！字符数: {md.Length}";
        }
        catch (Exception ex)
        {
            StatusText.Text = $"解析失败: {ex.Message}";
        }
    }

    private void Reset_Click(object sender, RoutedEventArgs e)
    {
        _currentFile = null;
        ResultZone.Visibility = Visibility.Collapsed;
        EmptyZone.Visibility = Visibility.Visible;
        SaveButton.IsEnabled = false;
        StatusText.Text = "准备就绪，等待导入文档。";
    }

    private void CopyMarkdown_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(MarkdownResultBox.Text)) return;
        var dp = new DataPackage();
        dp.SetText(MarkdownResultBox.Text);
        Clipboard.SetContent(dp);
        StatusText.Text = "Markdown 内容已成功复制到剪贴板！";
    }

    private async void SaveMarkdown_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(MarkdownResultBox.Text) || _currentFile == null) return;

        var picker = new FileSavePicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.MainWindowHandle);
        picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
        picker.FileTypeChoices.Add("Markdown 文档", new List<string> { ".md" });
        picker.SuggestedFileName = Path.GetFileNameWithoutExtension(_currentFile.Name);

        var saveFile = await picker.PickSaveFileAsync();
        if (saveFile != null)
        {
            await FileIO.WriteTextAsync(saveFile, MarkdownResultBox.Text);
            StatusText.Text = $"已导出 Markdown 至 {saveFile.Path}";
        }
    }

    private void DropZone_DragOver(object sender, DragEventArgs e)
    {
        e.AcceptedOperation = DataPackageOperation.Copy;
    }

    private async void DropZone_Drop(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            var items = await e.DataView.GetStorageItemsAsync();
            if (items.Count > 0 && items[0] is StorageFile f)
            {
                await ProcessFileAsync(f);
            }
        }
    }
}
