//
//  Channel.swift
//  HomeIPTV
//
//  频道数据模型 + M3U 解析器（纯 Swift，无第三方依赖）
//

import Foundation

struct Channel: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var logoURL: URL?
    var group: String
    var streamURL: URL

    init(name: String, logoURL: URL?, group: String, streamURL: URL) {
        self.id = UUID()
        self.name = name
        self.logoURL = logoURL
        self.group = group
        self.streamURL = streamURL
    }

    // Hashable：用于列表 diff
    static func == (lhs: Channel, rhs: Channel) -> Bool {
        lhs.streamURL == rhs.streamURL
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(streamURL)
    }
}

enum M3UParser {
    /// 解析 M3U 文本为频道数组
    /// 标准格式：
    /// #EXTINF:-1 tvg-id="..." tvg-logo="..." group-title="News",CCTV-1
    /// https://example.com/live.m3u8
    static func parse(text: String) -> [Channel] {
        let lines = text.components(separatedBy: .newlines)
        var channels: [Channel] = []
        var pendingName: String?
        var pendingLogo: URL?
        var pendingGroup: String = "未分类"

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTINF:") {
                // 形如：#EXTINF:-1 tvg-logo="http://.." group-title="News",Channel Name
                // 先去掉前缀
                let afterPrefix = String(line.dropFirst("#EXTINF:".count))
                // 按最后一个逗号拆属性和名称
                if let commaRange = afterPrefix.range(of: ",", options: .backwards) {
                    let attrsPart = String(afterPrefix[..<commaRange.lowerBound])
                    let namePart = String(afterPrefix[commaRange.upperBound...]).trimmingCharacters(in: .whitespaces)

                    pendingName = namePart
                    pendingLogo = extractAttribute(attrsPart, key: "tvg-logo").flatMap { URL(string: $0) }
                    pendingGroup = extractAttribute(attrsPart, key: "group-title") ?? "未分类"
                }
            } else if line.hasPrefix("#") {
                // 其他标签（#EXTGRP 等）忽略
                continue
            } else if let name = pendingName, let url = URL(string: line) {
                // 这一行是流地址
                channels.append(Channel(
                    name: name,
                    logoURL: pendingLogo,
                    group: pendingGroup,
                    streamURL: url
                ))
                pendingName = nil
                pendingLogo = nil
                pendingGroup = "未分类"
            }
        }
        return channels
    }

    /// 从属性串里提取 key="value"
    private static func extractAttribute(_ attrs: String, key: String) -> String? {
        // 简单状态机解析，避免正则在 tvOS 上的兼容问题
        let scanner = attrs
        let needle = "\(key)=\""
        guard let range = scanner.range(of: needle) else { return nil }
        let start = range.upperBound
        guard let end = scanner[start...].range(of: "\"") else { return nil }
        return String(scanner[start..<end.lowerBound])
    }
}
