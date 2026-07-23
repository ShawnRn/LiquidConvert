using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Security.Cryptography;
using Windows.Storage;
using Windows.Storage.Streams;

namespace LiquidConvert.Windows.Services;

/// <summary>Local-only image pipeline built on the Windows Imaging Component APIs.</summary>
public sealed class ImageProcessingService
{
    public static readonly ImageProcessingService Instance = new();
    public static readonly string[] SupportedExtensions = [".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".webp", ".heic", ".heif"];

    public async Task CompressImageAsync(StorageFile input, StorageFile output, double quality, int resizeMode, double scaleFactor, int targetWidth)
    {
        double scale = 1.0;
        if (resizeMode == 1) // Scale percentage
        {
            scale = Math.Clamp(scaleFactor, 0.05, 1.0);
        }
        else if (resizeMode == 2 && targetWidth > 0) // Fixed target width
        {
            var (w, _) = await GetDimensionsAsync(input);
            if (w > 0) scale = Math.Clamp((double)targetWidth / w, 0.05, 2.0);
        }

        using var bitmap = await LoadBitmapAsync(input, scale);
        string ext = Path.GetExtension(output.Name).ToLowerInvariant();

        if (ext is ".jpg" or ".jpeg")
        {
            using var stream = await output.OpenAsync(FileAccessMode.ReadWrite);
            await EncodeJpegAsync(bitmap, stream, quality);
        }
        else
        {
            Guid encoderId = ext switch
            {
                ".png" => BitmapEncoder.PngEncoderId,
                ".bmp" => BitmapEncoder.BmpEncoderId,
                ".tiff" => BitmapEncoder.TiffEncoderId,
                _ => BitmapEncoder.PngEncoderId
            };
            await SaveAsync(bitmap, output, encoderId);
        }
    }

    public async Task ConvertToPngAsync(StorageFile input, StorageFolder outputFolder)
    {
        using var bitmap = await LoadBitmapAsync(input);
        var output = await outputFolder.CreateFileAsync($"{Path.GetFileNameWithoutExtension(input.Name)}.png", CreationCollisionOption.GenerateUniqueName);
        await SaveAsync(bitmap, output, BitmapEncoder.PngEncoderId);
    }

    /// <summary>Applies an antialiased rounded-rectangle alpha mask and saves a transparent PNG.</summary>
    public async Task AddRoundedCornersAsync(StorageFile input, StorageFolder outputFolder, int radius)
    {
        using var bitmap = await LoadBitmapAsync(input);
        var width = bitmap.PixelWidth;
        var height = bitmap.PixelHeight;
        var cornerRadius = Math.Clamp(radius, 0, Math.Min(width, height) / 2);
        var byteCount = checked(width * height * 4);
        var buffer = new global::Windows.Storage.Streams.Buffer((uint)byteCount);
        bitmap.CopyToBuffer(buffer);
        CryptographicBuffer.CopyToByteArray(buffer, out byte[] pixels);

        if (cornerRadius > 0)
        {
            var center = cornerRadius - 0.5;
            var radiusSquared = cornerRadius * cornerRadius;
            for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                double dx = 0, dy = 0;
                if (x < cornerRadius && y < cornerRadius) { dx = center - x; dy = center - y; }
                else if (x >= width - cornerRadius && y < cornerRadius) { dx = x - (width - cornerRadius) + 0.5; dy = center - y; }
                else if (x < cornerRadius && y >= height - cornerRadius) { dx = center - x; dy = y - (height - cornerRadius) + 0.5; }
                else if (x >= width - cornerRadius && y >= height - cornerRadius) { dx = x - (width - cornerRadius) + 0.5; dy = y - (height - cornerRadius) + 0.5; }
                else continue;

                var distanceSquared = dx * dx + dy * dy;
                if (distanceSquared <= radiusSquared) continue;
                var coverage = Math.Clamp(cornerRadius + 0.5 - Math.Sqrt(distanceSquared), 0, 1);
                var offset = (y * width + x) * 4;
                for (var channel = 0; channel < 4; channel++)
                    pixels[offset + channel] = (byte)Math.Round(pixels[offset + channel] * coverage);
            }
        }

        using var rounded = SoftwareBitmap.CreateCopyFromBuffer(pixels.AsBuffer(), BitmapPixelFormat.Bgra8, width, height, BitmapAlphaMode.Premultiplied);
        var output = await outputFolder.CreateFileAsync($"{Path.GetFileNameWithoutExtension(input.Name)}-rounded.png", CreationCollisionOption.GenerateUniqueName);
        await SaveAsync(rounded, output, BitmapEncoder.PngEncoderId);
    }

