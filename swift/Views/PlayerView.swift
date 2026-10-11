//
//  PlayerView.swift
//  HomeIPTV
//
//  tvOS 全屏播放器。AVKit 负责视频与遥控器，本文件只加一层"这条线在放什么"的信息条。
//
//  信息条会自动淡出（大约 6 秒），不干扰观看；正在自动换线时会显示原因。
//  这里不做任何"保持会话"的设置，也不设置 isIdleTimerDisabled：
//  播放的收尾一律由 PlaybackController.stop() 负责（见故障记录文档）。
//

import AVKit
import SwiftUI

struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let playback: PlaybackController

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        // 画中画是"离开前台还在出声"的另一条路径，本 App 明确关掉
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
    }
}

/// 播放页外层的 SwiftUI 容器：AVKit 的播放器 + 一条会自动淡出的信息条
struct PlayerContainer: View {
    @ObservedObject var playback: PlaybackController

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let player = playback.player {
                PlayerView(player: player, playback: playback)
                    .ignoresSafeArea()
            }
            if playback.isShowingInfo {
                InfoBanner(playback: playback)
                    .padding(48)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: playback.isShowingInfo)
    }
}

private struct InfoBanner: View {
    @ObservedObject var playback: PlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(playback.channelName)
                .font(.title2.bold())
            HStack(spacing: 8) {
                if playback.sourceCount > 1 {
                    Badge(text: "\(playback.sourceIndex + 1)/\(playback.sourceCount) 线路", tint: .blue)
                }
                Text(playback.sourceLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let notice = playback.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if playback.sourceCount > 1 {
                Text("长按遥控器 → 选择 可切换线路")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
