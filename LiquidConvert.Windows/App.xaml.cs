using Microsoft.UI.Xaml;

namespace LiquidConvert.Windows;

public partial class App : Application
{
    public static MainWindow MainWindow { get; private set; } = null!;
    public static MainWindow CurrentMainWindow => MainWindow;
    public static nint MainWindowHandle => WinRT.Interop.WindowNative.GetWindowHandle(MainWindow);

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        MainWindow = new MainWindow();
        MainWindow.Activate();
    }
}
