import Foundation

/// 播放地址嗅探服务：对失效或非直链地址做页面抓取与正则嗅探，
/// 对齐 Android 版 AVBox 的"嗅探/解析切换"核心行为。
final class SniffService {
    static let shared = SniffService()
    
    private init() {}
    
    /// GBK/GB18030 编码（部分老站页面非 UTF-8）。
    private static let gbkEncoding: String.Encoding = {
        let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }()
    
    /// 候选嗅探正则（按优先级排序）。
    private static let sniffPatterns: [NSRegularExpression] = [
        // 常见 m3u8（含带 token 参数）
        try! NSRegularExpression(
            pattern: "https?://[^\\s\"'<>()]+?\\.m3u8[^\\s\"'<>()]*",
            options: [.caseInsensitive]
        ),
        // flv/mp4/m4v 直链
        try! NSRegularExpression(
            pattern: "https?://[^\\s\"'<>()]+?\\.(?:mp4|flv|m4v|ts)(?:\\?[^\\s\"'<>()]*)?",
            options: [.caseInsensitive]
        ),
        // iframe / video 标签的 src
        try! NSRegularExpression(
            pattern: "(?:iframe|video|source|embed)[^>]*\\bsrc\\s*=\\s*[\"']([^\"']+)[\"']",
            options: [.caseInsensitive]
        ),
        // 常见播放器变量：url = "..." / playUrl / vurl / videoUrl
        try! NSRegularExpression(
            pattern: "(?:url|playUrl|vurl|videoUrl|m3u8|mp4|realUrl)\\s*[:=]\\s*[\"'](https?://[^\"']+)[\"']",
            options: [.caseInsensitive]
        ),
        // window.location / location.href 跳转
        try! NSRegularExpression(
            pattern: "(?:window\\.)?location(?:\\.href)?\\s*[:=]\\s*[\"'](https?://[^\"']+)[\"']",
            options: [.caseInsensitive]
        ),
        // 通用 URL（兜底，排除图片/静态资源后缀）
        try! NSRegularExpression(
            pattern: "https?://[^\\s\"'<>()]+",
            options: []
        )
    ]
    
