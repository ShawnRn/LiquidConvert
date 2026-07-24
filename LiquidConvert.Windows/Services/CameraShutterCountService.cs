using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using Windows.Graphics.Imaging;
using Windows.Storage;

namespace LiquidConvert.Windows.Services;

public sealed record CameraShutterResult(
    string FilePath,
    string FileName,
    string FileSizeString,
    string? CameraMake,
    string? CameraModel,
    int? ShutterCount,
    string? SerialNumber,
    string? LensModel,
    string? DateTimeOriginal,
    string? Aperture,
    string? ShutterSpeed,
    string? Iso,
    string? FocalLength,
    string? RawMakerNoteTag,
    string StatusMessage,
    int? EstimatedLifeMax
)
{
    public double? EstimatedLifePercentage =>
        ShutterCount.HasValue && EstimatedLifeMax.HasValue && EstimatedLifeMax.Value > 0
            ? Math.Min(1.0, (double)ShutterCount.Value / EstimatedLifeMax.Value)
            : null;
}

public sealed class CameraShutterCountService
{
    public static readonly CameraShutterCountService Instance = new();

    private CameraShutterCountService() { }

    public async Task<CameraShutterResult> ParseAsync(StorageFile file)
    {
        var fileName = file.Name;
        var basicProps = await file.GetBasicPropertiesAsync();
        var fileSizeStr = FormatFileSize((long)basicProps.Size);

        string? make = null;
        string? model = null;
        string? dateTimeOriginal = null;
        string? aperture = null;
        string? shutterSpeed = null;
        string? iso = null;
        string? focalLength = null;
        string? lensModel = null;
        string? serialNum = null;

        try
        {
            using var stream = await file.OpenAsync(FileAccessMode.Read);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            var propertiesView = decoder.BitmapProperties;

            var propertyQuery = new[]
            {
                "/app1/ifd/{ushort=271}", // Make
                "/app1/ifd/{ushort=272}", // Model
                "/app1/ifd/exif/{ushort=36867}", // DateTimeOriginal
                "/app1/ifd/exif/{ushort=33437}", // FNumber
                "/app1/ifd/exif/{ushort=33436}", // ExposureTime
                "/app1/ifd/exif/{ushort=34855}", // ISOSpeedRatings
                "/app1/ifd/exif/{ushort=37386}", // FocalLength
                "/app1/ifd/exif/{ushort=42036}", // LensModel
                "/app1/ifd/exif/{ushort=42033}"  // BodySerialNumber
            };

            var propResults = await propertiesView.GetPropertiesAsync(propertyQuery);
            if (propResults.TryGetValue("/app1/ifd/{ushort=271}", out var valMake) && valMake.Value != null)
                make = valMake.Value.ToString()?.Trim();
            if (propResults.TryGetValue("/app1/ifd/{ushort=272}", out var valModel) && valModel.Value != null)
                model = valModel.Value.ToString()?.Trim();
            if (propResults.TryGetValue("/app1/ifd/exif/{ushort=36867}", out var valDate) && valDate.Value != null)
                dateTimeOriginal = valDate.Value.ToString()?.Trim();

            if (propResults.TryGetValue("/app1/ifd/exif/{ushort=33437}", out var valF) && valF.Value is double fNum)
                aperture = $"f/{fNum:F1}";
            if (propResults.TryGetValue("/app1/ifd/exif/{ushort=33436}", out var valExp) && valExp.Value is double expTime)
            {
                shutterSpeed = expTime >= 1.0 ? $"{expTime:F1}s" : $"1/{Math.Round(1.0 / expTime)}s";
            }
            if (propResults.TryGetValue("/app1/ifd/exif/{ushort=34855}", out var valIso) && valIso.Value != null)
                iso = valIso.Value.ToString();
            if (propResults.TryGetValue("/app1/ifd/exif/{ushort=37386}", out var valFl) && valFl.Value is double flVal)
                focalLength = $"{Math.Round(flVal)}mm";
            if (propResults.TryGetValue("/app1/ifd/exif/{ushort=42036}", out var valLens) && valLens.Value != null)
                lensModel = valLens.Value.ToString()?.Trim();
            if (propResults.TryGetValue("/app1/ifd/exif/{ushort=42033}", out var valSerial) && valSerial.Value != null)
                serialNum = valSerial.Value.ToString()?.Trim();
        }
        catch
        {
        }

        int? shutterCount = null;
        string? tagInfoStr = null;
        var statusMsg = "解析成功";

        var normMake = (make ?? "").ToUpperInvariant();
        var normModel = (model ?? "").ToUpperInvariant();

        try
        {
            using var fileStream = await file.OpenStreamForReadAsync();
            byte[] buffer = new byte[Math.Min((int)fileStream.Length, 10 * 1024 * 1024)];
            int readBytes = await fileStream.ReadAsync(buffer, 0, buffer.Length);

            if (normMake.Contains("SONY"))
            {
                var sonyRes = ParseSonyShutterCount(buffer, readBytes);
                shutterCount = sonyRes.Count;
                tagInfoStr = sonyRes.TagInfo;
            }
            else if (normMake.Contains("NIKON"))
            {
                var nikonRes = ParseNikonShutterCount(buffer, readBytes);
                shutterCount = nikonRes.Count;
                tagInfoStr = nikonRes.TagInfo;
            }
            else if (normMake.Contains("FUJIFILM") || normMake.Contains("FUJI"))
            {
                var fujiRes = ParseFujiShutterCount(buffer, readBytes);
                shutterCount = fujiRes.Count;
                tagInfoStr = fujiRes.TagInfo;
            }
            else if (normMake.Contains("OLYMPUS") || normMake.Contains("OM SYSTEM"))
            {
                var olyRes = ParseOlympusShutterCount(buffer, readBytes);
                shutterCount = olyRes.Count;
                tagInfoStr = olyRes.TagInfo;
            }
            else if (normMake.Contains("CANON"))
            {
                if (shutterCount == null) statusMsg = "佳能消费级机型未在照片中公开明文快门数";
            }
            else
            {
                var fallbackSony = ParseSonyShutterCount(buffer, readBytes);
                if (fallbackSony.Count.HasValue)
                {
                    shutterCount = fallbackSony.Count;
                    tagInfoStr = fallbackSony.TagInfo;
                    if (string.IsNullOrEmpty(make)) make = "SONY";
                }
                else
                {
                    var fallbackNikon = ParseNikonShutterCount(buffer, readBytes);
                    if (fallbackNikon.Count.HasValue)
                    {
                        shutterCount = fallbackNikon.Count;
                        tagInfoStr = fallbackNikon.TagInfo;
                        if (string.IsNullOrEmpty(make)) make = "Nikon";
                    }
                }
            }
        }
        catch (Exception ex)
        {
            statusMsg = $"读取二进制节点异常: {ex.Message}";
        }

        if (shutterCount == null && statusMsg == "解析成功")
        {
            statusMsg = "未在该照片的 EXIF / MakerNotes 中找到可读取的快门数字段";
        }

        var maxLife = EstimateShutterLife(normMake, normModel);

        return new CameraShutterResult(
            file.Path, fileName, fileSizeStr, make, model, shutterCount,
            serialNum, lensModel, dateTimeOriginal, aperture, shutterSpeed, iso, focalLength,
            tagInfoStr, statusMsg, maxLife
        );
    }

