//
//  CameraShutterCountView.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//

import SwiftUI
import UniformTypeIdentifiers
import MapKit

struct CameraShutterCountView: View {
    @State private var isTargeted = false
    @State private var results: [CameraShutterResult] = []
    @State private var selectedResultID: UUID? = nil
    @State private var isProcessing = false
    @State private var currentProcessingIndex = 0
    @State private var totalProcessingCount = 0
    
    var selectedResult: CameraShutterResult? {
        if let id = selectedResultID {
            return results.first(where: { $0.id == id })
        }
        return results.first
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏 Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("EXIF 信息摘要")
                            .font(.system(size: 22, weight: .bold))
                        
                        Text("Shutter Count")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.12))
                            .foregroundColor(.blue)
                            .clipShape(Capsule())
                    }
                    Text("相机型号、机械快门数及核心 EXIF 拍摄参数检测")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if !results.isEmpty {
                    Button(action: selectFiles) {
                        Label("检测其他照片", systemImage: "photo.badge.plus")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            Divider()
                .opacity(0.3)
            
            // 主内容区
            if isProcessing {
                VStack(spacing: 16) {
                    ProgressView(value: Double(currentProcessingIndex), total: Double(max(1, totalProcessingCount)))
                        .progressViewStyle(.linear)
                        .frame(width: 280)
                    
                    Text("正在深入提取 EXIF 与 MakerNote 硬件数据 (\(currentProcessingIndex)/\(totalProcessingCount))...")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                // 空状态/拖拽上传区
                dropZoneView
            } else {
                // 结果展示面板
                resultDetailView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - 拖拽区
    private var dropZoneView: some View {
        VStack(spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(isTargeted ? Color.blue.opacity(0.08) : Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(
                                isTargeted ? Color.blue : Color.primary.opacity(0.12),
                                style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: isTargeted ? [] : [8, 6])
                            )
                    )
                
                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 80, height: 80)
                            .shadow(color: .orange.opacity(0.3), radius: 12, x: 0, y: 6)
                        
                        Image(systemName: "camera.metering.matrix")
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    
                    VStack(spacing: 8) {
                        Text("点击或拖动照片到这里")
                            .font(.system(size: 17, weight: .semibold))
                        
                        Text("支持 RAW 及 JPG (最大建议 100MB)")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        
                        Text("支持索尼, 尼康, 富士, 宾得, 理光, 奥林巴斯, 松下等相机原图")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                            .padding(.top, 2)
                    }
                    
                    HStack(spacing: 12) {
                        Button(action: selectFiles) {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.fill")
                                Text("选择照片文件")
                            }
                            .font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                }
                .padding(32)
            }
            .padding(24)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
            }
        }
    }
    
    // MARK: - 结果详情视图
    private var resultDetailView: some View {
        HStack(spacing: 0) {
            // 主信息区
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let res = selectedResult {
                        // 1. 核心 Hero Banner (快门次数 + 快门状态评级)
                        heroSection(res: res)
                        
                        // 2. EXIF 信息明细网格
                        exifInfoGrid(res: res)
                    }
                }
                .padding(24)
            }
            
            Divider()
                .opacity(0.3)
            
            // 右侧面板 (地图拍摄位置 + 快捷更换上传)
            VStack(spacing: 20) {
                if let res = selectedResult {
                    // 1. 拍摄位置
                    locationCard(res: res)
                    
                    // 2. 上传/替换照片卡片
                    uploadCard
                }
                Spacer()
            }
            .frame(width: 300)
            .padding(20)
            .background(Color.primary.opacity(0.015))
        }
    }
    
    // 核心快门数与评级 Hero 卡片（固定 160pt 高度，绝对无瑕对齐）
    private func heroSection(res: CameraShutterResult) -> some View {
        HStack(alignment: .center, spacing: 16) {
            // 左半边：快门次数 & 进度条
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("快门次数")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    if let tag = res.rawMakerNoteTag {
                        Text(tag)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                
                Spacer()
                
                if let count = res.shutterCount {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(formatNumber(count))
                                .font(.system(size: 42, weight: .heavy, design: .rounded))
                                .foregroundStyle(
                                    LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing)
                                )
                            
                            if let total = res.totalShutterCount, total != count {
                                Text("(底盘采帧 \(formatNumber(total)))")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary.opacity(0.8))
                            }
                        }
                        
                        if let pct = res.estimatedLifePercentage {
                            VStack(alignment: .leading, spacing: 6) {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.primary.opacity(0.08))
                                            .frame(height: 10)
                                        
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing))
                                            .frame(width: max(8, geo.size.width * CGFloat(pct)), height: 10)
                                    }
                                }
                                .frame(height: 10)
                                
                                HStack {
                                    Text("机械快门已使用")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(String(format: "%.1f%%", pct * 100))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("未找到快门数据")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.orange)
                        Text(res.statusMessage)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
            }
            .padding(18)
            .frame(height: 160)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.primary.opacity(0.035))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
            
            // 右半边：快门状态评级 S/A/B/C/D
            VStack(spacing: 0) {
                HStack {
                    Text("快门状态")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                
                Spacer()
                
                let grade = res.shutterGrade
                VStack(spacing: 6) {
                    Text(grade.grade)
                        .font(.system(size: 42, weight: .black, design: .rounded))
                        .foregroundColor(colorForGrade(grade.colorName))
                        .shadow(color: colorForGrade(grade.colorName).opacity(0.3), radius: 6, x: 0, y: 3)
                    
                    Text(grade.title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(colorForGrade(grade.colorName))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(colorForGrade(grade.colorName).opacity(0.12))
                        .clipShape(Capsule())
                }
                
                Spacer()
            }
            .padding(18)
            .frame(width: 160, height: 160)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.primary.opacity(0.035))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(colorForGrade(res.shutterGrade.colorName).opacity(0.3), lineWidth: 1)
                    )
            )
        }
    }
    
    // EXIF 参数明细网格
    private func exifInfoGrid(res: CameraShutterResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("核心参数面板")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.primary)
            
            VStack(spacing: 1) {
                let modelValue: String = {
                    if let serial = res.serialNumber, !serial.isEmpty, serial != "N/A" {
                        return "\(res.cameraModel ?? "未知型号") (\(serial))"
                    } else {
                        return res.cameraModel ?? "未知型号"
                    }
                }()
                
                ExifDetailRow(leftTitle: "相机制造商", leftValue: res.cameraMake ?? "未知制造商",
                              rightTitle: "相机型号", rightValue: modelValue)
                
                Divider().opacity(0.3)
                
                ExifDetailRow(leftTitle: "镜头型号", leftValue: res.lensModel ?? "未知镜头",
                              rightTitle: "镜头焦距", rightValue: res.focalLength ?? "-")
                
                Divider().opacity(0.3)
                
                ExifDetailRow(leftTitle: "光圈", leftValue: res.aperture ?? "-",
                              rightTitle: "快门速度", rightValue: res.shutterSpeed ?? "-")
                
                Divider().opacity(0.3)
                
                ExifDetailRow(leftTitle: "ISO", leftValue: res.iso ?? "-",
                              rightTitle: "图片名称", rightValue: res.fileName)
                
                Divider().opacity(0.3)
                
                ExifDetailRow(leftTitle: "拍摄时间", leftValue: res.dateTimeOriginal ?? "未知",
                              rightTitle: "查询时间", rightValue: res.queryTime)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.primary.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }
    
    // 拍摄位置卡片
    private func locationCard(res: CameraShutterResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundColor(.orange)
                Text("拍摄位置")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
            }
            
            if let lat = res.latitude, let lon = res.longitude {
                MapViewRepresentable(latitude: lat, longitude: lon)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                
                Text(String(format: "GPS: %.4f°, %.4f°", lat, lon))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "map")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("照片未包含 GPS 拍摄坐标")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .background(Color.primary.opacity(0.02))
                .cornerRadius(12)
            }
        }
    }
    
    // 右下角上传/换图面板
    private var uploadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("更换图片检测")
                .font(.system(size: 13, weight: .bold))
            
            Button(action: selectFiles) {
                VStack(spacing: 10) {
                    Image(systemName: "camera")
                        .font(.system(size: 26))
                        .foregroundColor(.orange)
                    Text("点击或拖动照片到这里")
                        .font(.system(size: 12, weight: .medium))
                    Text("RAW / JPG (最大建议 100 MB)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isTargeted ? Color.orange.opacity(0.08) : Color.primary.opacity(0.02))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isTargeted ? Color.orange : Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        )
                )
            }
            .buttonStyle(.plain)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
            }
        }
    }
    
    // MARK: - 辅助逻辑与格式化
    private func colorForGrade(_ name: String) -> Color {
        switch name {
        case "green": return .green
        case "blue": return .blue
        case "orange": return .orange
        case "red": return .red
        default: return .secondary
        }
    }
    
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.prompt = "选择照片"
        
        if panel.runModal() == .OK {
            processURLs(panel.urls)
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    urls.append(url)
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            if !urls.isEmpty {
                processURLs(urls)
            }
        }
        return true
    }
    
    private func processURLs(_ urls: [URL]) {
        let validExts = ["arw", "sr2", "nef", "nrw", "cr2", "cr3", "raf", "orf", "rw2", "pef", "dng", "jpg", "jpeg"]
        let filtered = urls.filter { validExts.contains($0.pathExtension.lowercased()) }
        guard !filtered.isEmpty else { return }
        
        isProcessing = true
        totalProcessingCount = filtered.count
        currentProcessingIndex = 0
        results.removeAll()
        
        Task {
            var newResults: [CameraShutterResult] = []
            for (idx, url) in filtered.enumerated() {
                await MainActor.run {
                    currentProcessingIndex = idx + 1
                }
                let res = await CameraShutterCountParser.shared.parse(url: url)
                newResults.append(res)
            }
            
            await MainActor.run {
                self.results = newResults
                self.selectedResultID = newResults.first?.id
                self.isProcessing = false
            }
        }
    }
    
    private func formatNumber(_ num: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: num)) ?? "\(num)"
    }
}

// 明细行组件
private struct ExifDetailRow: View {
    let leftTitle: String
    let leftValue: String
    let rightTitle: String
    let rightValue: String
    
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(leftTitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .leading)
                Text(leftValue)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            
            HStack(spacing: 8) {
                Text(rightTitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .leading)
                Text(rightValue)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
    }
}

struct MapViewRepresentable: NSViewRepresentable {
    let latitude: Double
    let longitude: Double
    
    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.showsZoomControls = true
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        return mapView
    }
    
    func updateNSView(_ nsView: MKMapView, context: Context) {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let region = MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        nsView.setRegion(region, animated: false)
        
        nsView.removeAnnotations(nsView.annotations)
        
        let annotation = MKPointAnnotation()
        annotation.coordinate = coordinate
        nsView.addAnnotation(annotation)
    }
}
