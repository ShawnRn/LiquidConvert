using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using LiquidConvert.Windows.Services;

namespace LiquidConvert.Windows.Views;

public sealed partial class SettingsPage : Page
{
    private bool _isInitializing = true;

    public SettingsPage()
    {
        InitializeComponent();
        Loaded += SettingsPage_Loaded;
    }

    private void SettingsPage_Loaded(object sender, RoutedEventArgs e)
    {
        _isInitializing = true;

        UserNameBox.Text = SettingsStore.UserName;
        OutputFolderBox.Text = SettingsStore.DefaultOutputFolder ?? "";
        PadIdBox.Text = SettingsStore.PadId;
        CmsEndpointBox.Text = SettingsStore.CmsEndpoint;
        AutoFormatToggle.IsOn = SettingsStore.AutoFormat;

        ThemeCombo.SelectedIndex = SettingsStore.Theme switch
        {
            "Light" => 1,
            "Dark" => 2,
            _ => 0
        };

        _isInitializing = false;
    }

    private void UserNameBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_isInitializing) return;
        SettingsStore.UserName = UserNameBox.Text;
        if (App.CurrentMainWindow is MainWindow mainWin)
        {
            mainWin.UpdateUserProfileState();
        }
    }

    private void ThemeCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isInitializing) return;
        string theme = ThemeCombo.SelectedIndex switch
        {
            1 => "Light",
            2 => "Dark",
            _ => "System"
        };
        SettingsStore.Theme = theme;
    }

    private async void BrowseOutputFolder_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.MainWindowHandle);
        picker.SuggestedStartLocation = PickerLocationId.PicturesLibrary;
        picker.FileTypeFilter.Add("*");

        var folder = await picker.PickSingleFolderAsync();
        if (folder != null)
        {
            SettingsStore.DefaultOutputFolder = folder.Path;
            OutputFolderBox.Text = folder.Path;
        }
    }

    private void PadIdBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_isInitializing) return;
        SettingsStore.PadId = PadIdBox.Text;
    }

    private void CmsEndpointBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_isInitializing) return;
        SettingsStore.CmsEndpoint = CmsEndpointBox.Text;
    }

    private void AutoFormatToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_isInitializing) return;
        SettingsStore.AutoFormat = AutoFormatToggle.IsOn;
    }
}
