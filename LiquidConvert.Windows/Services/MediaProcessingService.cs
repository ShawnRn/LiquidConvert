using System.Diagnostics;
using Windows.Storage;

namespace LiquidConvert.Windows.Services;

/// <summary>Local FFmpeg wrapper for audio extraction and video-to-GIF conversion.</summary>
public sealed class MediaProcessingService
{
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
            throw new InvalidOperationException("未找到 FFmpeg。请安装 FFmpeg 并重新启动 LiquidConvert。");

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
