//
//  ChannelTile.swift
//  HomeIPTV
//
//  频道卡片 + 台标。
//
//  关于台标：原来直接用 m3u 里的 tvg-logo，而这些 logo 几乎全指向
//  i.imgur.com —— 在国内**完全拉不到**（实测 0.3 秒直接失败），于是整屏都是
//  灰方块，这也是"巨丑"的主要来源之一。
//
//  现在的做法：先用频道名**本地画一个台标**（渐变底 + 简称），一定画得出来、
//  不依赖网络；远程 logo 只在真的加载成功时才盖上去。
//

import SwiftUI

struct ChannelTile: View {
    let channel: Channel
    let isFavorite: Bool
    let onPlay: (Int) -> Void          // 以第几条线路播放
    let onToggleFavorite: () -> Void

    private var subtitle: String {
        var parts: [String] = []
        parts.append(Palette.groupDisplayName(channel.group))
        if channel.sources.count > 1 { parts.append("\(channel.sources.count) 条线路") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button {
            onPlay(0)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    ChannelLogo(name: channel.name, remoteURL: channel.logoURL)
                        .frame(width: 88, height: 88)
                    VStack(alignment: .trailing, spacing: 6) {
                        if !channel.qualityLabel.isEmpty {
                            Badge(text: channel.qualityLabel, tint: .green)
                        }
                        if channel.sources.count > 1 {
                            Badge(text: "\(channel.sources.count) 线路", tint: .blue)
                        }
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.yellow)
                        }
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
                Text(channel.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(18)
            .frame(width: 320, height: 220, alignment: .topLeading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.card)
        .contextMenu {
            Button(isFavorite ? "取消收藏" : "收藏") { onToggleFavorite() }
            if channel.sources.count > 1 {
                ForEach(Array(channel.sources.prefix(4).enumerated()), id: \.element.id) { index, source in
                    Button(source.label(index: index)) { onPlay(index) }
                }
            }
        }
    }
}

struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.28), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// 本地绘制的台标：渐变底 + 频道简称。
/// 远程 logo 只在加载成功时显示（失败就保持本地绘制，不出现灰块）。
struct ChannelLogo: View {
    let name: String
    let remoteURL: URL?
    @State private var remoteImage: Image?

    var body: some View {
        ZStack {
            LinearGradient(colors: Palette.colors(for: name),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let remoteImage {
                remoteImage
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
                    .padding(4)
            } else {
                let badge = Palette.badge(for: name)
                VStack(spacing: -2) {
                    if !badge.prefix.isEmpty {
                        Text(badge.prefix)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .opacity(0.85)
                    }
                    Text(badge.main)
                        .font(.system(size: badge.prefix.isEmpty ? 30 : 34,
                                      weight: .heavy, design: .rounded))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .task(id: remoteURL) {
            guard let remoteURL else { return }
            // 3 秒拿不到就算（国内很多 logo 域名压根不通），不拖慢界面
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = 3
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let ui = UIImage(data: data) else { return }
            remoteImage = Image(uiImage: ui)
        }
    }
}

/// 从名字稳定地推出配色与简称（同一个频道每次都是同一个样子）
enum Palette {
    static let palettes: [(Color, Color)] = [
        (Color(red: 0.20, green: 0.42, blue: 0.85), Color(red: 0.10, green: 0.20, blue: 0.55)),
        (Color(red: 0.80, green: 0.25, blue: 0.30), Color(red: 0.45, green: 0.10, blue: 0.22)),
        (Color(red: 0.15, green: 0.55, blue: 0.45), Color(red: 0.05, green: 0.28, blue: 0.26)),
        (Color(red: 0.55, green: 0.32, blue: 0.80), Color(red: 0.28, green: 0.14, blue: 0.48)),
        (Color(red: 0.85, green: 0.50, blue: 0.15), Color(red: 0.50, green: 0.24, blue: 0.05)),
        (Color(red: 0.25, green: 0.30, blue: 0.40), Color(red: 0.12, green: 0.15, blue: 0.22)),
    ]

    static func colors(for name: String) -> [Color] {
        let pair = palettes[abs(name.hashValue) % palettes.count]
        return [pair.0, pair.1]
    }

    /// 台标文字。CCTV-1 / CCTV-13 这类"字母+数字"的名字拆成
    /// 小字前缀 + 大字编号（就像真实台标那样好认），中文取前两字，
    /// 其余取前三个字母。
    static func badge(for name: String) -> (prefix: String, main: String) {
        let cjk = name.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }
        if cjk.count >= 2 {
            return ("", String(String.UnicodeScalarView(cjk.prefix(2))))
        }
        // 字母开头 + 数字编号：CCTV-1、CCTV5+、BTV-2 …
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let letters = trimmed.prefix { $0.isLetter }
        let rest = trimmed.dropFirst(letters.count)
        let number = rest.drop { $0 == "-" || $0 == " " }
        if !letters.isEmpty, number.first?.isNumber == true {
            let digits = number.prefix { $0.isNumber || $0 == "+" }
            return (String(letters.prefix(4)).uppercased(), String(digits))
        }
        let ascii = trimmed.uppercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII
        }
        if ascii.isEmpty { return ("", name.isEmpty ? "?" : String(name.prefix(2))) }
        return ("", String(String.UnicodeScalarView(ascii.prefix(3))))
    }

    /// 分组显示名：上游 iptv-org 的分组是英文，中文界面下统一成中文
    static func groupDisplayName(_ group: String) -> String {
        let map = [
            "General": "综合", "News": "新闻", "Movies": "电影", "Sports": "体育",
            "Education": "教育", "Music": "音乐", "Documentary": "纪实",
            "Culture": "文化", "Lifestyle": "生活", "Business": "财经",
            "Kids": "少儿", "Entertainment": "娱乐", "Family": "家庭",
            "Religious": "宗教", "Science": "科学", "Travel": "旅游",
            "Cooking": "美食", "Shop": "购物", "Weather": "天气",
            "Undefined": "未分类", "Auto": "汽车", "Animation": "动漫",
            "Classic": "经典", "Comedy": "喜剧", "Series": "剧集",
            "Outdoor": "户外", "Politics": "时政", "Legislative": "政务",
            "Local": "地方", "Relax": "休闲",
        ]
        return map[group] ?? group
    }
}
