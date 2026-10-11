//
//  ChannelListView.swift
//  HomeIPTV
//
//  主界面：左侧分类栏 + 右侧频道墙（Apple TV 上常见的布局）。
//
//  2026-10-11 改版要点（对应反馈）：
//  * "界面巨丑"：频道卡片改成有层次的信息块——本地绘制的台标、清晰度/国内标签、
//    线路条数，不再是纯文字加一个灰方块；
//  * "交互不便"：分类变成常驻侧栏（不用先进 Picker 再退回），长按卡片可以
//    收藏或直接指定线路；
//  * "频道重复"：列表按逻辑频道去重，一个频道只有一张卡片；
//  * "加载缓慢"：先用缓存/内置快照出画面，网络刷新在后台；加载中有明确提示。
//

import SwiftUI

struct ChannelListView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var playback: PlaybackController
    @State private var showingAbout = false

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 24)]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .background(Color.black)
        .sheet(isPresented: $showingAbout) { AboutView() }
        .task { await store.start() }
        .onChange(of: playback.isPresenting) { presenting in
            if presenting { showingAbout = false }
        }
    }

    // MARK: - 左侧分类

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("HomeIPTV")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 20)

            // tvOS 上 List(selection:) 不可用（走焦点导航），所以侧栏用一组
            // 可聚焦按钮实现；焦点上下移动由系统处理，选中即切分类。
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.groups, id: \.self) { group in
                        Button {
                            store.selectedGroup = group
                        } label: {
                            HStack(spacing: 10) {
                                Text(groupLabel(group))
                                    .font(.system(size: 22, weight: store.selectedGroup == group ? .semibold : .regular))
                                Spacer(minLength: 0)
                                if store.selectedGroup == group {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }

            Button { showingAbout = true } label: {
                Label("关于与隐私", systemImage: "info.circle")
                    .font(.footnote)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }

    private var statusLine: String {
        if store.isLoading { return store.statusText.isEmpty ? "正在加载…" : store.statusText }
        if let updated = store.lastUpdated {
            let time = updated.formatted(date: .omitted, time: .shortened)
            return "\(store.channels.count) 个频道 · \(store.sourceCount) 条线路 · 更新于 \(time)"
        }
        return "\(store.channels.count) 个频道 · \(store.sourceCount) 条线路"
    }

    private func groupLabel(_ group: String) -> String {
        switch group {
        case PlaylistStore.allKey: return "全部（\(store.channels.count)）"
        case PlaylistStore.favoritesKey: return "收藏（\(store.favorites.count)）"
        case PlaylistStore.multiSourceKey: return "多线路（\(store.multiSourceCount)）"
        default:
            let count = store.channels.filter { $0.group == group }.count
            return "\(Palette.groupDisplayName(group))（\(count)）"
        }
    }

    // MARK: - 右侧内容

    private var content: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                ForEach(store.filtered) { channel in
                    ChannelTile(
                        channel: channel,
                        isFavorite: store.isFavorite(channel),
                        onPlay: { index in
                            playback.play(channel: channel, sourceIndex: index)
                        },
                        onToggleFavorite: { store.toggleFavorite(channel) }
                    )
                }
            }
            .padding(40)
        }
        .overlay { emptyState }
        .overlay(alignment: .top) { loadingBanner }
        .fullScreenCover(isPresented: playerPresentation) {
            PlayerContainer(playback: playback)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.filtered.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: store.channels.isEmpty ? "antenna.radiowaves.left.and.right.slash" : "magnifyingglass")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text(store.channels.isEmpty ? (store.errorMessage ?? "正在加载频道…") : "这个分类下没有频道")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                if store.channels.isEmpty, store.errorMessage != nil {
                    Button("重试") { Task { await store.refresh() } }
                }
            }
            .padding(40)
        }
    }

    @ViewBuilder
    private var loadingBanner: some View {
        if store.isLoading {
            HStack(spacing: 10) {
                ProgressView()
                Text(store.statusText.isEmpty ? "正在加载…" : store.statusText)
                    .font(.footnote)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 16)
        }
    }

    /// 关闭播放页一律走 stop()：这是"机顶盒关不掉"故障的修复点之一
    private var playerPresentation: Binding<Bool> {
        Binding(
            get: { playback.isPresenting },
            set: { presented in
                if !presented { playback.stop(reason: "player dismissed") }
            }
        )
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    private let privacyURL = URL(string: "https://paste.rs/gH4A6")!

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("HomeIPTV")
                .font(.largeTitle.bold())
            Text("""
            只做一件事：把公开的直播源聚合成一个列表，在你的 Apple TV 上播放。

            · 不收集任何数据，没有账号，没有统计 SDK
            · 频道列表来自公开的 iptv-org 等项目，每 6 小时自动更新一次
            · 播放全部在本机完成，App 不上传任何东西
            · 直播源由第三方提供，可用性会随时间变化；同一频道有多条线路时会自动切换
            """)
            .font(.body)
            .foregroundStyle(.secondary)
            Link("查看完整隐私政策", destination: privacyURL)
            Button("好") { dismiss() }
        }
        .padding(60)
        .frame(width: 900)
    }
}
