import Foundation
import JavaScriptCore

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
        
        let script = try await NetworkManager.shared.getString(from: api)
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
                        ?? String(data: data, encoding: .gbk)
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
