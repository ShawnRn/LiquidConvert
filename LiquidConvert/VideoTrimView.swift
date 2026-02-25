//
//  VideoTrimView.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//  Pro-level Editor UI inspired by Final Cut Pro
//

import SwiftUI
import AVKit

struct VideoTrimView: View {
    let url: URL
    @Binding var trimRange: ClosedRange<Double>
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var startTime: Double = 0
    @State private var endTime: Double = 1
    @State private var currentTime: Double = 0
    @State private var isPlaying = false
    
    @State private var thumbnails: [NSImage] = []
    @State private var isGeneratingThumbnails = false
    
    // Timer for updating current time
    @State private var timeObserver: Any?

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            HStack(spacing: 20) {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(8)
                        .background(Circle().fill(Color.secondary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: []) // ⌨️ 修复 Esc 退出
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                    Text("剪辑 & 预览")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // 隐式空格快捷键支持
                Button("") { togglePlayback() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .opacity(0)
                    .frame(width: 0, height: 0)
                
                HStack(spacing: 12) {
                    Text(formatTime(endTime - startTime))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.yellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().stroke(Color.yellow.opacity(0.3), lineWidth: 1))
                    
                    Button("完成剪辑") {
                        trimRange = startTime...endTime
                        onConfirm()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
                    .controlSize(.regular)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
            
            Divider()

            // MARK: - Preview Area
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                if let player = player {
                    CoreVideoPlayer(player: player)
                        .overlay(
                            Color.black.opacity(0.001) // Transparent overlay for gestures
                                .onTapGesture { togglePlayback() }
                        )
                    
                    if !isPlaying {
                        Button(action: togglePlayback) {
                            ZStack {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .frame(width: 70, height: 70)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.white)
                                    .offset(x: 2)
                            }
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .scale))
                    }
                } else {
                    ProgressView("正在准备预览...")
                        .tint(.white)
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(1)

            // MARK: - Timeline Area
            VStack(spacing: 0) {
                // Time Ruler
                TimeRuler(duration: duration)
                    .frame(height: 25)
                    .padding(.horizontal, 24)
                
                // Professional Timeline
                VideoTimelineView(
                    duration: duration,
                    startTime: $startTime,
                    endTime: $endTime,
                    currentTime: currentTime,
                    thumbnails: thumbnails,
                    isPlaying: isPlaying, // 🎬 传入播放状态
                    onSeek: { time in
                        seek(to: time, updatePlayhead: true)
                    },
                    onSkim: { time in
                        seek(to: time, updatePlayhead: false)
                    },
                    onSkimEnd: {
                        // 🖱️ 鼠标离开归位：回到白线位置
                        seek(to: currentTime, updatePlayhead: false)
                    }
                )
                .frame(height: 80)
                .padding(.horizontal, 24)
                
                // Controls Bar
                HStack {
                    HStack(spacing: 16) {
                        Button(action: { seek(to: startTime, updatePlayhead: true) }) {
                            Image(systemName: "backward.end.fill")
                        }
                        
                        Button(action: togglePlayback) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                        }
                        
                        Button(action: { seek(to: endTime, updatePlayhead: true) }) {
                            Image(systemName: "forward.end.fill")
                        }
                    }
                    .foregroundColor(.primary)
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    Text(formatTime(currentTime))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.yellow)
                    Text("/")
                        .foregroundColor(.secondary)
                    Text(formatTime(duration))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 800, height: 600)
        .preferredColorScheme(.dark)
        .onAppear {
            setupPlayer()
            generateThumbnails()
        }
        .onDisappear {
            cleanUp()
        }
    }

    // MARK: - Logic Helpers
    
    private func setupPlayer() {
        let asset = AVURLAsset(url: url)
        Task {
            do {
                let durationValue = try await asset.load(.duration)
                self.duration = durationValue.seconds
                
                // Initialize range from binding if valid, otherwise full duration
                if trimRange.upperBound > trimRange.lowerBound && trimRange.upperBound <= duration {
                    self.startTime = trimRange.lowerBound
                    self.endTime = trimRange.upperBound
                } else {
                    self.startTime = 0
                    self.endTime = self.duration
                }
                
                let playerItem = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: playerItem)
                player.isMuted = true
                self.player = player
                
                let interval = CMTime(seconds: 0.033, preferredTimescale: 600)
                timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
                    if isPlaying {
                        // 🎬 核心解耦：只有正在播放时才允许更新 currentTime
                        self.currentTime = time.seconds
                        
                        if currentTime >= endTime - 0.05 { // 稍微提前一点防止溢出
                            player.pause()
                            self.isPlaying = false
                        }
                    }
                }
                
                seek(to: startTime, updatePlayhead: true)
            } catch {
                print("Failed to load video: \(error)")
            }
        }
    }

    private func generateThumbnails() {
        guard !isGeneratingThumbnails else { return }
        isGeneratingThumbnails = true
        
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        
        Task.detached(priority: .userInitiated) {
            do {
                let duration = try await asset.load(.duration).seconds
                let count = 10
                var times: [CMTime] = []
                for i in 0..<count {
                    let time = CMTime(seconds: Double(i) * (duration / Double(count)), preferredTimescale: 600)
                    times.append(time)
                }
                
                // 🔥 修复并发竞争：先局部收集，再统一更新
                var localThumbnails: [NSImage?] = Array(repeating: nil, count: count)
                
                await withTaskGroup(of: (Int, NSImage?).self) { group in
                    for (index, time) in times.enumerated() {
                        group.addTask {
                            do {
                                let (cgImage, _) = try await generator.image(at: time)
                                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                                return (index, nsImage)
                            } catch {
                                print("Failed to generate thumbnail at \(time.seconds): \(error)")
                                return (index, nil)
                            }
                        }
                    }
                    
                    for await (index, image) in group {
                        localThumbnails[index] = image
                    }
                }
                
                let finalImages = localThumbnails.compactMap { $0 }
                
                await MainActor.run {
                    self.thumbnails = finalImages
                    self.isGeneratingThumbnails = false
                }
            } catch {
                print("Thumbnail generation error: \(error)")
                await MainActor.run { self.isGeneratingThumbnails = false }
            }
        }
    }

    private func seek(to time: Double, updatePlayhead: Bool) {
        let target = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        if updatePlayhead {
            currentTime = time
        }
    }

    private func togglePlayback() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
        } else {
            // 如果已经在末尾，则回到起点再播
            if currentTime >= endTime - 0.1 || currentTime < startTime {
                seek(to: startTime, updatePlayhead: true)
            }
            player.play()
        }
        isPlaying.toggle()
    }

    private func cleanUp() {
        player?.pause()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        player = nil
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let mins = Int(s) / 60
        let secs = Int(s) % 60
        let ms = Int((s.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d.%02d", mins, secs, ms)
    }
}

// MARK: - Professional Timeline Component

struct VideoTimelineView: View {
    let duration: Double
    @Binding var startTime: Double
    @Binding var endTime: Double
    let currentTime: Double
    let thumbnails: [NSImage]
    let isPlaying: Bool         // 🎬 是否正在播放
    let onSeek: (Double) -> Void // 更新播放头
    let onSkim: (Double) -> Void // 仅预览
    let onSkimEnd: () -> Void    // 鼠标移开归位
    
    @State private var skimmingTime: Double? = nil
    
    // 拖拽平滑移动逻辑
    @State private var dragOffset: Double = 0
    @State private var initialStartTime: Double = 0
    @State private var initialEndTime: Double = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // 1. Filmstrip Background (Thumbnails)
                HStack(spacing: 0) {
                    if thumbnails.isEmpty {
                        Rectangle().fill(Color.gray.opacity(0.1))
                    } else {
                        ForEach(0..<thumbnails.count, id: \.self) { index in
                            Image(nsImage: thumbnails[index])
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geometry.size.width / CGFloat(thumbnails.count))
                                .clipped()
                        }
                    }
                }
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1), lineWidth: 1))

                // 2. Dimmed Out-of-Range Background (Safe Calculation)
                let safeDuration = max(0.01, duration)
                let startPos = (startTime / safeDuration) * geometry.size.width
                let endPos = (endTime / safeDuration) * geometry.size.width
                
                Group {
                    Color.black.opacity(0.6)
                        .frame(width: max(0, startPos))
                    
                    Color.black.opacity(0.6)
                        .frame(width: max(0, geometry.size.width - endPos))
                        .offset(x: max(0, endPos))
                }
                .allowsHitTesting(false)

                // 3. Selection Range Highlight & Whole Dragging
                Rectangle()
                    .stroke(Color.yellow, lineWidth: 2)
                    .background(Color.black.opacity(0.001))
                    .contentShape(Rectangle())
                    .frame(width: max(0, endPos - startPos))
                    .offset(x: startPos)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if dragOffset == 0 {
                                    initialStartTime = startTime
                                    initialEndTime = endTime
                                }
                                
                                let totalWidth = geometry.size.width
                                let deltaX = value.translation.width
                                let deltaTime = (Double(deltaX) / max(1, Double(totalWidth))) * duration
                                dragOffset = deltaTime
                                
                                let selectionDuration = initialEndTime - initialStartTime
                                var newStart = initialStartTime + deltaTime
                                
                                // 限制范围
                                if newStart < 0 { newStart = 0 }
                                if newStart + selectionDuration > duration {
                                    newStart = duration - selectionDuration
                                }
                                
                                startTime = newStart
                                endTime = newStart + selectionDuration
                                onSeek(startTime) // 同步预览起始点
                            }
                            .onEnded { _ in
                                dragOffset = 0
                            }
                    )

                // 4. Interactive Layer (FCP Skimming & Clicking)
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if isPlaying { return } // 🎬 播放期间不响应悬浮预览
                        
                        switch phase {
                        case .active(let location):
                            let totalWidth = max(1, geometry.size.width)
                            let time = (location.x / totalWidth) * duration
                            skimmingTime = max(0, min(duration, time))
                            onSkim(skimmingTime!)
                        case .ended:
                            skimmingTime = nil
                            onSkimEnd() // 🏖️ 告知外部归位
                        }
                    }
                    .onTapGesture { location in
                        let time = (location.x / geometry.size.width) * duration
                        onSeek(max(0, min(duration, time)))
                    }

                // 5. Trim Handles
                TrimHandleView(isStart: true)
                    .offset(x: startPos - 10)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let x = value.location.x
                                let newTime = (x / geometry.size.width) * duration
                                startTime = max(0, min(endTime - 0.1, newTime))
                                onSeek(startTime)
                                skimmingTime = nil
                            }
                    )
                
                TrimHandleView(isStart: false)
                    .offset(x: endPos - 10)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let x = value.location.x
                                let newTime = (x / geometry.size.width) * duration
                                endTime = min(duration, max(startTime + 0.1, newTime))
                                onSeek(endTime)
                                skimmingTime = nil
                            }
                    )

                // 6. Skimmer Line (Red)
                if let skimmerTime = skimmingTime, !isPlaying {
                    SkimmerView(time: skimmerTime, duration: duration, width: geometry.size.width)
                }

                // 7. Playhead (White Line)
                PlayheadView(time: currentTime, duration: safeDuration, width: geometry.size.width)
            }
        }
    }
}

