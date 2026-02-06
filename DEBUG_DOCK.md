# 调试Dock图标拖拽功能

## 问题
用户报告拖拽图片到Dock图标上没有自动转换为JPG。

## 调试步骤

### 1. 查看控制台日志
在Xcode中运行应用后，查看Debug Console是否有以下日志：

- `🔵 [Dock] 收到单个文件:` 或 `🔵 [Dock] 收到多个文件:`
- `🟢 [处理] 开始处理 X 个文件`
- `🟡 [过滤] 找到 X 个图片文件`
- `🚀 [启动] 开始后台转换任务`

### 2. 测试方法

1. **在Xcode中运行** (Cmd+R)
2. **保持Xcode窗口可见**（查看Console输出）
3. **拖拽一张PNG图片到Dock上的LiquidConvert图标**
4. **观察：**
   - 是否出现"开始转换"对话框
   - Console是否有日志输出
   - 是否生成JPG文件

### 3. 可能的问题

#### 问题A：事件没有触发（Console无任何日志）
**原因：** Info.plist没有正确配置或需要重新构建
**解决：**
```bash
# 在Xcode中
1. Product -> Clean Build Folder (Shift+Cmd+K)
2. 删除 DerivedData
3. 重新运行 (Cmd+R)
```

#### 问题B：收到文件但没有过滤到图片（有🔵日志，无🟡日志）
**原因：** 文件扩展名不在列表中
**解决：** 查看日志中的文件路径，确认扩展名

#### 问题C：转换失败（有所有日志但无JPG输出）
**原因：** ImageConverter.convertSilently 内部错误
**解决：** 查看ImageConverter的详细日志

### 4. 快速诊断命令

查看应用的Info.plist是否正确编译：
```bash
cd ~/Library/Developer/Xcode/DerivedData/LiquidConvert-*/Build/Products/Debug/LiquidConvert.app/Contents
cat Info.plist | grep -A 5 CFBundleDocumentTypes
```

## 预期行为

正常工作时应该看到：
1. 控制台输出完整的日志链
2. 弹出对话框显示"开始转换"
3. 在源文件同目录生成.jpg文件
4. 源文件被删除
5. 桌面右上角显示通知
