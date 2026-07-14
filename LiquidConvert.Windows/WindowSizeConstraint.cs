using System.Runtime.InteropServices;
using Windows.Graphics;

namespace LiquidConvert.Windows;

internal static class WindowSizeConstraint
{
    private const uint WmGetMinMaxInfo = 0x0024;
    private const uint SubclassId = 1;
    private static SizeInt32 _minimumSize;
    private static readonly SubclassProc Callback = WindowProcedure;

    public static void Attach(nint windowHandle, SizeInt32 minimumSize)
    {
        _minimumSize = minimumSize;
        if (!SetWindowSubclass(windowHandle, Callback, SubclassId, 0))
            throw new InvalidOperationException("Unable to apply the minimum window size.");
    }

    private static nint WindowProcedure(nint windowHandle, uint message, nint wParam, nint lParam, nuint subclassId, nuint referenceData)
    {
        if (message == WmGetMinMaxInfo)
        {
            var info = Marshal.PtrToStructure<MinMaxInfo>(lParam);
            info.MinimumTrackSize = new Point { X = _minimumSize.Width, Y = _minimumSize.Height };
            Marshal.StructureToPtr(info, lParam, false);
        }
        return DefSubclassProc(windowHandle, message, wParam, lParam);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MinMaxInfo
    {
        public Point Reserved;
        public Point MaximumSize;
        public Point MaximumPosition;
        public Point MinimumTrackSize;
        public Point MaximumTrackSize;
    }

    private delegate nint SubclassProc(nint windowHandle, uint message, nint wParam, nint lParam, nuint subclassId, nuint referenceData);

    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowSubclass(nint windowHandle, SubclassProc callback, uint subclassId, nuint referenceData);

    [DllImport("comctl32.dll")]
    private static extern nint DefSubclassProc(nint windowHandle, uint message, nint wParam, nint lParam);
}
