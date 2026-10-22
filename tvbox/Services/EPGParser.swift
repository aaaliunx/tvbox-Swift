import Foundation

/// 单个 xmltv 节目条目。
struct EPGProgramme {
    /// 频道标识（programme 的 channel 属性）。
    var channelId: String = ""
    /// 节目名称。
    var title: String = ""
    /// 节目描述。
    var desc: String = ""
    /// 节目开始日期（yyyyMMdd）。
    var startDate: String = ""
    /// 节目开始时间（HH:mm）。
    var startTime: String = ""
    /// 节目结束时间（HH:mm）。
    var endTime: String = ""
}

/// xmltv（EPG）解析器，基于 Foundation XMLParser。
/// 支持 <programme start="20260101120000 +0800" channel="CCTV1"> 结构。
final class EPGXMLParser: NSObject, XMLParserDelegate {
    private(set) var programmes: [EPGProgramme] = []
    
    private var currentElement = ""
    private var currentProgramme: EPGProgramme?
    private var currentText = ""
    private var titleText = ""
    private var descText = ""
    
    func parse(data: Data) {
        programmes = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }
    
    // MARK: - XMLParserDelegate
    
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""
        
        if elementName == "programme" {
            var programme = EPGProgramme()
            programme.channelId = attributeDict["channel"] ?? ""
            if let rawStart = attributeDict["start"] {
                (programme.startDate, programme.startTime) = Self.splitDateTime(rawStart)
            }
            if let rawStop = attributeDict["stop"] {
                programme.endTime = Self.splitDateTime(rawStop).1
            }
            currentProgramme = programme
            titleText = ""
            descText = ""
        } else if elementName == "title" && currentProgramme != nil {
            currentText = ""
        } else if elementName == "desc" && currentProgramme != nil {
            currentText = ""
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
    
    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "title", currentProgramme != nil {
            titleText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if elementName == "desc", currentProgramme != nil {
            descText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if elementName == "programme" {
            if var programme = currentProgramme {
                programme.title = titleText
                programme.desc = descText
                // 过滤无标题或无法解析时间的条目。
                if !programme.title.isEmpty, !programme.startTime.isEmpty {
                    programmes.append(programme)
                }
            }
            currentProgramme = nil
        }
        currentElement = ""
    }
    
    /// 拆分 xmltv 时间字段（如 "20260101120000 +0800"）为日期 + HH:mm。
    private static func splitDateTime(_ raw: String) -> (String, String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 12 else { return ("", "") }
        let datePart = String(trimmed.prefix(8))
        let timePart = trimmed.dropFirst(8).prefix(4)
        let hh = timePart.prefix(2)
        let mm = timePart.dropFirst(2).prefix(2)
        return (datePart, "\(hh):\(mm)")
    }
}
