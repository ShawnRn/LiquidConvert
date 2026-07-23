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

public sealed partial class VideoGifPage : Page
{
    private StorageFile? _currentFile;

    public VideoGifPage()
    {
        InitializeComponent();
    }

    private async void PickFile_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.MainWindowHandle);
        picker.SuggestedStartLocation = PickerLocationId.VideosLibrary;
        picker.FileTypeFilter.Add(".mp4");
        picker.FileTypeFilter.Add(".mov");
        picker.FileTypeFilter.Add(".mkv");
        picker.FileTypeFilter.Add(".avi");
        picker.FileTypeFilter.Add(".webm");

        var file = await picker.PickSingleFileAsync();
        if (file != null)
        {
            SetFile(file);
        }
    }

    private void SetFile(StorageFile file)
    {
        _currentFile = file;
        FileNameText.Text = file.Name;
        FilePathText.Text = file.Path;
        EmptyZone.Visibility = Visibility.Collapsed;
        FileCard.Visibility = Visibility.Visible;
        RunButton.IsEnabled = true;
        StatusText.Text = $"已加载视频: {file.Name}";
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
                SetFile(f);
            }
        }
    }

    private async void RunGif_Click(object sender, RoutedEventArgs e)
    {
        if (_currentFile == null) return;

        int fps = FpsCombo.SelectedIndex switch
        {
            0 => 10,
            1 => 15,
            2 => 24,
            3 => 30,
            _ => 15
        };

        int width = WidthCombo.SelectedIndex switch
        {
            0 => 480,
            1 => 720,
            2 => 1080,
            _ => 720
        };

        var savePicker = new FileSavePicker();
        WinRT.Interop.InitializeWithWindow.Initialize(savePicker, App.MainWindowHandle);
        savePicker.SuggestedStartLocation = PickerLocationId.PicturesLibrary;
        savePicker.FileTypeChoices.Add("GIF 动态图片", new List<string> { ".gif" });
        savePicker.SuggestedFileName = Path.GetFileNameWithoutExtension(_currentFile.Name);

        var saveFile = await savePicker.PickSaveFileAsync();
        if (saveFile == null) return;

        RunButton.IsEnabled = false;
        StatusText.Text = "正在生成 GIF 动图，请稍候...";

        try
        {
            double startSec = StartSecBox.Value;
            double endSec = EndSecBox.Value;

            await MediaProcessingService.Instance.ProcessVideoToGifAsync(_currentFile, saveFile, fps, width, startSec, endSec);

            StatusText.Text = $"GIF 生成成功！已保存至 {saveFile.Path}";
            var dialog = new ContentDialog
            {
                Title = "GIF 生成成功",
                Content = $"已成功生成 GIF 动图：\n{saveFile.Name}",
                CloseButtonText = "确定",
                XamlRoot = XamlRoot
            };
            await dialog.ShowAsync();
        }
        catch (Exception ex)
        {
            StatusText.Text = $"GIF 生成失败: {ex.Message}";
        }
        finally
        {
            RunButton.IsEnabled = true;
        }
    }
}
