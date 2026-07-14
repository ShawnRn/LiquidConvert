namespace LiquidConvert.Windows.Services;

internal static class LarkDiagnosticLog
{
    private static readonly object SyncRoot = new();
    internal static readonly string Path = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "LiquidConvert", "lark2pad.log");

    internal static void Write(string message)
    {
        lock (SyncRoot)
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
            File.AppendAllText(Path, $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}");
        }
    }
}
