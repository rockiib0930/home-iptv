//
//  PlaylistStore.swift
//  HomeIPTV
//
//  从远程 m3u URL 拉取频道列表，缓存到 UserDefaults，支持下拉刷新/定时自动刷新
//

import Foundation
import SwiftUI

@MainActor
class PlaylistStore: ObservableObject {
    /// 默认订阅地址（部署完 GitHub Pages 后换成你自己的）
    /// 占位：https://YOUR_USERNAME.github.io/home-iptv/hd.m3u
    /// 局域网调试可换成：http://192.168.3.210:8000/hd.m3u
    @AppStorage("playlistURL") var playlistURL = "https://cdn.jsdelivr.net/gh/rockiib0930/home-iptv@main/out/index.m3u"

    @Published var channels: [Channel] = []
    @Published var groups: [String] = []
    @Published var selectedGroup: String = "全部"
    @Published var isLoading = false
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?

    private let cacheKey = "cached_channels_v1"
    let refreshInterval: TimeInterval = 6 * 3600  // 6 小时自动刷新

    init() {
        // 启动时先读缓存，再后台拉新
        loadCache()
        Task { await refresh() }
    }

    var filtered: [Channel] {
        if selectedGroup == "全部" { return channels }
        return channels.filter { $0.group == selectedGroup }
    }

    func refresh() async {
        guard let url = URL(string: playlistURL) else {
            errorMessage = "订阅地址无效"
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            let parsed = M3UParser.parse(text: text)
            channels = parsed
            rebuildGroups()
            saveCache()
            lastUpdated = Date()
        } catch {
            errorMessage = "刷新失败：\(error.localizedDescription)"
            // 失败时保留旧缓存，不清空
        }
        isLoading = false
    }

    private func rebuildGroups() {
        let set = NSMutableOrderedSet()
        channels.forEach { set.add($0.group) }
        groups = ["全部"] + (set.array as! [String])
    }

    // MARK: - 缓存（磁盘文件，避免 UserDefaults 容量限制）
    private var cacheFileURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("channels.json")
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(channels) else { return }
        try? data.write(to: cacheFileURL)
        UserDefaults.standard.set(Date(), forKey: cacheKey + "_time")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheFileURL),
              let cached = try? JSONDecoder().decode([Channel].self, from: data) else {
            return
        }
        channels = cached
        rebuildGroups()
        lastUpdated = UserDefaults.standard.object(forKey: cacheKey + "_time") as? Date
    }
}
