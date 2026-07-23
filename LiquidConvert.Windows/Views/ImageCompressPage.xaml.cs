using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using LiquidConvert.Windows.Services;

namespace LiquidConvert.Windows.Views;

public sealed class ImageCompressItem
{
    public required StorageFile File { get; set; }
    public required string Name { get; set; }
    public required string Path { get; set; }
    public long OriginalSizeBytes { get; set; }
    public string OriginalSizeStr => FormatBytes(OriginalSizeBytes);
    public long CompressedSizeBytes { get; set; }
    public string CompressedSizeStr => CompressedSizeBytes > 0 ? FormatBytes(CompressedSizeBytes) : "--";
    public string StatusStr { get; set; } = "等待处理";

    private static string FormatBytes(long bytes)
    {
        if (bytes < 1024) return $"{bytes} B";
        if (bytes < 1024 * 1024) return $"{bytes / 1024.0:F1} KB";
        return $"{bytes / (1024.0 * 1024.0):F2} MB";
    }
}

public sealed partial class ImageCompressPage : Page
{
    private readonly ObservableCollection<ImageCompressItem> _items = [];

    public ImageCompressPage()
    {
        InitializeComponent();
        FileListView.ItemsSource = _items;
    }

    private void QualitySlider_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (QualityValueText != null)
        {
            QualityValueText.Text = $"{(int)e.NewValue}%";
        }
    }

    private void ScaleSlider_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (ScaleValueText != null)
        {
            ScaleValueText.Text = $"{(int)e.NewValue}%";
        }
    }

    private void ResizeModeCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ScaleOptionPanel == null || WidthOptionPanel == null) return;
        ScaleOptionPanel.Visibility = ResizeModeCombo.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed;
        WidthOptionPanel.Visibility = ResizeModeCombo.SelectedIndex == 2 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void AddFiles_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.MainWindowHandle);
        picker.SuggestedStartLocation = PickerLocationId.PicturesLibrary;
        picker.FileTypeFilter.Add(".jpg");
        picker.FileTypeFilter.Add(".jpeg");
        picker.FileTypeFilter.Add(".png");
        picker.FileTypeFilter.Add(".webp");
        picker.FileTypeFilter.Add(".bmp");

        var files = await picker.PickMultipleFilesAsync();
        if (files != null && files.Count > 0)
        {
            await AddStorageFilesAsync(files);
        }
    }

    private async Task AddStorageFilesAsync(IEnumerable<IStorageItem> items)
    {
        foreach (var item in items)
        {
            if (item is StorageFile file && !_items.Any(x => x.Path == file.Path))
            {
                var props = await file.GetBasicPropertiesAsync();
                _items.Add(new ImageCompressItem
                {
                    File = file,
                    Name = file.Name,
                    Path = file.Path,
                    OriginalSizeBytes = (long)props.Size
                });
            }
        }

        UpdateListState();
    }

    private void ClearFiles_Click(object sender, RoutedEventArgs e)
    {
        _items.Clear();
        UpdateListState();
    }

    private void UpdateListState()
    {
        EmptyState.Visibility = _items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        FileListView.Visibility = _items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        StartCompressButton.IsEnabled = _items.Count > 0;
        StatusSummaryText.Text = _items.Count > 0 ? $"已添加 {_items.Count} 张图片" : "列表为空，等待添加文件...";
    }

    private void FileList_DragOver(object sender, DragEventArgs e)
    {
        e.AcceptedOperation = DataPackageOperation.Copy;
    }

    private async void FileList_Drop(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            var items = await e.DataView.GetStorageItemsAsync();
            await AddStorageFilesAsync(items);
        }
    }

    private async void StartCompress_Click(object sender, RoutedEventArgs e)
    {
        var folderPicker = new FolderPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(folderPicker, App.MainWindowHandle);
        folderPicker.SuggestedStartLocation = PickerLocationId.PicturesLibrary;
        folderPicker.FileTypeFilter.Add("*");

        var folder = await folderPicker.PickSingleFolderAsync();
        if (folder == null) return;

        StartCompressButton.IsEnabled = false;
        double quality = QualitySlider.Value / 100.0;
        int modeIndex = ResizeModeCombo.SelectedIndex;
        double scale = ScaleSlider.Value / 100.0;
        int targetWidth = (int)TargetWidthBox.Value;
        int formatIndex = FormatCombo.SelectedIndex;

        int processed = 0;
        foreach (var item in _items)
        {
            item.StatusStr = "压缩中...";
            FileListView.ItemsSource = null;
            FileListView.ItemsSource = _items;

            try
            {
                string ext = formatIndex switch
                {
                    1 => ".jpg",
                    2 => ".png",
                    3 => ".webp",
                    _ => Path.GetExtension(item.Name)
                };

                string outName = Path.GetFileNameWithoutExtension(item.Name) + "_min" + ext;
                StorageFile outFile = await folder.CreateFileAsync(outName, CreationCollisionOption.GenerateUniqueName);

                await ImageProcessingService.Instance.CompressImageAsync(item.File, outFile, quality, modeIndex, scale, targetWidth);

                var outProps = await outFile.GetBasicPropertiesAsync();
                item.CompressedSizeBytes = (long)outProps.Size;
                item.StatusStr = "已完成";
                processed++;
            }
            catch
            {
                item.StatusStr = "失败";
            }

            FileListView.ItemsSource = null;
            FileListView.ItemsSource = _items;
        }

        StartCompressButton.IsEnabled = true;
        StatusSummaryText.Text = $"处理完成！已保存 {processed} 个压缩文件至指定文件夹。";
    }
}
