import Foundation
import AVFoundation
import Combine

/// 片头片尾检测结果：introEnd=片头结束点（秒），outroStart=片尾开始点（秒）
struct SkipPoints: Codable {
    var introEnd: Double?
    var outroStart: Double?
}

/// 智能跳过片头片尾控制器：
/// - 首次播放某视频时，后台分析该视频数据（音轨低能量转场空隙 + 画面帧差突变），
///   自动定位片头结束点 / 片尾开始点；
/// - 结果按播放地址缓存到 UserDefaults，同集再次播放直接复用、零等待；
/// - 播放过程中由 tick 驱动自动跳过：片头段自动 seek 到正片起点，片尾段自动跳下一集；
/// - 控制栏提供"跳片头 / 跳片尾"手动按钮兜底（检测不到时按默认 20s / 结尾前 10s）。
@MainActor
final class SmartSkipController: ObservableObject {
    static let shared = SmartSkipController()

    /// 片头结束点（秒），nil 表示未检测到。
    @Published var introEnd: Double?
    /// 片尾开始点（秒），nil 表示未检测到。
    @Published var outroStart: Double?
    /// 检测进行中（供 UI 显示"检测片头片尾中…"）。
    @Published private(set) var isAnalyzing = false

    private var currentKey: String?
    private var introSkipped = false
    private var outroSkipped = false
    private var detectTask: Task<Void, Never>?

    private init() {}

    // MARK: - 设置开关（默认开启）

