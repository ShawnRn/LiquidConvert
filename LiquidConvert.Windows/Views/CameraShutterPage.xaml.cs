using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using LiquidConvert.Windows.Services;

namespace LiquidConvert.Windows.Views;

public sealed partial class CameraShutterPage : Page
{
    public CameraShutterPage()
    {
        InitializeComponent();
    }

    private async void PickFiles_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.MainWindowHandle);
        picker.SuggestedStartLocation = PickerLocationId.PicturesLibrary;
        picker.FileTypeFilter.Add(".jpg");
        picker.FileTypeFilter.Add(".jpeg");
        picker.FileTypeFilter.Add(".arw");
        picker.FileTypeFilter.Add(".nef");
        picker.FileTypeFilter.Add(".cr2");
        picker.FileTypeFilter.Add(".cr3");
        picker.FileTypeFilter.Add(".raf");
        picker.FileTypeFilter.Add(".orf");
        picker.FileTypeFilter.Add(".pef");

        var file = await picker.PickSingleFileAsync();
        if (file != null)
        {
            await ProcessFileAsync(file);
        }
    }

    private async Task ProcessFileAsync(StorageFile file)
    {
        DropZone.Visibility = Visibility.Collapsed;
        ResultZone.Visibility = Visibility.Collapsed;
        LoadingZone.Visibility = Visibility.Visible;
        ReSelectButton.Visibility = Visibility.Collapsed;

        try
        {
            var result = await CameraShutterCountService.Instance.ParseAsync(file);

            CameraMakeText.Text = (result.CameraMake ?? "CAMERA").ToUpperInvariant();
            CameraModelText.Text = result.CameraModel ?? "未知相机型号";
            ShutterCountText.Text = result.ShutterCount.HasValue ? $"{result.ShutterCount.Value:N0}" : "未找到快门数";
            SerialNumberText.Text = !string.IsNullOrWhiteSpace(result.SerialNumber) ? result.SerialNumber : "无序列号记录";

            FileNameText.Text = result.FileName;
            FileSizeText.Text = result.FileSizeString;
            DateText.Text = result.DateTimeOriginal ?? "未知时间";

            ApertureText.Text = result.Aperture ?? "--";
            ShutterSpeedText.Text = result.ShutterSpeed ?? "--";
            IsoText.Text = result.Iso ?? "--";
            FocalLengthText.Text = result.FocalLength ?? "--";
            LensModelText.Text = result.LensModel ?? "未知镜头";

            if (result.EstimatedLifeMax.HasValue && result.ShutterCount.HasValue)
            {
                double pct = result.EstimatedLifePercentage ?? 0;
                double pct100 = pct * 100.0;
                LifeProgressBar.Value = pct100;
                LifeProgressText.Text = $"已用 {pct100:F1}% (标称 {result.EstimatedLifeMax.Value:N0} 次)";
            }
            else
            {
                LifeProgressBar.Value = 0;
                LifeProgressText.Text = "无法评估最大寿命";
            }

            ConfidenceText.Text = result.ShutterCount.HasValue ? "高置信度 (EXIF/MakerNote 原始解析)" : "标准 EXIF 解析 (未提取到硬件快门)";

            LoadingZone.Visibility = Visibility.Collapsed;
            ResultZone.Visibility = Visibility.Visible;
            ReSelectButton.Visibility = Visibility.Visible;
        }
        catch (Exception ex)
        {
            LoadingZone.Visibility = Visibility.Collapsed;
            DropZone.Visibility = Visibility.Visible;

            var dialog = new ContentDialog
            {
                Title = "解析失败",
                Content = $"无法分析此照片 EXIF: {ex.Message}",
                CloseButtonText = "确定",
                XamlRoot = XamlRoot
            };
            await dialog.ShowAsync();
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
            if (items.FirstOrDefault() is StorageFile file)
            {
                await ProcessFileAsync(file);
            }
        }
    }

    private void DropZone_Tapped(object sender, TappedRoutedEventArgs e)
    {
        PickFiles_Click(sender, e);
    }
}
