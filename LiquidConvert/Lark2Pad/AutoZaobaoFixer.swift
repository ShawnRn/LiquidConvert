import Foundation

@MainActor
enum AutoZaobaoFixer {
    static func fixIfNeeded() async {
        let fm = FileManager.default
        let desktopPath = "/Users/shawnrain/Desktop/zaobao.txt"
        let downloadDestHTML = "/Users/shawnrain/Downloads/20260602_早报.html"
        
        guard fm.fileExists(atPath: desktopPath) else {
            print("[AutoZaobaoFixer] 未在桌面找到 zaobao.txt，跳过自动修复。")
            return
        }
        
        do {
            var htmlContent = try String(contentsOfFile: desktopPath, encoding: .utf8)
            
            // 匹配微信图片链接
            let pattern = #"https://mmbiz\.qpic\.cn/[^\s"'>]+"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            
            let nsString = htmlContent as NSString
            let matches = regex.matches(in: htmlContent, options: [], range: NSRange(location: 0, length: nsString.length))
            
            if matches.isEmpty {
                print("[AutoZaobaoFixer] zaobao.txt 中未包含微信图片链接，无需修复。")
                // 但如果 Downloads 下没有 20260602_早报.html，我们还是帮他生成一份
                if !fm.fileExists(atPath: downloadDestHTML) {
                    try htmlContent.write(toFile: downloadDestHTML, atomically: true, encoding: .utf8)
                    print("[AutoZaobaoFixer] 已将桌面 zaobao.txt 直接复制生成 20260602_早报.html")
                }
                return
            }
            
            print("[AutoZaobaoFixer] 发现 \(matches.count) 个待修复的微信图片链接，开始自动上传并替换...")
            
            var urlsToReplace: [String] = []
            for match in matches {
                let urlStr = nsString.substring(with: match.range)
                // 微信链接中的 &amp; 需要还原为 &
                let cleanURL = urlStr.replacingOccurrences(of: "&amp;", with: "&")
                if !urlsToReplace.contains(cleanURL) {
                    urlsToReplace.append(cleanURL)
                }
            }
            
            var replacedCount = 0
            for rawURL in urlsToReplace {
                print("[AutoZaobaoFixer] 正在上传微信图片: \(rawURL)")
                do {
                    // 调用 ImageUploader 上传图片到私有图床
                    let newURL = try await ImageUploader.uploadSingleImage(url: rawURL, behavior: .direct) { _, _ in }
                    print("[AutoZaobaoFixer] 上传成功，新链接: \(newURL)")
                    
                    // 在 HTML 内容中替换，注意要同时替换带有 &amp; 的原链接和普通的 & 链接
                    let ampURL = rawURL.replacingOccurrences(of: "&", with: "&amp;")
                    htmlContent = htmlContent.replacingOccurrences(of: ampURL, with: newURL)
                    htmlContent = htmlContent.replacingOccurrences(of: rawURL, with: newURL)
                    replacedCount += 1
                } catch {
                    print("[AutoZaobaoFixer] ❌ 微信图片上传失败: \(rawURL), 错误: \(error.localizedDescription)")
                }
            }
            
            if replacedCount > 0 {
                // 写入桌面 zaobao.txt 和 Downloads/20260602_早报.html
                try htmlContent.write(toFile: desktopPath, atomically: true, encoding: .utf8)
                try htmlContent.write(toFile: downloadDestHTML, atomically: true, encoding: .utf8)
                print("[AutoZaobaoFixer] 🎉 成功修复 \(replacedCount) 个图片链接，已更新 zaobao.txt 并生成 20260602_早报.html")
            }
        } catch {
            print("[AutoZaobaoFixer] ❌ 修复失败: \(error.localizedDescription)")
        }
    }
}