    private (int? Count, string? TagInfo) ParseSonyShutterCount(byte[] buffer, int length)
    {
        byte[] p9050 = new byte[] { 0x50, 0x90 };
        int maxIndex = Math.Min(length - 60, 5 * 1024 * 1024);
        for (int i = 0; i < maxIndex; i++)
        {
            if (buffer[i] == p9050[0] && buffer[i + 1] == p9050[1])
            {
                int[] offsets = new[] { 0x003A, 0x0050, 0x0032, 0x0038, 0x0020 };
                foreach (var off in offsets)
                {
                    int valOffset = i + off;
                    if (valOffset + 4 <= length)
                    {
                        uint val = (uint)(buffer[valOffset] | (buffer[valOffset + 1] << 8) | (buffer[valOffset + 2] << 16) | (buffer[valOffset + 3] << 24));
                        if (val >= 100 && val <= 2500000)
                        {
                            return ((int)val, "Sony MakerNote (Tag 0x9050)");
                        }
                    }
                }
            }
        }

        byte[] p0846 = new byte[] { 0x46, 0x08 };
        for (int i = 0; i < maxIndex; i++)
        {
            if (buffer[i] == p0846[0] && buffer[i + 1] == p0846[1])
            {
                int valOffset = i + 32;
                if (valOffset + 4 <= length)
                {
                    uint val = (uint)(buffer[valOffset] | (buffer[valOffset + 1] << 8) | (buffer[valOffset + 2] << 16) | (buffer[valOffset + 3] << 24));
                    if (val >= 100 && val <= 2500000)
                    {
                        return ((int)val, "Sony FocusInfo (Tag 0x0846)");
                    }
                }
            }
        }

        return (null, null);
    }

