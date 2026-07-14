using LiquidConvert.Windows.Services;
using Microsoft.UI.Xaml;

namespace LiquidConvert.Windows;

public sealed partial class LarkLoginWindow : Window
{
    private readonly Lark2PadService _service = new();
    public LarkLoginWindow()
    {
        InitializeComponent();
        Browser.CoreWebView2Initialized += (_, _) => Browser.Source = new Uri(Lark2PadService.RootUrl);
        _ = InitializeBrowserAsync();
    }

    private async Task InitializeBrowserAsync() => await Browser.EnsureCoreWebView2Async();

    private async void Save_Click(object sender, RoutedEventArgs e)
    {
        if (Browser.CoreWebView2 is null) return;
        var cookies = await Browser.CoreWebView2.CookieManager.GetCookiesAsync(Lark2PadService.RootUrl);
        await _service.SaveCookiesAsync(cookies.Select(cookie => new CookieRecord(cookie.Name, cookie.Value, cookie.Path)));
        Close();
    }
    private void Close_Click(object sender, RoutedEventArgs e) => Close();
}
