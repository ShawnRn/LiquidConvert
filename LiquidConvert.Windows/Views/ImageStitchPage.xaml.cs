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

public sealed class ImageStitchItem
{
    public required StorageFile File { get; set; }
    public required string Name { get; set; }
    public required string Path { get; set; }
}

public sealed partial class ImageStitchPage : Page
{
    private readonly ObservableCollection<ImageStitchItem> _items = [];

    public ImageStitchPage()
    {
        InitializeComponent();
        FileListView.ItemsSource = _items;
    }

    private void SpacingSlider_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (SpacingValueText != null) SpacingValueText.Text = $"{(int)e.NewValue} px";
    }

    private void MarginSlider_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (MarginValueText != null) MarginValueText.Text = $"{(int)e.NewValue} px";
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
            foreach (var f in files)
            {
                if (!_items.Any(x => x.Path == f.Path))
                {
                    _items.Add(new ImageStitchItem { File = f, Name = f.Name, Path = f.Path });
                }
            }
            UpdateState();
        }
    }

    private void ClearFiles_Click(object sender, RoutedEventArgs e)
    {
        _items.Clear();
        UpdateState();
    }

    private void RemoveItem_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is ImageStitchItem item)
        {
            _items.Remove(item);
            UpdateState();
        }
    }

    private void UpdateState()
    {
        EmptyState.Visibility = _items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        FileListView.Visibility = _items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ExportButton.IsEnabled = _items.Count >= 2;
        StatusText.Text = $"当前已选 {_items.Count} 张图片" + (_items.Count < 2 ? " (至少需要 2 张图片)" : " (已准备就绪)");
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
            foreach (var item in items)
            {
                if (item is StorageFile f && !_items.Any(x => x.Path == f.Path))
                {
                    _items.Add(new ImageStitchItem { File = f, Name = f.Name, Path = f.Path });
                }
            }
            UpdateState();
        }
    }

    private async void ExportStitch_Click(object sender, RoutedEventArgs e)
    {
        if (_items.Count < 2) return;

        var picker = new FileSavePicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.MainWindowHandle);
        picker.SuggestedStartLocation = PickerLocationId.PicturesLibrary;
        string ext = FormatCombo.SelectedIndex == 1 ? ".jpg" : ".png";
        picker.FileTypeChoices.Add(FormatCombo.SelectedIndex == 1 ? "JPEG 图片" : "PNG 图片", new List<string> { ext });
        picker.SuggestedFileName = $"Stitched_Image_{DateTime.Now:yyyyMMdd_HHmmss}";

        var saveFile = await picker.PickSaveFileAsync();
        if (saveFile == null) return;

        ExportButton.IsEnabled = false;
        StatusText.Text = "正在合成长图，请稍候...";

        try
        {
            var files = _items.Select(x => x.File).ToList();
            var targetFolder = await saveFile.GetParentAsync();
            string filename = saveFile.Name;

            await ImageProcessingService.Instance.StitchVerticallyAsync(files, targetFolder, filename);

            StatusText.Text = $"长图合成成功！已保存至 {saveFile.Path}";
            
            var dialog = new ContentDialog
            {
                Title = "拼接成功",
                Content = $"已成功将 {_items.Count} 张图片合成为长图：\n{saveFile.Name}",
                CloseButtonText = "确定",
                XamlRoot = XamlRoot
            };
            await dialog.ShowAsync();
        }
        catch (Exception ex)
        {
            StatusText.Text = $"拼接失败: {ex.Message}";
        }
        finally
        {
            ExportButton.IsEnabled = true;
        }
    }
}
