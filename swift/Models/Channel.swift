//
//  Channel.swift
//  HomeIPTV
//
//  频道数据模型 + M3U 解析器（纯 Swift，无第三方依赖）。
//
//  2026-10-11 重做：原来的模型是"一条 m3u 行 = 一个频道"，于是同一个 CCTV-1
//  有 5 条源就显示成 5 张一模一样的卡片（反馈里的"频道重复"），而且没有任何
//  "这条线在国内能不能播"的信息。
//
//  现在按**逻辑频道**聚合：一个频道 = 一个名字 + 若干条线路（source）。
//  列表里一个频道只出现一次，播放时可以在线路之间切换/自动回退。
//

import Foundation

/// 一条播放线路。同一个频道可能有多个上游源，国内可播性差别很大，
/// 所以单独建模，而不是当作"另一个频道"。
struct StreamSource: Codable, Hashable, Identifiable {
    var url: URL
    /// 上游来源名（aggregate.py 的 name 字段）
    var provider: String
    /// "FHD" / "HD" / "4K" / "SD" / ""，来自 tvg-id 后缀或频道名后缀
    var quality: String
    /// 是否可能国内可播（中文名 / .cn 频道 / 国内域名与 IP 段）
    var isCN: Bool

    var id: String { url.absoluteString }

    /// 给用户看的线路标签
    func label(index: Int) -> String {
        var parts = ["线路 \(index + 1)"]
        if !quality.isEmpty { parts.append(quality) }
        if isCN { parts.append("国内") }
        if !provider.isEmpty { parts.append(provider) }
        return parts.joined(separator: " · ")
    }
}

/// 一个逻辑频道（一个名字，若干线路）
struct Channel: Identifiable, Codable, Hashable {
    /// 稳定标识：优先 tvg-id（去掉清晰度后缀），否则用规范化后的名字。
    /// 列表刷新前后同一频道的 identity 因此不会变。
    var key: String
    var name: String
    var logoURL: URL?
    var group: String
    var sources: [StreamSource]
    /// 至少有一条国内可能可播的线路
    var isCN: Bool

    var id: String { key }
    var primarySource: StreamSource? { sources.first }
    var qualityLabel: String { sources.first?.quality ?? "" }
    var sourceCount: Int { sources.count }
}

enum M3UParser {

    /// 解析 M3U 文本，按逻辑频道聚合后返回（顺序保持首次出现的顺序）
    static func parse(text: String) -> [Channel] {
        var merged: [String: Channel] = [:]
        var order: [String] = []
        var pending: (name: String, logo: URL?, group: String, tvgID: String, provider: String)?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#EXTM3U") { continue }

            if line.hasPrefix("#EXTINF:") {
                pending = parseExtinf(line)
            } else if line.hasPrefix("#") {
                continue  // #EXTGRP / #EXTVLCOPT 等，暂不需要
            } else if let entry = pending, let url = URL(string: line) {
                let source = StreamSource(
                    url: url,
                    provider: entry.provider,
                    quality: quality(tvgID: entry.tvgID, name: entry.name),
                    // 三条判据：中文名/中文分组、tvg-id 带 .cn（iptv-org 的国家后缀）、
                    // 或者域名/IP 看着在国内。命中任意一条即算国内线路。
                    isCN: looksChinese(text: "\(entry.name) \(entry.group)")
                        || entry.tvgID.lowercased().contains(".cn")
                        || looksChineseHost(url))
                let key = dedupeKey(tvgID: entry.tvgID, name: entry.name, group: entry.group)
                let shown = displayName(entry.name)
                if var existing = merged[key] {
                    if !existing.sources.contains(where: { $0.url == source.url }) {
                        existing.sources.append(source)
                    }
                    merged[key] = existing
                } else {
                    merged[key] = Channel(key: key, name: shown, logoURL: entry.logo,
                                          group: entry.group, sources: [source],
                                          isCN: source.isCN)
                    order.append(key)
                }
                pending = nil
            }
        }

