import Foundation
import Network
import Combine

/// 局域网遥控服务：在设备上启动一个迷你 HTTP 服务，
/// 同一局域网的浏览器访问即可遥控本机播放（对齐 Android 版 AVBox 的遥控能力）。
/// 端点：
///   GET /              状态页（HTML）
///   GET /play?url=xxx  播放指定地址（通知 DetailView）
///   GET /pause         暂停
///   GET /resume        继续播放
///   GET /vol?level=60  音量（0-100）
/// 通知通过 NotificationCenter 发出，由视图层订阅执行。
final class RemoteControlService: ObservableObject {
    static let shared = RemoteControlService()
    
    /// 遥控播放请求通知（userInfo: ["url": String]）。
    static let playRequestNotification = Notification.Name("RemoteControlPlayRequest")
    /// 暂停请求通知。
    static let pauseRequestNotification = Notification.Name("RemoteControlPauseRequest")
    /// 继续播放请求通知。
    static let resumeRequestNotification = Notification.Name("RemoteControlResumeRequest")
    /// 音量请求通知（userInfo: ["level": Int]）。
    static let volumeRequestNotification = Notification.Name("RemoteControlVolumeRequest")
    
    @Published var isRunning = false
    /// 供设置页展示的访问地址（http://设备IP:端口）。
    @Published var accessURL: String = ""
    /// 当前播放地址（状态页展示用）。
    var currentPlayURL: String = ""
    
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    
    private init() {}
    
    // MARK: - 启停
    
    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: 8765)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.publishAccessURL()
                case .failed(let error):
                    print("[RemoteControl] 监听失败: \(error)")
                    self?.stop()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
            isRunning = true
        } catch {
            print("[RemoteControl] 启动失败: \(error)")
        }
    }
    
    func stop() {
        connections.forEach { $0.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
        accessURL = ""
    }
    
    // MARK: - HTTP 处理
    
    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .global(qos: .userInitiated))
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            
            var response = self.route(requestData: data)
            if response.data.isEmpty {
                response = Self.htmlResponse(body: "<h1>TVBox Remote</h1><p>No route.</p>", status: 404)
            }
            response.headers["Content-Length"] = "\(response.data.count)"
            response.headers["Connection"] = "close"
            
            let headerText = "HTTP/1.1 \(response.status) \(response.reason)\r\n" +
                response.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") +
                "\r\n\r\n"
            let fullData = (headerText.data(using: .utf8) ?? Data()) + response.data
            
            connection.send(content: fullData, completion: .contentProcessed { _ in
                connection.cancel()
            })
            
            if isComplete || error != nil {
                connection.cancel()
            }
        }
    }
    
    /// 简单路由。
    private func route(requestData: Data) -> (status: Int, reason: String, headers: [String: String], data: Data) {
        guard let requestLine = String(data: requestData, encoding: .utf8)?.components(separatedBy: "\r\n").first else {
            return (400, "Bad Request", [:], Data())
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return (400, "Bad Request", [:], Data()) }
        let method = String(parts[0]).uppercased()
        let pathWithQuery = String(parts[1])
        guard method == "GET" else { return (405, "Method Not Allowed", [:], Data()) }
        
        let urlComponents = pathWithQuery.components(separatedBy: "?")
        let path = urlComponents.first ?? "/"
        let query = parseQuery(urlComponents.count > 1 ? urlComponents[1] : "")
        
        switch path {
        case "/":
            let body = statusPageHTML(query: query)
            return (200, "OK", ["Content-Type": "text/html; charset=utf-8"], Data(body.utf8))
        case "/play":
            guard let url = query["url"], !url.isEmpty else { return (400, "Bad Request", [:], Data()) }
            currentPlayURL = url
            NotificationCenter.default.post(
                name: Self.playRequestNotification,
                object: nil,
                userInfo: ["url": url]
            )
            let body = "<h1>OK</h1><p>正在播放：\(url.htmlEscaped)</p>"
            return (200, "OK", ["Content-Type": "text/html; charset=utf-8"], Data(body.utf8))
        case "/pause":
            NotificationCenter.default.post(name: Self.pauseRequestNotification, object: nil)
            return (200, "OK", ["Content-Type": "text/html; charset=utf-8"], Data("<h1>已暂停</h1>".utf8))
        case "/resume":
            NotificationCenter.default.post(name: Self.resumeRequestNotification, object: nil)
            return (200, "OK", ["Content-Type": "text/html; charset=utf-8"], Data("<h1>继续播放</h1>".utf8))
        case "/vol":
            let level = Int(query["level"] ?? "") ?? -1
            guard level >= 0, level <= 100 else { return (400, "Bad Request", [:], Data()) }
            NotificationCenter.default.post(
                name: Self.volumeRequestNotification,
                object: nil,
                userInfo: ["level": level]
            )
            return (200, "OK", ["Content-Type": "text/html; charset=utf-8"], Data("<h1>音量 \(level)%</h1>".utf8))
        default:
            return (404, "Not Found", [:], Data())
        }
    }
    
    private func parseQuery(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            guard kv.count == 2 else { continue }
            let key = kv[0].removingPercentEncoding ?? kv[0]
            let value = kv[1].removingPercentEncoding ?? kv[1]
            result[key] = value
        }
        return result
    }
    
    private func statusPageHTML(query: [String: String]) -> String {
        let playURL = query["url"] ?? ""
        let playForm = playURL.isEmpty
            ? "<form action='/play' method='get'><input name='url' placeholder='粘贴播放地址' style='width:90%;padding:8px'/><br/><br/><button type='submit' style='padding:8px 24px'>播放</button></form>"
            : "<form action='/play' method='get'><input name='url' value='\(playURL.htmlEscaped)' style='width:90%;padding:8px'/><br/><br/><button type='submit' style='padding:8px 24px'>播放</button></form>"
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>TVBox Remote</title>
        <style>
        body{font-family:-apple-system,sans-serif;background:#111;color:#fff;padding:24px}
        a{display:inline-block;color:#fff;background:#f57c00;padding:12px 28px;border-radius:10px;margin:6px;text-decoration:none;font-size:16px}
        .now{color:#ff9800;word-break:break-all}
        </style></head><body>
        <h2>TVBox 遥控</h2>
        <p>当前播放：<span class="now">\(currentPlayURL.htmlEscaped.isEmpty ? "无" : currentPlayURL.htmlEscaped)</span></p>
        \(playForm)
        <p><a href="/pause">暂停</a><a href="/resume">继续</a></p>
        <p><a href="/vol?level=0">音量 0</a><a href="/vol?level=50">50</a><a href="/vol?level=100">100</a></p>
        </body></html>
        """
    }
    
    private func publishAccessURL() {
        // 常见局域网网段提示：优先用本机 IP。
        let ip = Self.currentIPAddress() ?? "127.0.0.1"
        accessURL = "http://\(ip):8765"
    }
    
    /// 获取本机局域网 IP（en0 网卡，IPv4）。
    private static func currentIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "pdp_ip0" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count),
                        nil, 0, NI_NUMERICHOST
                    ) == 0 {
                        address = String(cString: host)
                        break
                    }
                }
            }
            cursor = interface.ifa_next
        }
        return address
    }
    
    private static func htmlResponse(body: String, status: Int) -> (status: Int, reason: String, headers: [String: String], data: Data) {
        return (status, status == 200 ? "OK" : "Error", ["Content-Type": "text/html; charset=utf-8"], Data(body.utf8))
    }
}

private extension String {
    /// HTML 转义（遥控状态页用）。
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