    private (int? Count, string? TagInfo) ParseNikonShutterCount(byte[] buffer, int length)
    {
        var mechCount = FindUInt32Tag(buffer, length, new byte[] { 0x37, 0x00 }, new byte[] { 0x00, 0x37 });
        if (mechCount.HasValue)
        {
            return (mechCount, "Nikon MakerNote (Tag 0x0037)");
        }
        var totalCount = FindUInt32Tag(buffer, length, new byte[] { 0xA7, 0x00 }, new byte[] { 0x00, 0xA7 });
        return totalCount.HasValue ? (totalCount, "Nikon MakerNote (Tag 0x00a7)") : (null, null);
    }

    private (int? Count, string? TagInfo) ParseFujiShutterCount(byte[] buffer, int length)
    {
        var count = FindUInt32Tag(buffer, length, new byte[] { 0x38, 0x14 }, new byte[] { 0x14, 0x38 });
        return count.HasValue ? (count, "Fujifilm MakerNote (Tag 0x1438)") : (null, null);
    }

    private (int? Count, string? TagInfo) ParseOlympusShutterCount(byte[] buffer, int length)
    {
        var count = FindUInt32Tag(buffer, length, new byte[] { 0x0A, 0x01 }, new byte[] { 0x01, 0x0A });
        return count.HasValue ? (count, "Olympus Equipment (Tag 0x010a)") : (null, null);
    }

    private int? FindUInt32Tag(byte[] buffer, int length, byte[] tagIDLE, byte[] tagIDBE)
    {
        int maxIndex = Math.Min(length - 12, 5 * 1024 * 1024);
        for (int i = 0; i < maxIndex; i += 2)
        {
            byte b0 = buffer[i];
            byte b1 = buffer[i + 1];
            bool isLE = (b0 == tagIDLE[0] && b1 == tagIDLE[1]);
            bool isBE = (b0 == tagIDBE[0] && b1 == tagIDBE[1]);

            if (isLE || isBE)
            {
                ushort typeVal = isLE
                    ? (ushort)(buffer[i + 2] | (buffer[i + 3] << 8))
                    : (ushort)((buffer[i + 2] << 8) | buffer[i + 3]);

                if (typeVal == 3 || typeVal == 4)
                {
                    uint countVal = isLE
                        ? (uint)(buffer[i + 8] | (buffer[i + 9] << 8) | (buffer[i + 10] << 16) | (buffer[i + 11] << 24))
                        : (uint)((buffer[i + 8] << 24) | (buffer[i + 9] << 16) | (buffer[i + 10] << 8) | buffer[i + 11]);

                    if (countVal > 0 && countVal < 3000000)
                    {
                        return (int)countVal;
                    }
                }
            }
        }
        return null;
    }

    private int? EstimateShutterLife(string make, string model)
    {
        if (make.Contains("SONY"))
        {
            if (model.Contains("A1") || model.Contains("A9") || model.Contains("7R")) return 500000;
            return 200000;
        }
        if (make.Contains("NIKON"))
        {
            if (model.Contains("Z 9") || model.Contains("Z9") || model.Contains("D6")) return 500000;
            return 200000;
        }
        return 150000;
    }

    private static string FormatFileSize(long bytes)
    {
        string[] suf = { "B", "KB", "MB", "GB" };
        if (bytes == 0) return "0 B";
        int place = Convert.ToInt32(Math.Floor(Math.Log(bytes, 1024)));
        double num = Math.Round(bytes / Math.Pow(1024, place), 1);
        return $"{num} {suf[place]}";
    }
}
