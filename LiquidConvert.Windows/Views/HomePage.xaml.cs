using System.Collections.Generic;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LiquidConvert.Windows.Views;

public sealed record QuickToolItem(
    string Tag,
    string Title,
    string Description,
    string Glyph
);

public sealed partial class HomePage : Page
{
    public HomePage()
    {
        InitializeComponent();
        LoadQuickTools();
    }

    private void LoadQuickTools()
    {
        var tools = new List<QuickToolItem>
        {
            new("convert", "图片转换", "支持 PNG, JPEG, WebP, HEIC 等常用格式双向互转。", "\uE8AB"),
            new("compress", "图片压缩", "智能有损/无损压缩，体积骤减，支持按比例缩放。", "\uE91B"),
            new("stitch", "图片拼接", "长图拼接、网格拼图，自定义边距、圆角与背景色。", "\uE8B9"),
            new("video", "视频 GIF", "视频片段截取与转高清 GIF，控制 FPS 与分辨率。", "\uE714"),
            new("audio", "音频转换", "视频分离音频、格式转换、比特率与范围剪辑。", "\uE8D6"),
            new("icon", "图标转换", "生成 Windows ICO, macOS ICNS, iOS & Android 图标包。", "\uE8A7"),
            new("shutter", "快门检测", "相机 EXIF & MakerNote 解析，快门次数与寿命评估。", "\uE722"),
            new("document", "AI 文档提取", "智能解析图片/PDF，一键提取 Markdown 与表格。", "\uE8A5"),
            new("lark", "Lark2Pad", "飞书富文本/Markdown 转换，公众号排版与 Pad 同步。", "\uE8A5")
        };

        QuickToolsGrid.ItemsSource = tools;
    }

    private void QuickToolsGrid_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is QuickToolItem item && App.CurrentMainWindow is MainWindow mainWin)
        {
            mainWin.NavigateToTag(item.Tag);
        }
    }

    private void Card_PointerEntered(object sender, PointerRoutedEventArgs e)
    {
        if (sender is Border border)
        {
            border.Translation = new System.Numerics.Vector3(0, -2, 0);
        }
    }

    private void Card_PointerExited(object sender, PointerRoutedEventArgs e)
    {
        if (sender is Border border)
        {
            border.Translation = new System.Numerics.Vector3(0, 0, 0);
        }
    }
}
