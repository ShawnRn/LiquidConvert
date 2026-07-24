using System.Text.Json;

namespace LiquidConvert.Windows.Services;

/// <summary>Local JSON settings that work for both packaged and installer-based Windows builds.</summary>
public static class SettingsStore
{
    private const string ThemeKey = "settings.theme";
    private const string OutputFolderKey = "settings.output-folder";
    private const string UserNameKey = "settings.user-name";
    private const string CustomAvatarKey = "settings.custom-avatar";
    private const string LarkServerKey = "settings.lark-server";
    private const string EtherpadTokenKey = "settings.etherpad-token";
    private const string PadIdKey = "settings.pad-id";
    private const string CmsEndpointKey = "settings.cms-endpoint";
    private const string AutoFormatKey = "settings.auto-format";
    private const string LarkAutoUploadKey = "settings.lark-auto-upload";
    private const string LarkRoundImagesKey = "settings.lark-round-images";
    private const string LarkAddHeaderKey = "settings.lark-add-header";
    private const string LarkAddFooterKey = "settings.lark-add-footer";
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

    public static string UserName
    {
        get => Get(UserNameKey) ?? "UserName";
        set => Set(UserNameKey, value);
    }

    public static string? CustomAvatar
    {
        get => Get(CustomAvatarKey);
        set => Set(CustomAvatarKey, value);
    }

    public static string LarkServer
    {
        get => Get(LarkServerKey) ?? "https://pad.0x001.net";
        set => Set(LarkServerKey, value);
    }

    public static string EtherpadToken
    {
        get => Get(EtherpadTokenKey) ?? "";
        set => Set(EtherpadTokenKey, value);
    }

    public static string PadId
    {
        get => Get(PadIdKey) ?? "";
        set => Set(PadIdKey, value);
    }

    public static string CmsEndpoint
    {
        get => Get(CmsEndpointKey) ?? "";
        set => Set(CmsEndpointKey, value);
    }

    public static bool AutoFormat
    {
        get => Get(AutoFormatKey) != "false";
        set => Set(AutoFormatKey, value ? "true" : "false");
    }

    public static bool LarkAutoUpload
    {
        get => Get(LarkAutoUploadKey) != "false";
        set => Set(LarkAutoUploadKey, value ? "true" : "false");
    }

    public static bool LarkRoundImages
    {
        get => Get(LarkRoundImagesKey) != "false";
        set => Set(LarkRoundImagesKey, value ? "true" : "false");
    }

    public static bool LarkAddHeader
    {
        get => Get(LarkAddHeaderKey) != "false";
        set => Set(LarkAddHeaderKey, value ? "true" : "false");
    }

    public static bool LarkAddFooter
    {
        get => Get(LarkAddFooterKey) != "false";
        set => Set(LarkAddFooterKey, value ? "true" : "false");
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
