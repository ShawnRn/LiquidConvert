using System;
using System.IO;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using LiquidConvert.Windows.Services;

namespace LiquidConvert.Windows.Views;

public sealed partial class IconPage : Page
{
    private StorageFile? _currentFile;

    public IconPage()
    {
        InitializeComponent();
    }

    private void RadiusSlider_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (RadiusValueText != null) RadiusValueText.Text = $"{(int)e.NewValue} px";
    }

    private async void PickFile_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.MainWindowHandle);
        picker.SuggestedStartLocation = PickerLocationId.PicturesLibrary;
        picker.FileTypeFilter.Add(".png");
        picker.FileTypeFilter.Add(".jpg");
        picker.FileTypeFilter.Add(".jpeg");
        picker.FileTypeFilter.Add(".webp");

        var file = await picker.PickSingleFileAsync();
        if (file != null) SetFile(file);
    }

    private void SetFile(StorageFile file)
    {
        _currentFile = file;
        FileNameText.Text = file.Name;
        FilePathText.Text = file.Path;
        EmptyZone.Visibility = Visibility.Collapsed;
        FileCard.Visibility = Visibility.Visible;
        RunButton.IsEnabled = true;
        StatusText.Text = $"已加载图标原图: {file.Name}";
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
            if (items.Count > 0 && items[0] is StorageFile f) SetFile(f);
        }
    }

    private async void RunIcon_Click(object sender, RoutedEventArgs e)
    {
        if (_currentFile == null) return;

        var folderPicker = new FolderPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(folderPicker, App.MainWindowHandle);
        folderPicker.SuggestedStartLocation = PickerLocationId.PicturesLibrary;
        folderPicker.FileTypeFilter.Add("*");

        var folder = await folderPicker.PickSingleFolderAsync();
        if (folder == null) return;

        RunButton.IsEnabled = false;
        StatusText.Text = "正在导出图标资源包，请稍候...";

        try
        {
            int radius = (int)RadiusSlider.Value;
            int platform = PlatformCombo.SelectedIndex;

            await IconProcessingService.Instance.GenerateIconSetAsync(_currentFile, folder, radius, platform);

            StatusText.Text = $"图标生成成功！已导出至 {folder.Path}";
            var dialog = new ContentDialog
            {
                Title = "图标生成成功",
                Content = $"已成功导出图标资源包至文件夹：\n{folder.Path}",
                CloseButtonText = "确定",
                XamlRoot = XamlRoot
            };
            await dialog.ShowAsync();
        }
        catch (Exception ex)
        {
            StatusText.Text = $"生成图标失败: {ex.Message}";
        }
        finally
        {
            RunButton.IsEnabled = true;
        }
    }
}
