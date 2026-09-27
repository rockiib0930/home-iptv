//
//  PlayerView.swift
//  HomeIPTV
//
//  tvOS 全屏播放器：直接用 AVKit，自动支持遥控器、直播时移、硬解
//

import SwiftUI
import AVKit

struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        // tvOS 上默认就是全屏体验
        vc.showsPlaybackControls = true
        // 直播类内容隐藏进度条拖动（更像电视）
        player.play()
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
    }
}