    var autoSkipIntro: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: HawkConfig.SKIP_INTRO) != nil { return d.bool(forKey: HawkConfig.SKIP_INTRO) }
        return true
    }
    var autoSkipOutro: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: HawkConfig.SKIP_OUTRO) != nil { return d.bool(forKey: HawkConfig.SKIP_OUTRO) }
        return true
    }

    // MARK: - 复位（切换新视频）

    func reset(forKey key: String) {
        guard currentKey != key else { return }
        currentKey = key
        introEnd = nil
        outroStart = nil
        introSkipped = false
        outroSkipped = false
        detectTask?.cancel()
        detectTask = nil

        // 命中缓存：直接复用，零等待
        if let cached = Self.loadCache(key: key) {
            apply(points: cached)
            return
        }
        guard let url = Self.sanitizedURL(from: key) else { return }
        isAnalyzing = true
        detectTask = Task { @MainActor in
            let points = await Self.detect(url: url)
            guard !Task.isCancelled else { return }
            Self.saveCache(key: key, points: points)
            self.apply(points: points)
            self.isAnalyzing = false
        }
    }

    private func apply(points: SkipPoints) {
        introEnd = points.introEnd
        outroStart = points.outroStart
    }

    /// 重新触发检测（手动按钮/设置变更后调用）。
    func redetect(forKey key: String) {
        currentKey = nil
        reset(forKey: key)
    }

    // MARK: - 播放进度驱动（自动跳过）

    func tick(currentTime: Double, duration: Double, isPlaying: Bool,
              canPlayNext: Bool, onSeekTo: (Double) -> Void, onPlayNext: () -> Void) {
        guard isPlaying, duration > 30 else { return }

        // 片头：播放到片头结束点附近时自动 seek 到正片起点
        if autoSkipIntro, let end = introEnd, !introSkipped {
            if currentTime >= end - 2, currentTime <= end + 8 {
                introSkipped = true
                onSeekTo(end + 0.8)
            }
        }
        // 片尾：播放到片尾开始点前自动跳下一集
        if autoSkipOutro, let start = outroStart, !outroSkipped, canPlayNext {
            if currentTime >= start - 4, currentTime <= start + 2 {
                outroSkipped = true
                onPlayNext()
            }
        }
    }

    /// 手动"跳片头"目标点（检测到则跳片头结束，否则按默认 20 秒）。
    var introTarget: Double { introEnd ?? 20 }

    /// 手动"跳片尾"目标点（检测到则跳到片尾开始前 3 秒，否则结尾前 10 秒）。
    func outroTarget(duration: Double) -> Double {
        if let start = outroStart { return max(0, start - 3) }
        return max(0, duration - 10)
    }

    // MARK: - 手动记录（自动检测无结果时，由用户拖动进度条后标记）

    /// 把当前播放位置记录为片头结束点（同集后续自动复用）。
    func markIntro(at time: Double) {
        guard let key = currentKey else { return }
        introEnd = time
        introSkipped = false
        let pts = SkipPoints(introEnd: time, outroStart: outroStart)
        Self.saveCache(key: key, points: pts)
    }

    /// 把当前播放位置记录为片尾开始点（同集后续自动复用）。
    func markOutro(at time: Double) {
        guard let key = currentKey else { return }
        outroStart = time
        outroSkipped = false
        let pts = SkipPoints(introEnd: introEnd, outroStart: time)
        Self.saveCache(key: key, points: pts)
    }

    // MARK: - 缓存

    private nonisolated static func cacheKey(_ key: String) -> String {
        "smart_skip_v1_" + String(Self.stableHash(key), radix: 36)
    }
    private nonisolated static func stableHash(_ s: String) -> Int {
        var h: Int = 5381
        for b in s.utf8 { h = ((h << 5) &+ h) &+ Int(b) }
        return h
    }
    private nonisolated static func loadCache(key: String) -> SkipPoints? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(key)) else { return nil }
        return try? JSONDecoder().decode(SkipPoints.self, from: data)
    }
    private nonisolated static func saveCache(key: String, points: SkipPoints) {
        guard let data = try? JSONEncoder().encode(points) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(key))
    }

    // MARK: - URL 净化（与 AVPlayerContentView 保持一致）

    private nonisolated static func sanitizedURL(from raw: String) -> URL? {
        if let u = URL(string: raw) { return u }
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let u = URL(string: encoded) else { return nil }
        return u
    }

    // MARK: - 检测算法

    private nonisolated static func detect(url: URL) async -> SkipPoints {
        let asset = AVURLAsset(url: url)
        do {
            let secs = try await asset.load(.duration).seconds
            guard secs.isFinite, secs > 70 else { return SkipPoints() }
            let duration = secs
            var points = SkipPoints()

            // 片头：分析 [15s, 240s] 音频低能量空隙，取最后一个空隙的结束点
            let introWindow = 240.0
            if let rms = audioRMS(asset: asset, start: 15, length: introWindow - 15, window: 0.25), !rms.isEmpty {
                let thr = energyThreshold(rms)
                let gaps = lowEnergyGaps(rms: rms, threshold: thr, minWindows: 2)
                if let last = gaps.last {
                    let t = 15 + Double(last.end) * 0.25
                    if t >= 20, t <= 180 { points.introEnd = t }
                }
            }
            // 音频未命中时用画面帧差备选
            if points.introEnd == nil {
                if let cut = frameCuts(asset: asset, start: 15, end: 240).last, cut >= 20, cut <= 180 {
                    points.introEnd = cut
                }
            }

            // 片尾：分析 [duration-240, duration-15] 音频低能量空隙，取最后一个空隙的开始点
            let outroWindow = 240.0
            if duration > outroWindow + 40 {
                if let rms = audioRMS(asset: asset, start: duration - outroWindow, length: outroWindow - 15, window: 0.25), !rms.isEmpty {
                    let thr = energyThreshold(rms)
                    let gaps = lowEnergyGaps(rms: rms, threshold: thr, minWindows: 2)
                    if let last = gaps.last {
                        let t = (duration - outroWindow) + Double(last.start) * 0.25
                        if t >= duration - 180, t <= duration - 25 { points.outroStart = t }
                    }
                }
                if points.outroStart == nil {
                    if let cut = frameCuts(asset: asset, start: duration - outroWindow, end: duration - 15).last,
                       cut >= duration - 180, cut <= duration - 25 {
                        points.outroStart = cut
                    }
                }
            }
            return points
        } catch {
            return SkipPoints()
        }
    }

    /// 读取音轨指定区间的 RMS 序列（每 window 秒一个值）。
    private nonisolated static func audioRMS(asset: AVURLAsset, start: Double, length: Double, window: Double) -> [Double]? {
        guard let track = asset.tracks(withMediaType: .audio).first else { return nil }
        let range = CMTimeRange(start: CMTime(seconds: max(start, 0), preferredTimescale: 600),
                                duration: CMTime(seconds: max(length, 0.1), preferredTimescale: 600))
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { return nil }
        reader.timeRange = range
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var rms: [Double] = []
        var sampleRate: Double = 48000
        var haveRate = false
        var acc: Double = 0
        var accCount = 0
        var windowSamples: Int = Int(sampleRate * window)

        while let sb = output.copyNextSampleBuffer() {
            var channels = 2
            if let fmt = CMSampleBufferGetFormatDescription(sb) {
                var asbd = AudioStreamBasicDescription()
                CMAudioFormatDescriptionGetStreamBasicDescription(fmt, &asbd)
                if asbd.mSampleRate > 0 {
                    sampleRate = Double(asbd.mSampleRate)
                    haveRate = true
                }
                if asbd.mChannelsPerFrame > 0 {
                    channels = Int(asbd.mChannelsPerFrame)
                }
            }
            windowSamples = max(1, Int(sampleRate * window))
            // 用 CMSampleBufferCopyPCMDataIntoAudioBufferList 拷出 PCM（调用者提供缓冲，无需手动释放）。
            let numFrames = CMSampleBufferGetNumSamples(sb)
            guard numFrames > 0 else { continue }
            var samples = [Float](repeating: 0, count: Int(numFrames) * channels)
            let err = samples.withUnsafeMutableBytes { raw -> OSStatus in
                var abl = AudioBufferList()
                abl.mNumberBuffers = 1
                abl.mBuffers.0.mNumberChannels = UInt32(channels)
                abl.mBuffers.0.mDataByteSize = raw.count
                abl.mBuffers.0.mData = raw.baseAddress
                return CMSampleBufferCopyPCMDataIntoAudioBufferList(
                    sb, frameOffset: 0, frameCount: Int32(numFrames), bufferList: &abl)
            }
            guard err == noErr else { continue }
            for v in samples {
                let f = Double(v)
                acc += f * f
                accCount += 1
                if accCount >= windowSamples {
                    rms.append(sqrt(acc / Double(accCount)))
                    acc = 0
                    accCount = 0
                }
            }
        }
        if reader.status == .failed { return nil }
        if accCount > 0 { rms.append(sqrt(acc / Double(accCount))) }
        return rms.isEmpty ? nil : rms
    }

    /// 低能量阈值：序列 P85 的 18%，下限 0.002。
    private nonisolated static func energyThreshold(_ rms: [Double]) -> Double {
        let sorted = rms.sorted()
        let idx = max(0, Int(Double(sorted.count) * 0.85) - 1)
        return max(sorted[min(idx, sorted.count - 1)] * 0.18, 0.002)
    }

    /// 低能量空隙段（index 区间 [start, end)），连续 minWindows 个窗口以上才算。
    private nonisolated static func lowEnergyGaps(rms: [Double], threshold: Double, minWindows: Int) -> [(start: Int, end: Int)] {
        var gaps: [(Int, Int)] = []
        var i = 0
        let n = rms.count
        while i < n {
            if rms[i] < threshold {
                var j = i
                while j < n && rms[j] < threshold { j += 1 }
                if j - i >= minWindows { gaps.append((i, j)) }
                i = j
            } else {
                i += 1
            }
        }
        return gaps
    }

    /// 画面帧差突变点：每 step 秒采样一帧灰度亮度，记录相邻亮度差大于阈值的时刻。
    private nonisolated static func frameCuts(asset: AVURLAsset, start: Double, end: Double, step: Double = 1.5) -> [Double] {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.maximumSize = CGSize(width: 64, height: 36)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        var cuts: [Double] = []
        var prev: Double?
        var t = start
        while t < end {
            if let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
                let luma = averageLuma(of: cg)
                if let p = prev, abs(luma - p) > 0.12 {
                    cuts.append(t)
                }
                prev = luma
            }
            t += step
        }
        return cuts
    }

    private nonisolated static func averageLuma(of image: CGImage) -> Double {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return 0 }
        var pixel = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixel, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum: Int = 0
        for v in pixel { sum += Int(v) }
        return Double(sum) / Double(pixel.count * 255)
    }
}