        return order.compactMap { key -> Channel? in
            guard var channel = merged[key] else { return nil }
            channel.sources = sortedSources(channel.sources)
            channel.isCN = channel.sources.contains { $0.isCN }
            return channel
        }
    }

    // MARK: - 解析细节

    private static func parseExtinf(_ line: String)
        -> (name: String, logo: URL?, group: String, tvgID: String, provider: String) {
        let afterPrefix = String(line.dropFirst("#EXTINF:".count))
        var name = afterPrefix
        var attrs = ""
        if let comma = afterPrefix.range(of: ",", options: .backwards) {
            attrs = String(afterPrefix[..<comma.lowerBound])
            name = String(afterPrefix[comma.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return (name,
                attribute(attrs, "tvg-logo").flatMap { URL(string: $0) },
                attribute(attrs, "group-title") ?? "未分类",
                attribute(attrs, "tvg-id") ?? "",
                attribute(attrs, "tvg-name") ?? "")
    }

    /// 从属性串里提取 key="value"（自己扫，不依赖正则）
    static func attribute(_ attrs: String, _ key: String) -> String? {
        let needle = "\(key)=\""
        guard let start = attrs.range(of: needle)?.upperBound,
              let end = attrs[start...].range(of: "\"") else { return nil }
        return String(attrs[start..<end.lowerBound])
    }

    /// 聚合键：同一频道的多个源要落到同一个 key 上。
    /// tvg-id 里带清晰度后缀（CCTV1.cn@SD / @HD），去掉它才是同一个频道。
    static func dedupeKey(tvgID: String, name: String, group: String) -> String {
        if !tvgID.isEmpty {
            let base = tvgID.split(separator: "@").first.map(String.init) ?? tvgID
            return "id:" + base.lowercased()
        }
        return "name:" + normalizedName(name)
    }

    /// 名字规范化：去掉大小写、空白、标点，以及常见清晰度后缀，
    /// 让 "CCTV-1 HD" 与 "CCTV-1" 归到一起。
    static func normalizedName(_ name: String) -> String {
        var text = name.lowercased()
        for suffix in ["1080p", "720p", "4k", "uhd", "fhd", "hd", "sd", "高清", "标清", "超清"] {
            while text.hasSuffix(suffix) { text = String(text.dropLast(suffix.count)) }
        }
        let allowed = text.unicodeScalars.filter { scalar in
            !(CharacterSet.whitespacesAndNewlines.contains(scalar)
              || CharacterSet.punctuationCharacters.contains(scalar)
              || CharacterSet.symbols.contains(scalar))
        }
        return String(String.UnicodeScalarView(allowed))
    }

    /// 显示用的名字：去掉末尾的清晰度标记（"湖南卫视 HD" → "湖南卫视"），
    /// 保留原始大小写与空格。清晰度改由卡片上的标签表达，不再塞在名字里。
    static func displayName(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespaces)
        let suffixes = ["1080P", "1080p", "720P", "720p", "4K", "UHD", "FHD",
                        "HD", "SD", "高清", "标清", "超清", "hd", "sd"]
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where text.hasSuffix(suffix) {
                let trimmed = String(text.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespaces)
                // 只在剩下的名字仍然有意义时才截断（避免把名字整个吃掉）
                if trimmed.count >= 2 {
                    text = trimmed
                    changed = true
                }
            }
        }
        // 清理后可能留下尾部分隔符（"CCTV-4K HD" → "CCTV-"），一并去掉
        while let last = text.last, last == "-" || last == "·" || last == "_" || last == "/" {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// 从 tvg-id 后缀或名字里取清晰度标签
    static func quality(tvgID: String, name: String) -> String {
        let haystack = "\(tvgID) \(name)".lowercased()
        if haystack.contains("4k") || haystack.contains("uhd") { return "4K" }
        if haystack.contains("@fhd") || haystack.contains("1080p") || haystack.contains("fhd") {
            return "FHD"
        }
        if haystack.contains("@hd") || haystack.contains("高清") || haystack.contains(" hd") {
            return "HD"
        }
        if haystack.contains("@sd") || haystack.contains("标清") || haystack.contains(" sd") {
            return "SD"
        }
        return ""
    }

    /// 含 CJK 即视为国内频道
    static func looksChinese(text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    /// 判断这条线是否像"国内可播"：只看域名层面的信号。
    ///
    /// 曾经加过"IP 首段属于国内网段"的启发式，结果 216/219 个频道都被标成国内——
    /// 大量海外源也挂在那些网段上，标签就失去意义了。宁可少标也不要乱标。
    static func looksChineseHost(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        if host.isEmpty { return false }
        for marker in [".cn", ".com.cn", "cctv", "cntv", "migu", "wasu", "chinanet",
                       "cgtn", "smgbb", "huya", "douyu"] {
            if host.contains(marker) { return true }
        }
        return false
    }

    /// 线路排序：先国内，再清晰度（FHD>HD>4K>SD>无），最后按 URL 稳定排序
    static func sortedSources(_ sources: [StreamSource]) -> [StreamSource] {
        func rank(_ source: StreamSource) -> (Int, Int) {
            let qualityRank: Int
            switch source.quality {
            case "FHD": qualityRank = 0
            case "HD": qualityRank = 1
            case "4K": qualityRank = 2
            case "SD": qualityRank = 3
            default: qualityRank = 4
            }
            return (source.isCN ? 0 : 1, qualityRank)
        }
        return sources.sorted {
            let lhs = rank($0), rhs = rank($1)
            if lhs != rhs { return lhs < rhs }
            return $0.url.absoluteString < $1.url.absoluteString
        }
    }
}
