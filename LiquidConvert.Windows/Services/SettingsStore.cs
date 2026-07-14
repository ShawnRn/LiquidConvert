using System.Text.Json;

namespace LiquidConvert.Windows.Services;

/// <summary>Local JSON settings that work for both packaged and installer-based Windows builds.</summary>
public static class SettingsStore
{
    private const string ThemeKey = "settings.theme";
    private const string OutputFolderKey = "settings.output-folder";
    private static readonly object Gate = new();
    private static readonly string SettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "LiquidConvert", "settings.json");

    public static string Theme
    {
        get => Get(ThemeKey) ?? "System";
        set => Set(ThemeKey, value);
    }

    public static string? DefaultOutputFolder
    {
        get => Get(OutputFolderKey);
        set => Set(OutputFolderKey, value);
    }

    public static string? Get(string key)
    {
        lock (Gate) return Read().GetValueOrDefault(key);
    }

    public static void Set(string key, string? value)
    {
        lock (Gate)
        {
            var values = Read();
            if (string.IsNullOrWhiteSpace(value)) values.Remove(key);
            else values[key] = value;
            Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(values));
        }
    }

    public static void Remove(string key) => Set(key, null);

    private static Dictionary<string, string> Read()
    {
        try
        {
            return File.Exists(SettingsPath)
                ? JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(SettingsPath)) ?? []
                : [];
        }
        catch (JsonException) { return []; }
        catch (IOException) { return []; }
    }
}