// MARK: - 渲染隔离组件 (优化 30fps 重绘性能)

struct PlayheadView: View {
    let time: Double
    let duration: Double
    let width: CGFloat
    
    var body: some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: 1.5)
            .offset(x: (time / max(0.01, duration)) * width)
            .allowsHitTesting(false)
    }
}

struct SkimmerView: View {
    let time: Double
    let duration: Double
    let width: CGFloat
    
    var body: some View {
        Rectangle()
            .fill(Color.red)
            .frame(width: 1.5)
            .offset(x: (time / max(0.01, duration)) * width)
            .allowsHitTesting(false)
    }
}

struct TrimHandleView: View {
    let isStart: Bool
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(white: 0.2))
                .frame(width: 20, height: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )
            
            Image(systemName: isStart ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .black))
                .foregroundColor(.white)
        }
        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
        .cursor(.resizeLeftRight)
    }
}

struct TimeRuler: View {
    let duration: Double
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                Path { path in
                    let tickCount = 20
                    for i in 0...tickCount {
                        let x = CGFloat(i) * (geometry.size.width / CGFloat(tickCount))
                        path.move(to: CGPoint(x: x, y: geometry.size.height))
                        path.addLine(to: CGPoint(x: x, y: geometry.size.height - (i % 5 == 0 ? 10 : 5)))
                    }
                }
                .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                
                HStack {
                    Text("0:00")
                    Spacer()
                    Text(formatTime(duration/2))
                    Spacer()
                    Text(formatTime(duration))
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.bottom, 12)
            }
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside {
                cursor.push()
            } else {
                cursor.pop()
            }
        }
    }
}

struct CoreVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none 
        view.videoGravity = .resizeAspect
        view.allowsMagnification = true
        view.allowsVideoFrameAnalysis = false 
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player != player {
            nsView.player = player
        }
    }
}