    /// 忽略的资源后缀（嗅探兜底正则命中后仍需过滤）。
    private static let ignoredExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "ico", "css", "js", "woff",
        "woff2", "ttf", "svg", "json", "xml", "txt", "html", "htm", "pdf"
    ]
    
    /// 对给定播放地址执行嗅探，返回候选播放地址列表（已去重、过滤）。
    func sniff(from urlString: String) async -> [String] {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return [] }
        
        var content = ""
        // 优先请求页面/接口内容。
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue(url.host ?? "", forHTTPHeaderField: "Referer")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               http.statusCode == 200,
               let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: Self.gbkEncoding) {
                content = text
            }
        } catch {
            print("嗅探抓取失败: \(error)")
        }
        
        // 若内容看起来已是直接可播地址（m3u8/mp4 且非 HTML），直接返回。
        let lowerContent = content.lowercased()
        if !lowerContent.contains("<html") && !lowerContent.contains("<script") && !lowerContent.contains("<body") {
            if lowerContent.hasPrefix("http"), Self.isPlayable(trimmed) {
                return [trimmed]
            }
        }
        
        var results: [String] = []
        var seen = Set<String>()
        
        for pattern in Self.sniffPatterns {
            let matches = pattern.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches {
                // 提取整个匹配或第 1 个捕获组。
                let captureRange = match.range(at: match.numberOfRanges > 1 ? 1 : 0)
                guard captureRange.location != NSNotFound,
                      let range = Range(captureRange, in: content) else { continue }
                var candidate = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                // 去除尾部引号/括号残留。
                candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>()"))
                
                guard !candidate.isEmpty,
                      candidate.lowercased().hasPrefix("http"),
                      !seen.contains(candidate) else { continue }
                
                let normalized = Self.normalizeCandidate(candidate, base: trimmed)
                guard !seen.contains(normalized) else { continue }
                
                // 过滤非视频资源。
                if Self.isLikelyVideo(normalized) || normalized == trimmed {
                    seen.insert(normalized)
                    results.append(normalized)
                }
            }
        }
        
        // 去重后返回（最多 5 个候选）。
        return Array(results.prefix(5))
    }
    
    /// 解析器接入：从配置解析器列表中取第一个可用解析器，
    /// 用"解析接口 + 原地址"拼接后请求，尝试提取真实播放地址。
    /// 仅支持返回 JSON 的解析接口；WebView 型解析器暂不自动调用。
    func parseViaParser(originalURL: String, parseBeans: [ParseBean]) async -> String? {
        guard let bean = parseBeans.first(where: { $0.url.isValidURL }) else { return nil }
        let parseUrlString = bean.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = Self.parseUrlSeparator(parseUrlString),
              let url = URL(string: "\(parseUrlString)\(separator)\(originalURL)") else { return nil }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            // JSON 中常见字段：url / playUrl / vinfo / data。
            let patterns = [
                try! NSRegularExpression(pattern: "\"url\"\\s*:\\s*\"([^\"]+)\"", options: []),
                try! NSRegularExpression(pattern: "\"playUrl\"\\s*:\\s*\"([^\"]+)\"", options: []),
                try! NSRegularExpression(pattern: "\"(?:url|play|realUrl)\"\\s*:\\s*\"(https?://[^\"]+)\"", options: [.caseInsensitive])
            ]
            for pattern in patterns {
                if let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                   match.numberOfRanges > 1 {
                    let range = Range(match.range(at: 1), in: text)
                    let value = String(text[range!]).replacingOccurrences(of: "\\/", with: "/")
                    let normalized = value.removingPercentEncoding ?? value
                    if Self.isLikelyVideo(normalized) {
                        return normalized
                    }
                }
            }
        } catch {
            print("解析器请求失败: \(error)")
        }
        return nil
    }
    
    /// 解析接口的拼接分隔符（? 或 /）。
    private static func parseUrlSeparator(_ url: String) -> String? {
        if url.contains("?") { return "&url=" }
        if url.hasSuffix("/") { return "" }
        return "?url="
    }
    
    /// 规范化候选地址：相对路径拼 base、HTML 实体解码。
    private static func normalizeCandidate(_ candidate: String, base: String) -> String {
        var normalized = candidate
        normalized = normalized.replacingOccurrences(of: "&amp;", with: "&")
        if normalized.hasPrefix("//") {
            normalized = "https:" + normalized
        } else if normalized.hasPrefix("/") {
            if let baseURL = URL(string: base), let host = baseURL.host {
                let scheme = baseURL.scheme ?? "https"
                normalized = "\(scheme)://\(host)\(normalized)"
            }
        }
        return normalized
    }
    
    /// 判断是否为可播放视频地址（m3u8/mp4/flv/ts 或包含播放关键字）。
    private static func isLikelyVideo(_ url: String) -> Bool {
        let lower = url.lowercased()
        if Self.isPlayable(url) { return true }
        // 包含播放常见路径关键字。
        let keywords = ["/play/", "/video/", "/v/", "/live/", "/vod/", "m3u8", "playurl", "play_url", "/media/", "/stream/"]
        return keywords.contains { lower.contains($0) }
    }
    
    private static func isPlayable(_ url: String) -> Bool {
        let lower = url.lowercased()
        guard let u = URL(string: url) else { return false }
        // 排除静态资源。
        let ext = (u.pathExtension.isEmpty ? "" : u.pathExtension.lowercased())
        if Self.ignoredExtensions.contains(ext) { return false }
        let playableExts = ["m3u8", "mp4", "flv", "m4v", "ts", "mov", "mkv", "webm", "avi"]
        if playableExts.contains(ext) { return true }
        return lower.contains("m3u8")
    }
}
