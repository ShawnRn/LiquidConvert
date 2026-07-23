using System;
using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using LiquidConvert.Windows.Services;
using LiquidConvert.Windows.Views;

namespace LiquidConvert.Windows;

public sealed partial class MainWindow : Window
{
    private readonly Dictionary<string, Button> _navButtons = [];
    private string _currentTag = "home";

    public MainWindow()
    {
        InitializeComponent();
        Title = "LiquidConvert";
        WindowSizeConstraint.Register(this, 1376, 936);

        RegisterNavButtons();
        UpdateUserProfileState();

        // 默认导航至主页
        NavigateToTag("home");
    }

    private void RegisterNavButtons()
    {
        _navButtons["home"] = NavHome;
        _navButtons["convert"] = NavConvert;
        _navButtons["compress"] = NavCompress;
        _navButtons["stitch"] = NavStitch;
        _navButtons["video"] = NavVideo;
        _navButtons["audio"] = NavAudio;
        _navButtons["icon"] = NavIcon;
        _navButtons["shutter"] = NavShutter;
        _navButtons["document"] = NavDocument;
        _navButtons["lark"] = NavLark;
        _navButtons["settings"] = SettingsNavButton;
    }

    public void UpdateUserProfileState()
    {
        UserNameText.Text = SettingsStore.UserName;
    }

    public void NavigateToTag(string tag)
    {
        _currentTag = tag;
        Type? pageType = tag switch
        {
            "home" => typeof(HomePage),
            "convert" => typeof(ImageCompressPage), // 可用 ImageCompressPage 或 Convert
            "compress" => typeof(ImageCompressPage),
            "stitch" => typeof(ImageStitchPage),
            "video" => typeof(VideoGifPage),
            "audio" => typeof(AudioPage),
            "icon" => typeof(IconPage),
            "shutter" => typeof(CameraShutterPage),
            "document" => typeof(AIDocumentPage),
            "lark" => typeof(Lark2PadPage),
            "settings" => typeof(SettingsPage),
            _ => typeof(HomePage)
        };

        if (pageType != null && ContentFrame.CurrentSourcePageType != pageType)
        {
            ContentFrame.Navigate(pageType);
        }

        UpdateNavSelectionUI(tag);
    }

    private void UpdateNavSelectionUI(string selectedTag)
    {
        foreach (var (tag, btn) in _navButtons)
        {
            bool isSelected = tag == selectedTag;
            btn.Opacity = isSelected ? 1.0 : 0.75;
            btn.FontWeight = isSelected ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;
        }
    }

    private void ModeButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string tag)
        {
            NavigateToTag(tag);
        }
    }

    private void ContentFrame_Navigated(object sender, Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        // 保持框架状态同步
    }

    public void Settings_Click(object sender, RoutedEventArgs e)
    {
        NavigateToTag("settings");
    }
}
