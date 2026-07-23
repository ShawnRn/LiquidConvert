using System.Diagnostics;
using Windows.Storage;

namespace LiquidConvert.Windows.Services;

/// <summary>Local FFmpeg wrapper for audio extraction and video-to-GIF conversion.</summary>
public sealed class MediaProcessingService
{
    public static readonly MediaProcessingService Instance = new();

    public async Task ProcessAudioAsync(StorageFile input, StorageFile output, string format, string bitrate, double startSec, double endSec)
    {
        string codec = format.ToLowerInvariant() switch
        {
            "mp3" => "-c:a libmp3lame",
            "wav" => "-c:a pcm_s16le",
            "flac" => "-c:a flac",
            "aac" => "-c:a aac",
            "m4a" => "-c:a aac",
            _ => "-c:a aac"
        };

        string timeArgs = "";
        if (startSec > 0) timeArgs += $" -ss {startSec:F1}";
        if (endSec > startSec) timeArgs += $" -to {endSec:F1}";

        await RunFfmpegAsync($"-y{timeArgs} -i \"{input.Path}\" -vn {codec} -b:a {bitrate} \"{output.Path}\"");
    }

    public async Task ProcessVideoToGifAsync(StorageFile input, StorageFile output, int fps, int width, double startSec, double endSec)
    {
        string timeArgs = "";
        if (startSec > 0) timeArgs += $" -ss {startSec:F1}";
        if (endSec > startSec) timeArgs += $" -to {endSec:F1}";

        string scaleArg = width > 0 ? $"scale={width}:-1:flags=lanczos" : "scale=720:-1:flags=lanczos";
        await RunFfmpegAsync($"-y{timeArgs} -i \"{input.Path}\" -vf \"fps={fps},{scaleArg}\" \"{output.Path}\"");
    }

    public async Task ExtractAudioAsync(StorageFile input, StorageFolder outputFolder)
    {
        var output = await outputFolder.CreateFileAsync($"{Path.GetFileNameWithoutExtension(input.Name)}.m4a", CreationCollisionOption.GenerateUniqueName);
        await RunFfmpegAsync($"-y -i \"{input.Path}\" -vn -c:a aac -b:a 192k \"{output.Path}\"");
    }

    public async Task ConvertVideoToGifAsync(StorageFile input, StorageFolder outputFolder)
    {
        var output = await outputFolder.CreateFileAsync($"{Path.GetFileNameWithoutExtension(input.Name)}.gif", CreationCollisionOption.GenerateUniqueName);
        await RunFfmpegAsync($"-y -i \"{input.Path}\" -vf \"fps=15,scale=720:-1:flags=lanczos\" \"{output.Path}\"");
    }

    private static async Task RunFfmpegAsync(string arguments)
    {
        var executable = FindFfmpeg();
        if (executable is null)
            throw new InvalidOperationException("未找到 FFmpeg 环境。请安装 FFmpeg 并将其添加到系统 PATH 中。");

        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = executable,
                Arguments = arguments,
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardError = true,
                RedirectStandardOutput = true
            }
        };
        process.Start();
        var error = await process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        if (process.ExitCode != 0) throw new InvalidOperationException(error.Trim());
    }

    private static string? FindFfmpeg()
    {
        var names = new[] { "ffmpeg.exe", "ffmpeg" };
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? string.Empty).Split(Path.PathSeparator))
        {
            foreach (var name in names)
            {
                var candidate = Path.Combine(directory.Trim(), name);
                if (File.Exists(candidate)) return candidate;
            }
        }
        return null;
    }
}
