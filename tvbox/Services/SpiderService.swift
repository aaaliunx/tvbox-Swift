import Foundation
import JavaScriptCore
import zlib

/// Spider（type=3）源执行服务。
/// 通过 JavaScriptCore 在沙箱内执行用户配置的 JS 脚本源，
/// 桥接同步 fetch 网络能力，对齐 Android 版 TVBox/AVBox 的 Spider 协议：
///   homeContent(reset) / categoryContent(cid, page, filter, extend)
///   detailContent(ids) / searchContent(key, quick)
/// 所有脚本返回 JSON 字符串，这里统一解析为 Swift 模型。
/// 注意：同一脚本的调用必须串行（JSContext 非线程安全）。
final class SpiderService {
    static let shared = SpiderService()
    
    /// 已加载脚本上下文缓存（按脚本 URL）。
    private var contextCache: [String: JSContext] = [:]
    /// JS 调用串行队列。
    private let executionQueue = DispatchQueue(label: "tvbox.spider.execution")
    
    /// GBK/GB18030 编码（部分老站页面非 UTF-8）。
    private static let gbkEncoding: String.Encoding = {
        let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }()
    
    // MARK: - jar（zip）源支持
    
    /// 下载 jar 并解包提取第一个 .js 脚本内容。
    private static func extractJSFromJar(at urlString: String) async throws -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        guard data.count > 22 else { return nil }
        return extractFirstJS(from: data)
    }
    
    /// 解析 zip 中央目录，返回第一个 .js 条目内容（支持 store/deflate）。
    private static func extractFirstJS(from zipData: Data) -> String? {
        guard zipData.count > 22 else { return nil }
        // 定位 EOCD（0x06054b50），允许最大 64KB 尾部注释。
        var eocd = -1
        var idx = zipData.count - 22
        let minStart = max(0, zipData.count - 22 - 65535)
        while idx >= minStart {
            if zipData[idx] == 0x50,
               idx + 3 < zipData.count,
               zipData[idx + 1] == 0x4b,
               zipData[idx + 2] == 0x05,
               zipData[idx + 3] == 0x06 {
                eocd = idx
                break
            }
            idx -= 1
        }
        guard eocd >= 0 else { return nil }
        
        let cdCount = Int(leU16(zipData, eocd + 10))
        let cdOffset = Int(leU32(zipData, eocd + 16))
        guard cdOffset >= 0, cdOffset < zipData.count else { return nil }
        
        var jsEntries: [(local: Int, method: Int, size: Int)] = []
        var pos = cdOffset
        for _ in 0..<min(cdCount, 65535) {
            guard pos + 46 <= zipData.count else { break }
            guard leU32(zipData, pos) == 0x02014b50 else { break }
            let method = Int(leU16(zipData, pos + 10))
            let compressed = Int(leU32(zipData, pos + 20))
            let nameLen = Int(leU16(zipData, pos + 28))
            let extraLen = Int(leU16(zipData, pos + 30))
            let commentLen = Int(leU16(zipData, pos + 32))
            let localOffset = Int(leU32(zipData, pos + 42))
            let nameStart = pos + 46
            guard nameStart + nameLen <= zipData.count else { break }
            let nameData = zipData.subdata(in: nameStart..<(nameStart + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            if name.lowercased().hasSuffix(".js") {
                jsEntries.append((localOffset, method, compressed))
            }
            pos = nameStart + nameLen + extraLen + commentLen
        }
        
        for entry in jsEntries {
            if let content = readZipEntry(zipData, local: entry.local, method: entry.method, compressedSize: entry.size) {
                return content
            }
        }
        return nil
    }
    
    /// 读取 zip 本地文件头并解出条目内容。
    private static func readZipEntry(_ data: Data, local: Int, method: Int, compressedSize: Int) -> String? {
        guard local >= 0, local + 30 <= data.count else { return nil }
        let nameLen = Int(leU16(data, local + 26))
        let extraLen = Int(leU16(data, local + 28))
        let start = local + 30 + nameLen + extraLen
        guard start >= 0, start + compressedSize <= data.count else { return nil }
        let raw = data.subdata(in: start..<(start + compressedSize))
        let bytes: Data
        if method == 0 {
            bytes = raw
        } else if method == 8 {
            guard let inflated = zlibInflate(raw) else { return nil }
            bytes = inflated
        } else {
            return nil
        }
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1)
    }
    
    private static func leU16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[o]) | (UInt16(d[o + 1]) << 8)
    }
    
    private static func leU32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | (UInt32(d[o + 1]) << 8) | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24)
    }
    
    /// zlib 解压（windowBits 15+32 自动识别 deflate/zlib/gzip）。
    private static func zlibInflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let base = raw.baseAddress else { return nil }
            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: base.assumingMemoryBound(to: UInt8.self))
            stream.avail_in = uInt(data.count)
            var out = Data(capacity: data.count * 4)
            let chunk = 65536
            var buffer = [UInt8](repeating: 0, count: chunk)
            var st = inflateInit2_(
                &stream,
                15 + 32,
                (ZLIB_VERSION as NSString).utf8String,
                Int32(MemoryLayout<z_stream>.size)
            )
            guard st == Z_OK else { return nil }
            while st == Z_OK {
                var produced = 0
                buffer.withUnsafeMutableBytes { (rawBuf: UnsafeMutableRawBufferPointer) in
                    stream.next_out = rawBuf.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(chunk)
                    st = inflate(&stream, Z_NO_FLUSH)
                    produced = chunk - Int(stream.avail_out)
                }
                if produced > 0 { out.append(buffer, count: produced) }
                if st == Z_STREAM_END { break }
            }
            inflateEnd(&stream)
            return st == Z_STREAM_END ? out : nil
        }
    }
    
    private init() {}
    
    /// 脚本 URL 是否可支持（http/https 脚本，而非 jar:// Java 包）。
    func isSupported(api: String) -> Bool {
        let trimmed = api.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }
    
    // MARK: - 首页分类 + 推荐列表
    
    /// 调用 homeContent 获取分类与首页推荐。
    func homeContent(for sourceBean: SourceBean) async throws -> (
        sorts: [MovieSort.SortData],
        homeVideos: [Movie.Video]
    ) {
        let json = try await callFunction("homeContent", args: ["true"], sourceBean: sourceBean)
        let data = try normalizeData(in: json)
        let sorts = Self.parseSorts(from: data["class"])
        let videos = Self.parseVideos(from: data["list"], sourceKey: sourceBean.key)
        return (sorts, videos)
    }
    
    /// 调用 categoryContent 获取分类页视频列表。
    func categoryContent(
        for sourceBean: SourceBean,
        sort: MovieSort.SortData,
        page: Int = 1
    ) async throws -> [Movie.Video] {
        let json = try await callFunction(
            "categoryContent",
            args: ["\(sort.id)", "\(page)", "true", ""],
            sourceBean: sourceBean
        )
        let data = try normalizeData(in: json)
        return Self.parseVideos(from: data["list"], sourceKey: sourceBean.key)
    }
    
    /// 调用 searchContent 搜索。
    func searchContent(for sourceBean: SourceBean, keyword: String) async throws -> [Movie.Video] {
        let json = try await callFunction(
            "searchContent",
            args: ["\(keyword)", "true"],
            sourceBean: sourceBean
        )
        let data = try normalizeData(in: json)
        return Self.parseVideos(from: data["list"], sourceKey: sourceBean.key)
    }
    
    /// 调用 detailContent 获取详情。
    func detailContent(for sourceBean: SourceBean, vodId: String) async throws -> VodInfo? {
        let json = try await callFunction("detailContent", args: ["\(vodId)"], sourceBean: sourceBean)
        let data = try normalizeData(in: json)
        let list = data["list"] as? [[String: Any]] ?? []
        guard let first = list.first else { return nil }
        return Self.parseDetail(from: first, sourceKey: sourceBean.key)
    }
    
    // MARK: - JS 执行
    
    /// 获取（并缓存）已加载的 JSContext。
    private func context(for sourceBean: SourceBean) async throws -> JSContext {
        let api = sourceBean.api.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !api.isEmpty else { throw SourceError.emptyApi }
        guard isSupported(api: api) else {
            throw SourceError.unsupportedType(sourceBean.typeDescription)
        }
        
        if let cached = contextCache[api] { return cached }
        
        // jar 本质是 zip 容器：TVBox 生态多数 jar 实际打包 JS 脚本，
        // 解包提取 JS 后执行；纯 Java 字节码 jar 无法在 iOS 运行（无 JVM）。
        let script: String
        if api.lowercased().hasSuffix(".jar") {
            guard let js = try await Self.extractJSFromJar(at: api) else {
                throw SourceError.spiderFunctionFailed(
                    "jar 源未找到 JS 脚本：iOS 无法执行 Java 字节码，请改用 JS 版脚本源"
                )
            }
            script = js
        } else {
            script = try await NetworkManager.shared.getString(from: api)
        }
        let context = JSContext()!
        context.exceptionHandler = { _, exception in
            print("[Spider] JS 异常: \(exception?.toString() ?? "unknown")")
        }
        
        // 注入同步 fetch：spider 脚本常用 fetch(url) 直接取页面/接口内容。
        let fetchBlock: @convention(block) (String) -> String? = { input in
            guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue(url.host ?? "", forHTTPHeaderField: "Referer")
            
            let semaphore = DispatchSemaphore(value: 0)
            var result: String?
            let task = URLSession.shared.dataTask(with: request) { data, _, _ in
                if let data {
                    result = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: Self.gbkEncoding)
                }
                semaphore.signal()
            }
            task.resume()
            _ = semaphore.wait(timeout: .now() + 10)
            return result
        }
        context.setObject(fetchBlock, forKeyedSubscript: "fetch" as NSString)
        
        // console.log 桥接到日志（部分脚本会打印调试信息）。
        let logBlock: @convention(block) (String) -> Void = { message in
            print("[Spider] console: \(message)")
        }
        context.setObject(logBlock, forKeyedSubscript: "log" as NSString)
        
        context.evaluateScript(script)
        contextCache[api] = context
        return context
    }
    
    /// 串行调用脚本函数并返回其 JSON 字符串结果。
    /// 同一脚本上下文串行执行，避免 JSContext 并发问题。
    private func callFunction(
        _ name: String,
        args: [String],
        sourceBean: SourceBean
    ) async throws -> String {
        let context = try await context(for: sourceBean)
        
        return try await withCheckedThrowingContinuation { continuation in
            executionQueue.async {
                guard let function = context.objectForKeyedSubscript(name) else {
                    continuation.resume(throwing: SourceError.spiderFunctionMissing(name))
                    return
                }
                let result = function.call(withArguments: args)
                guard let value = result?.toString() else {
                    continuation.resume(throwing: SourceError.spiderFunctionFailed(name))
                    return
                }
                continuation.resume(returning: value)
            }
        }
    }
    
    // MARK: - JSON 适配与解析
    
    /// 适配两种返回格式：
    ///  1) { "class": [...], "list": [...] }
    ///  2) { "code": 0, "data": { "class": [...], "list": [...] } }
    private func normalizeData(in json: String) throws -> [String: Any] {
        guard let raw = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw SourceError.parseError("Spider 返回非 JSON: \(json.prefix(200))")
        }
        if let data = obj["data"] as? [String: Any], obj["code"] != nil {
            return data
        }
        return obj
    }
    
    /// 解析分类列表（class 字段）。
    private static func parseSorts(from value: Any?) -> [MovieSort.SortData] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            let id = Self.stringValue(item["type_id"])
            let name = Self.stringValue(item["type_name"])
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return MovieSort.SortData(id: id, name: name, flag: "spider")
        }
    }
    
    /// 解析视频列表（list 字段）。
    private static func parseVideos(from value: Any?, sourceKey: String) -> [Movie.Video] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            let vodId = Self.stringValue(item["vod_id"])
            let name = Self.stringValue(item["vod_name"])
            guard !vodId.isEmpty, !name.isEmpty else { return nil }
            var video = Movie.Video(
                id: vodId,
                name: name,
                pic: Self.stringValue(item["vod_pic"]),
                note: Self.stringValue(item["vod_remarks"]),
                sourceKey: sourceKey
            )
            video.tid = Self.stringValue(item["type_id"])
            video.year = Self.stringValue(item["vod_year"])
            video.area = Self.stringValue(item["vod_area"])
            video.type = Self.stringValue(item["type_name"])
            video.director = Self.stringValue(item["vod_director"])
            video.actor = Self.stringValue(item["vod_actor"])
            video.des = Self.stringValue(item["vod_content"])
            video.last = Self.stringValue(item["vod_time"])
            return video
        }
    }
    
    /// 解析详情（vod_play_from 线路 + vod_play_url 剧集）。
    private static func parseDetail(from item: [String: Any], sourceKey: String) -> VodInfo {
        let vodId = Self.stringValue(item["vod_id"])
        var info = VodInfo(id: vodId, sourceKey: sourceKey)
        info.name = Self.stringValue(item["vod_name"])
        info.pic = Self.stringValue(item["vod_pic"])
        info.note = Self.stringValue(item["vod_remarks"])
        info.year = Self.stringValue(item["vod_year"])
        info.area = Self.stringValue(item["vod_area"])
        info.typeName = Self.stringValue(item["type_name"])
        info.director = Self.stringValue(item["vod_director"])
        info.actor = Self.stringValue(item["vod_actor"])
        info.des = Self.stringValue(item["vod_content"])
        
        let playFromRaw = Self.stringValue(item["vod_play_from"])
        let playUrlRaw = Self.stringValue(item["vod_play_url"])
        let flags = playFromRaw.isEmpty
            ? ["默认"]
            : playFromRaw.components(separatedBy: "$$$").filter { !$0.isEmpty }
        let lines = playUrlRaw.components(separatedBy: "$$$")
        
        for (index, flag) in flags.enumerated() {
            let episodesRaw = index < lines.count ? lines[index] : ""
            var episodes: [VodInfo.Episode] = []
            for part in episodesRaw.components(separatedBy: "#") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if let separator = trimmed.firstIndex(of: "$") {
                    let epName = String(trimmed[..<separator])
                        .trimmingCharacters(in: .whitespaces)
                    let epUrl = String(trimmed[separator...].dropFirst())
                        .trimmingCharacters(in: .whitespaces)
                    if !epName.isEmpty, !epUrl.isEmpty {
                        episodes.append(VodInfo.Episode(name: epName, url: epUrl))
                    }
                } else if trimmed.isValidURL {
                    episodes.append(VodInfo.Episode(name: "第\(episodes.count + 1)集", url: trimmed))
                }
            }
            if !episodes.isEmpty {
                info.playUrlMap[flag] = episodes
            }
        }
        
        if !flags.isEmpty {
            info.playFlags = flags
            info.playFlag = flags[0]
        }
        return info
    }
    
    /// 兼容 Int/String 的值提取。
    private static func stringValue(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
}

// MARK: - Spider 相关错误

extension SourceError {
    /// Spider 脚本缺少指定函数。
    static func spiderFunctionMissing(_ name: String) -> SourceError {
        .unsupportedType("Spider 缺少函数 \(name)")
    }
    
    /// Spider 函数调用失败。
    static func spiderFunctionFailed(_ name: String) -> SourceError {
        .unsupportedType("Spider 函数 \(name) 调用失败")
    }
}
