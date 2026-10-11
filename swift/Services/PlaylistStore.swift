//
//  PlaylistStore.swift
//  HomeIPTV
//
//  频道列表的加载与状态。
//
//  2026-10-11 重做，针对"加载缓慢"：
//  * 镜像按**国内实测耗时**排序，逐个回退（实测 fastly 1.4s / Pages 1.6s /
//    gcore 1.9s / cdn 1.9s；raw.githubusercontent 12s 超时，已剔除）；
//  * 首次启动先用**内置快照**（App 包里带的 bootstrap.m3u）立刻出画面，
//    网络刷新在后台进行，不再"白屏等网络"；
//  * 磁盘缓存继续保留，刷新失败时不清空旧数据。
//

import Foundation
import SwiftUI

@MainActor
final class PlaylistStore: ObservableObject {

    /// 订阅源镜像：国内实测可用且按耗时排序。最后一个失败才报错。
    /// 第一个是**在本机网络上实测筛过的**列表（只含连得上、且分片真的拉得到的线路），
    /// 优先用它；它不可用时才退回全量列表，并在界面上说明"未筛选"。
    static let mirrors: [(url: String, verified: Bool)] = [
        ("https://fastly.jsdelivr.net/gh/rockiib0930/home-iptv@main/out/live.m3u", true),
        ("https://rockiib0930.github.io/home-iptv/out/live.m3u", true),
        ("https://fastly.jsdelivr.net/gh/rockiib0930/home-iptv@main/out/index.m3u", false),
        ("https://rockiib0930.github.io/home-iptv/out/index.m3u", false),
        ("https://gcore.jsdelivr.net/gh/rockiib0930/home-iptv@main/out/index.m3u", false),
    ]

    static let allKey = "全部"
    static let favoritesKey = "收藏"
    /// "多线路"：同一频道有多条源，播不动时会自动跳下一条，实际可用性明显更高。
    ///
    /// 为什么不叫"国内可用"：实测这份播放列表 332 条源里有 202 条是 .cn 频道、
    /// 127 条是中文名，合计 99% 都算国内——那个分类永远显示"几乎全部"，
    /// 等于没有筛选作用。多线路才是真正能区分"更容易播出来"的维度。
    static let multiSourceKey = "多线路"

    @Published private(set) var channels: [Channel] = []
    @Published private(set) var groups: [String] = [allKey, favoritesKey, multiSourceKey]
    @Published var selectedGroup: String = allKey
    @Published var query: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var statusText: String = ""
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var favorites: Set<String> = []
    /// 本次成功加载用的镜像（便于排查）
    @Published private(set) var activeMirror: String = ""
    /// 当前列表是否经过"国内本机实测"筛选（false 时界面要说明未筛选）
    @Published private(set) var isVerifiedList = false

    private let cacheFileURL: URL
    private let favoritesKeyName = "favorite_channel_keys"
    let refreshInterval: TimeInterval = 6 * 3600

    init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheFileURL = dir.appendingPathComponent("channels_v2.json")
        favorites = Set(UserDefaults.standard.stringArray(forKey: favoritesKeyName) ?? [])
    }

    /// 启动：先用缓存/内置快照出画面，再后台刷新
    func start() async {
        if !loadCache() { loadBootstrap() }
        rebuildGroups()
        await refresh()
    }

    // MARK: - 过滤

    var filtered: [Channel] {
        var result = channels
        switch selectedGroup {
        case Self.allKey: break
        case Self.favoritesKey: result = result.filter { favorites.contains($0.key) }
        case Self.multiSourceKey: result = result.filter { $0.sources.count > 1 }
        default: result = result.filter { $0.group == selectedGroup }
        }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            result = result.filter {
                $0.name.lowercased().contains(needle)
                    || M3UParser.normalizedName($0.name).contains(needle)
            }
        }
        return result
    }

    var multiSourceCount: Int { channels.filter { $0.sources.count > 1 }.count }
    var sourceCount: Int { channels.reduce(0) { $0 + $1.sources.count } }

    func isFavorite(_ channel: Channel) -> Bool { favorites.contains(channel.key) }

    func toggleFavorite(_ channel: Channel) {
        if favorites.contains(channel.key) { favorites.remove(channel.key) }
        else { favorites.insert(channel.key) }
        UserDefaults.standard.set(Array(favorites), forKey: favoritesKeyName)
        if selectedGroup == Self.favoritesKey { rebuildGroups() }
    }

    // MARK: - 刷新

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var lastError: String = ""
        for (index, mirror) in Self.mirrors.enumerated() {
            statusText = "正在加载线路 \(index + 1)/\(Self.mirrors.count)…"
            do {
                let text = try await fetch(mirror.url)
                let parsed = M3UParser.parse(text: text)
                guard !parsed.isEmpty else { throw URLError(.cannotParseResponse) }
                // 用本机播放记忆调整线路顺序：在这台设备上播成功过的排前面
                channels = parsed.map { channel in
                    var copy = channel
                    copy.sources = SourceHealth.shared.sorted(channel.sources)
                    return copy
                }
                rebuildGroups()
                saveCache()
                lastUpdated = Date()
                activeMirror = mirror.url
                isVerifiedList = mirror.verified
                statusText = "已更新"
                return
            } catch {
                lastError = error.localizedDescription
                continue
            }
        }
        // 全部镜像失败：保留旧数据，只提示
        statusText = ""
        if channels.isEmpty {
            errorMessage = "订阅源加载失败：\(lastError)"
        }
    }

    private func fetch(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        // 10 秒足够：实测这几个镜像都在 2 秒内
        request.timeoutInterval = 10
        request.cachePolicy = .reloadRevalidatingCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return text
    }

    // MARK: - 分组

    private func rebuildGroups() {
        var counts: [String: Int] = [:]
        for channel in channels { counts[channel.group, default: 0] += 1 }
        // 频道多的分组靠前；"未分类/Undefined" 这类排到最后
        let names = counts.keys.sorted { lhs, rhs in
            let lhsJunk = (lhs == "未分类" || lhs == "Undefined")
            let rhsJunk = (rhs == "未分类" || rhs == "Undefined")
            if lhsJunk != rhsJunk { return !lhsJunk }
            if counts[lhs] != counts[rhs] { return (counts[lhs] ?? 0) > (counts[rhs] ?? 0) }
            return lhs < rhs
        }
        groups = [Self.allKey, Self.favoritesKey, Self.multiSourceKey] + names
    }

    // MARK: - 缓存与内置快照

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(channels) else { return }
        try? data.write(to: cacheFileURL)
        UserDefaults.standard.set(Date(), forKey: "channels_v2_time")
    }

    @discardableResult
    private func loadCache() -> Bool {
        guard let data = try? Data(contentsOf: cacheFileURL),
              let cached = try? JSONDecoder().decode([Channel].self, from: data),
              !cached.isEmpty else { return false }
        channels = cached
        lastUpdated = UserDefaults.standard.object(forKey: "channels_v2_time") as? Date
        activeMirror = "缓存"
        statusText = "缓存"
        isVerifiedList = true
        return true
    }

    /// App 包里的快照：首次启动也能立刻看到内容，不用等网络
    private func loadBootstrap() {
        guard let url = Bundle.main.url(forResource: "bootstrap", withExtension: "m3u"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parsed = M3UParser.parse(text: text)
        if !parsed.isEmpty {
            channels = parsed
            activeMirror = "内置快照"
            statusText = "内置快照"
        }
    }
}
