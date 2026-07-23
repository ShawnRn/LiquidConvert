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

public sealed partial class AudioPage : Page
{
    private StorageFile? _currentFile;

    public AudioPage()
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
        picker.FileTypeFilter.Add(".mp3");
        picker.FileTypeFilter.Add(".wav");
        picker.FileTypeFilter.Add(".aac");
        picker.FileTypeFilter.Add(".flac");
        picker.FileTypeFilter.Add(".m4a");

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
        StatusText.Text = $"已加载文件: {file.Name}";
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

    private async void RunConvert_Click(object sender, RoutedEventArgs e)
    {
        if (_currentFile == null) return;

        string format = FormatCombo.SelectedIndex switch
        {
            1 => "aac",
            2 => "wav",
            3 => "flac",
            4 => "m4a",
            _ => "mp3"
        };

        string bitrate = BitrateCombo.SelectedIndex switch
        {
            0 => "128k",
            1 => "192k",
            2 => "256k",
            3 => "320k",
            _ => "256k"
        };

        var savePicker = new FileSavePicker();
        WinRT.Interop.InitializeWithWindow.Initialize(savePicker, App.MainWindowHandle);
        savePicker.SuggestedStartLocation = PickerLocationId.MusicLibrary;
        savePicker.FileTypeChoices.Add($"{format.ToUpperInvariant()} 音频文件", new List<string> { $".{format}" });
        savePicker.SuggestedFileName = Path.GetFileNameWithoutExtension(_currentFile.Name);

        var saveFile = await savePicker.PickSaveFileAsync();
        if (saveFile == null) return;

        RunButton.IsEnabled = false;
        StatusText.Text = "正在进行音频提取与转码...";

        try
        {
            double startSec = StartSecBox.Value;
            double endSec = EndSecBox.Value;

            await MediaProcessingService.Instance.ProcessAudioAsync(_currentFile, saveFile, format, bitrate, startSec, endSec);

            StatusText.Text = $"音频处理成功！已保存至 {saveFile.Path}";
            var dialog = new ContentDialog
            {
                Title = "音频处理成功",
                Content = $"已成功导出音频：\n{saveFile.Name}",
                CloseButtonText = "确定",
                XamlRoot = XamlRoot
            };
            await dialog.ShowAsync();
        }
        catch (Exception ex)
        {
            StatusText.Text = $"音频转换失败: {ex.Message}";
        }
        finally
        {
            RunButton.IsEnabled = true;
        }
    }
}