    public async Task CompressToTargetAsync(StorageFile input, StorageFolder outputFolder, ulong maxBytes)
    {
        // First preserve original dimensions and lower JPEG quality. If needed, progressively scale down.
        for (var scale = 1.0; scale >= 0.35; scale -= 0.10)
        {
            using var bitmap = await LoadBitmapAsync(input, scale);
            for (var quality = 0.90; quality >= 0.30; quality -= 0.10)
            {
                using var memory = new InMemoryRandomAccessStream();
                await EncodeJpegAsync(bitmap, memory, quality);
                if (memory.Size > maxBytes) continue;

                var output = await outputFolder.CreateFileAsync(
                    $"{Path.GetFileNameWithoutExtension(input.Name)}-compressed.jpg",
                    CreationCollisionOption.GenerateUniqueName);
                using var destination = await output.OpenAsync(FileAccessMode.ReadWrite);
                memory.Seek(0);
                await RandomAccessStream.CopyAsync(memory, destination);
                await destination.FlushAsync();
                return;
            }
        }

        throw new InvalidOperationException("无法在保持基本可读性的范围内压缩到目标大小。");
    }

    public async Task StitchVerticallyAsync(IReadOnlyList<StorageFile> inputs, StorageFolder outputFolder, string fileName)
    {
        if (inputs.Count < 2) throw new InvalidOperationException("拼接至少需要两张图片。");

        var dimensions = new List<(uint Width, uint Height)>();
        foreach (var input in inputs) dimensions.Add(await GetDimensionsAsync(input));
        var width = dimensions.Min(item => item.Width);
        var bitmaps = new List<SoftwareBitmap>();

        try
        {
            foreach (var input in inputs)
                bitmaps.Add(await LoadBitmapAsync(input, width / (double)(await GetDimensionsAsync(input)).Width));

            var height = checked((int)bitmaps.Sum(item => (long)item.PixelHeight));
            var pixels = new byte[checked((int)(width * (uint)height * 4))];
            var rowOffset = 0;

            foreach (var bitmap in bitmaps)
            {
                var byteCount = checked((int)(bitmap.PixelWidth * bitmap.PixelHeight * 4));
                var buffer = new global::Windows.Storage.Streams.Buffer((uint)byteCount);
                bitmap.CopyToBuffer(buffer);
                CryptographicBuffer.CopyToByteArray(buffer, out byte[] source);
                System.Buffer.BlockCopy(source, 0, pixels, rowOffset, byteCount);
                rowOffset += byteCount;
            }

            using var stitched = SoftwareBitmap.CreateCopyFromBuffer(
                pixels.AsBuffer(), BitmapPixelFormat.Bgra8, (int)width, height, BitmapAlphaMode.Premultiplied);
            var output = await outputFolder.CreateFileAsync(fileName, CreationCollisionOption.GenerateUniqueName);
            await SaveAsync(stitched, output, BitmapEncoder.PngEncoderId);
        }
        finally
        {
            foreach (var bitmap in bitmaps) bitmap.Dispose();
        }
    }

    private static async Task<(uint Width, uint Height)> GetDimensionsAsync(StorageFile file)
    {
        using var stream = await file.OpenReadAsync();
        var decoder = await BitmapDecoder.CreateAsync(stream);
        return (decoder.PixelWidth, decoder.PixelHeight);
    }

    private static async Task<SoftwareBitmap> LoadBitmapAsync(StorageFile file, double scale = 1.0)
    {
        using var stream = await file.OpenReadAsync();
        var decoder = await BitmapDecoder.CreateAsync(stream);
        var transform = new BitmapTransform();
        if (scale < 0.999)
        {
            transform.ScaledWidth = Math.Max(1U, (uint)Math.Round(decoder.PixelWidth * scale));
            transform.ScaledHeight = Math.Max(1U, (uint)Math.Round(decoder.PixelHeight * scale));
            transform.InterpolationMode = BitmapInterpolationMode.Fant;
        }
        return await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
    }

    private static async Task SaveAsync(SoftwareBitmap bitmap, StorageFile output, Guid encoderId)
    {
        using var stream = await output.OpenAsync(FileAccessMode.ReadWrite);
        var encoder = await BitmapEncoder.CreateAsync(encoderId, stream);
        encoder.SetSoftwareBitmap(bitmap);
        await encoder.FlushAsync();
    }

    private static async Task EncodeJpegAsync(SoftwareBitmap bitmap, IRandomAccessStream stream, double quality)
    {
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, stream);
        encoder.SetSoftwareBitmap(bitmap);
        var properties = new BitmapPropertySet
        {
            ["ImageQuality"] = new BitmapTypedValue(quality, PropertyType.Double)
        };
        await encoder.BitmapProperties.SetPropertiesAsync(properties);
        await encoder.FlushAsync();
    }
}
