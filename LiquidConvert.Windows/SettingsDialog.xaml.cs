using LiquidConvert.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace LiquidConvert.Windows;

public sealed partial class SettingsDialog : ContentDialog
{
    private readonly nint _windowHandle;
    private readonly Lark2PadService _larkService = new();
    private bool _isInitializing = true;

    public SettingsDialog(nint windowHandle)
    {
        _windowHandle = windowHandle;
        InitializeComponent();
        ThemePicker.SelectedIndex = SettingsStore.Theme switch { "Light" => 1, "Dark" => 2, _ => 0 };
        _isInitializing = false;
        RefreshOutputFolder();
        RefreshLarkSession();
    }

    private void ThemePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isInitializing) return;
        SettingsStore.Theme = ThemePicker.SelectedIndex switch { 1 => "Light", 2 => "Dark", _ => "System" };
    }

    private async void ChooseOutputFolder_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker();
        InitializeWithWindow.Initialize(picker, _windowHandle);
        picker.FileTypeFilter.Add("*");
        var folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;
        SettingsStore.DefaultOutputFolder = folder.Path;
        RefreshOutputFolder();
    }

    private void ClearOutputFolder_Click(object sender, RoutedEventArgs e)
    {
        SettingsStore.DefaultOutputFolder = null;
        RefreshOutputFolder();
    }

    private void ClearLarkSession_Click(object sender, RoutedEventArgs e)
    {
        _larkService.ClearSession();
        RefreshLarkSession();
    }

    private void RefreshOutputFolder() => OutputFolderText.Text = SettingsStore.DefaultOutputFolder is { Length: > 0 } path ? path : "未设置（每次操作时选择输出位置）";

    private void RefreshLarkSession()
    {
        var hasSession = _larkService.HasSession;
        LarkSessionText.Text = hasSession ? "已保存 Etherpad 登录会话。" : "尚未保存 Etherpad 登录会话。";
        ClearLarkSessionButton.IsEnabled = hasSession;
    }
}
