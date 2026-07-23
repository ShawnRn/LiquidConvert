using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace LiquidConvert.Windows.Services;

/// <summary>Creates a modern PNG-backed Windows ICO from a source bitmap.</summary>
public sealed class IconProcessingService
{
    public static readonly IconProcessingService Instance = new();

    public async Task GenerateIconSetAsync(StorageFile input, StorageFolder outputFolder, int cornerRadius, int targetPlatform)
    {
        // 目标平台: 0 = Windows ICO, 1 = 多尺寸 PNG 资源包, 2 = iOS / Android 图标集
        if (targetPlatform == 0)
        {
            await CreateIcoAsync(input, outputFolder);
            return;
        }

        int[] sizes = targetPlatform == 2
            ? [20, 29, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180, 1024]
            : [16, 32, 48, 64, 128, 256, 512, 1024];

        foreach (var sz in sizes)
        {
            using var inputStream = await input.OpenReadAsync();
            var decoder = await BitmapDecoder.CreateAsync(inputStream);
            var transform = new BitmapTransform { ScaledWidth = (uint)sz, ScaledHeight = (uint)sz, InterpolationMode = BitmapInterpolationMode.Fant };
            using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);

            var outFile = await outputFolder.CreateFileAsync($"icon_{sz}x{sz}.png", CreationCollisionOption.GenerateUniqueName);
            using var outStream = await outFile.OpenAsync(FileAccessMode.ReadWrite);
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, outStream);
            encoder.SetSoftwareBitmap(bitmap);
            await encoder.FlushAsync();
        }
    }

    public async Task CreateIcoAsync(StorageFile input, StorageFolder outputFolder)
    {
        using var inputStream = await input.OpenReadAsync();
        var decoder = await BitmapDecoder.CreateAsync(inputStream);
        var transform = new BitmapTransform { ScaledWidth = 256, ScaledHeight = 256, InterpolationMode = BitmapInterpolationMode.Fant };
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
        using var pngStream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, pngStream);
        encoder.SetSoftwareBitmap(bitmap);
        await encoder.FlushAsync();
        pngStream.Seek(0);
        var reader = new DataReader(pngStream);
        await reader.LoadAsync((uint)pngStream.Size);
        var png = new byte[checked((int)pngStream.Size)];
        reader.ReadBytes(png);

        var output = await outputFolder.CreateFileAsync($"{Path.GetFileNameWithoutExtension(input.Name)}.ico", CreationCollisionOption.GenerateUniqueName);
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)1);
        writer.Write((byte)0); writer.Write((byte)0); writer.Write((byte)0); writer.Write((byte)0);
        writer.Write((ushort)1); writer.Write((ushort)32); writer.Write(png.Length); writer.Write(22);
        writer.Write(png);
        await FileIO.WriteBytesAsync(output, stream.ToArray());
    }
}
