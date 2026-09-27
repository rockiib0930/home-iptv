//
//  ChannelListView.swift
//  HomeIPTV
//
//  tvOS 主界面：左侧分类 + 右侧频道网格。遥控器焦点由 SwiftUI 自动处理。
//

import SwiftUI
import AVKit

struct ChannelListView: View {
    @EnvironmentObject var store: PlaylistStore
    @State private var presentingPlayer = false
    @State private var player: AVPlayer?

    private let gridColumns = [
        GridItem(.adaptive(minimum: 280), spacing: 40)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部分类选择（所有平台通用，tvOS 上为导航链接样式）
                Picker("分类", selection: $store.selectedGroup) {
                    ForEach(store.groups, id: \.self) { Text($0).tag($0) }
                }
#if os(tvOS)
                .pickerStyle(.navigationLink)
#else
                .pickerStyle(.wheel)
#endif
                .padding(.horizontal, 40)
                .padding(.top, 10)

                // 频道网格
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 40) {
                        ForEach(store.filtered) { channel in
                            ChannelCard(channel: channel) {
                                player = AVPlayer(url: channel.streamURL)
                                presentingPlayer = true
                            }
                        }
                    }
                    .padding(40)
                }
            }
            .navigationTitle("HomeIPTV · \(store.filtered.count) 个频道")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        if store.isLoading {
                            ProgressView()
                        } else {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let t = store.lastUpdated {
                        Text("更新于 \(t.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if let err = store.errorMessage, store.channels.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 60))
                        Text(err).font(.title2)
                        Button("重试") { Task { await store.refresh() } }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $presentingPlayer) {
            if let player = player {
                PlayerView(player: player)
            }
        }
        .onAppear {
            // 每 6 小时自动刷新一次
            Timer.scheduledTimer(withTimeInterval: store.refreshInterval, repeats: true) { _ in
                Task { await store.refresh() }
            }
        }
    }
}

struct ChannelCard: View {
    let channel: Channel
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                AsyncImage(url: channel.logoURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Rectangle().foregroundStyle(.tertiary)
                }
                .frame(height: 120)
                .cornerRadius(12)

                Text(channel.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 280, height: 200)
            .padding()
            .background(.ultraThickMaterial)
            .cornerRadius(16)
        }
#if os(tvOS)
        .buttonStyle(.card)
#else
        .buttonStyle(.plain)
#endif
    }
}
