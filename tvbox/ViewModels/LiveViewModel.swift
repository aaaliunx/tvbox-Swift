import Foundation
import SwiftUI
import Combine

/// 直播 ViewModel
@MainActor
class LiveViewModel: ObservableObject {
    /// 全部频道分组。
    @Published var channelGroups: [LiveChannelGroup] = []
    /// 当前选中分组索引。
    @Published var selectedGroupIndex: Int = 0
    /// 当前选中频道索引（相对于当前分组）。
    @Published var selectedChannelIndex: Int = 0
    /// 当前播放频道。
    @Published var currentChannel: LiveChannelItem?
    /// 当前频道节目单（预留）。
    @Published var epgList: [Epginfo] = []
    /// 加载状态（预留，便于后续接入远程 EPG）。
    @Published var isLoading = false
    /// 是否显示频道列表（预留给 TV 遥控交互）。
    @Published var showChannelList = false
    
    /// 订阅配置更新，支持直播频道列表实时刷新。
    private var cancellables: Set<AnyCancellable> = []
    
    init() {
        bindLiveChannelGroups()
    }
    
    /// 加载直播频道
    func loadChannels() {
        applyChannelGroups(ApiConfig.shared.liveChannelGroupList)
    }
    
    /// 选择频道分组
    func selectGroup(_ index: Int) {
        guard index >= 0, index < channelGroups.count else { return }
        selectedGroupIndex = index
        selectedChannelIndex = 0
        if let first = channelGroups[index].channels.first {
            selectChannel(first)
        }
    }
    
    /// 选择频道
    func selectChannel(_ channel: LiveChannelItem) {
        currentChannel = channel
        loadEPG(for: channel)
    }
    
    /// 上一个频道
    func previousChannel() {
        guard !channelGroups.isEmpty else { return }
        if selectedChannelIndex > 0 {
            selectedChannelIndex -= 1
        } else if selectedGroupIndex > 0 {
            selectedGroupIndex -= 1
            selectedChannelIndex = channelGroups[selectedGroupIndex].channels.count - 1
        }
        if let ch = channelGroups[selectedGroupIndex].channels[safe: selectedChannelIndex] {
            selectChannel(ch)
        }
    }
    
    /// 下一个频道
    func nextChannel() {
        guard !channelGroups.isEmpty else { return }
        let group = channelGroups[selectedGroupIndex]
        if selectedChannelIndex < group.channels.count - 1 {
            selectedChannelIndex += 1
        } else if selectedGroupIndex < channelGroups.count - 1 {
            selectedGroupIndex += 1
            selectedChannelIndex = 0
        }
        if let ch = channelGroups[selectedGroupIndex].channels[safe: selectedChannelIndex] {
            selectChannel(ch)
        }
    }
    
    /// 切换线路
    func switchSource() {
        // `currentChannel` 为值类型，调用 mutating 方法会触发 @Published 重新发布。
        currentChannel?.nextSource()
    }
    
    /// 当前频道列表
    var currentChannels: [LiveChannelItem] {
        guard selectedGroupIndex < channelGroups.count else { return [] }
        return channelGroups[selectedGroupIndex].channels
    }
    
    /// 加载 EPG 节目单（xmltv）。
    /// 取频道自带 epg 地址，拉取后按频道名匹配当天节目。
    private func loadEPG(for channel: LiveChannelItem) {
        epgList = []
        let epgUrl = channel.epg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !epgUrl.isEmpty,
              let url = URL(string: epgUrl) else { return }
        
        let channelKey = channel.channelName
        Task.detached(priority: .utility) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let parser = EPGXMLParser()
                parser.parse(data: data)
                
                let today = Self.epgTodayString()
                let matched = parser.programmes.filter { programme in
                    Self.epgChannelMatches(programme.channelId, channelName: channelKey)
                        && programme.startDate == today
                }
                let items: [Epginfo] = matched.enumerated().map { index, programme in
                    Epginfo(
                        title: programme.title,
                        startTime: programme.startTime,
                        endTime: programme.endTime,
                        index: index
                    )
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // 频道可能已切换，仅当仍是当前频道时更新。
                    if self.currentChannel?.channelName == channelKey {
                        self.epgList = items
                    }
                }
            } catch {
                print("EPG 加载失败: \(error)")
            }
        }
    }
    
    /// 今天日期字符串（yyyyMMdd，本地时区）。
    nonisolated private static func epgTodayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: Date())
    }
    
    /// EPG 频道与配置频道名匹配：相同、互相包含（去空白与常见符号）。
    nonisolated private static func epgChannelMatches(_ epgId: String, channelName: String) -> Bool {
        let a = epgId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = channelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        return a.contains(b) || b.contains(a)
    }
    
    private func bindLiveChannelGroups() {
        ApiConfig.shared.$liveChannelGroupList
            .sink { [weak self] groups in
                self?.applyChannelGroups(groups)
            }
            .store(in: &cancellables)
    }
    
    private func applyChannelGroups(_ groups: [LiveChannelGroup]) {
        let previousChannelId = currentChannel?.id
        channelGroups = groups
        
        guard !groups.isEmpty else {
            selectedGroupIndex = 0
            selectedChannelIndex = 0
            currentChannel = nil
            return
        }
        
        if let previousChannelId,
           let located = locateChannel(withId: previousChannelId, in: groups) {
            selectedGroupIndex = located.groupIndex
            selectedChannelIndex = located.channelIndex
            currentChannel = groups[located.groupIndex].channels[located.channelIndex]
            return
        }
        
        let clampedGroupIndex = min(max(0, selectedGroupIndex), groups.count - 1)
        selectedGroupIndex = clampedGroupIndex
        
        let channels = groups[clampedGroupIndex].channels
        guard !channels.isEmpty else {
            selectedChannelIndex = 0
            currentChannel = nil
            return
        }
        
        let clampedChannelIndex = min(max(0, selectedChannelIndex), channels.count - 1)
        selectedChannelIndex = clampedChannelIndex
        currentChannel = channels[clampedChannelIndex]
    }
    
    private func locateChannel(
        withId channelId: String,
        in groups: [LiveChannelGroup]
    ) -> (groupIndex: Int, channelIndex: Int)? {
        for (groupIndex, group) in groups.enumerated() {
            if let channelIndex = group.channels.firstIndex(where: { $0.id == channelId }) {
                return (groupIndex, channelIndex)
            }
        }
        return nil
    }
}

// 安全数组下标访问
extension Collection {
    /// 安全下标读取，越界时返回 `nil`。
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
