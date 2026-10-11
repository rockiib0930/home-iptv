//
//  PlaybackController.swift
//  HomeIPTV
//
//  播放会话的唯一所有者。存在的理由不是"能播"，而是**能停**。
//
//  故障（2026-10-11 修复）：App 之前声明了 `UIBackgroundModes: [audio]`，
//  而且没有任何地方暂停播放器。
//
//  * 声明后台音频后，离开 App 音频仍在播；tvOS 在音频播放期间**不会休眠**，
//    于是机顶盒表现为"关不掉"——按电源/睡眠，声音还在，机器不睡。
//  * 播放器一旦没人暂停，音频会话就一直 active，即使用户已经退出播放页。
//
//  现在播放只会在三处结束，且每一处都把会话拆干净：
//  ① 用户离开播放页（含按 Menu 关闭）② App 离开前台 ③ 流结束或失败。
//
//  明确不做的两件事（都是这类故障的帮凶）：
//  * 不使用 `UIApplication.isIdleTimerDisabled`：一旦哪里出错没恢复，
//    设备就永远不能休眠，这正是"关不掉"的另一半成因；宁可让屏幕在长时间
//    播放时自行变暗，也要保证设备任何时候都能关。
//  * 不请求后台播放能力：直播播放器没有理由在用户离开后继续占用音频。
//

import AVFoundation
import AVKit
import SwiftUI

@MainActor
final class PlaybackController: ObservableObject {

    /// 播放页是否呈现。只读：关闭动作必须走 `stop(reason:)`，否则又会留下
    /// 一个还在出声的播放器。
    @Published private(set) var isPresenting = false
    /// 播放失败的原因，供界面提示
    @Published private(set) var streamError: String?
    /// 最近一次停止的原因（写日志/排查用）
    @Published private(set) var lastStopReason: String?

    private(set) var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?

    // MARK: - 播放

    func play(url: URL) {
        // 换台前先把上一路彻底停掉，避免两个 AVPlayer 同时持有一个音频会话
        stop(reason: "switching channel")

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.allowsExternalPlayback = true
        player = newPlayer
        streamError = nil
        activateAudioSession()
        observeFailure(of: item)
        isPresenting = true
        newPlayer.play()
    }

    /// 停止播放并释放音频会话。可以重复调用。
    func stop(reason: String) {
        let hadPlayer = player != nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        removeObservers()
        deactivateAudioSession()
        if isPresenting || hadPlayer {
            lastStopReason = reason
        }
        isPresenting = false
    }

    /// 用户已看到过失败提示，清掉标记，避免下次播放时旧提示又弹出来
    func clearStreamError() {
        streamError = nil
    }

    // MARK: - 流结束/失败

    /// tvOS 27 起通知名改挂在 AVPlayerItem 上；本 App 仍支持 tvOS 16，
    /// 所以按系统版本取名字，而不是为了少一条警告拉高最低版本。
    private static var playToEndName: Notification.Name {
        if #available(tvOS 27.0, *) { return AVPlayerItem.didPlayToEndTimeNotification }
        return .AVPlayerItemDidPlayToEndTime
    }

    private static var failedToPlayToEndName: Notification.Name {
        if #available(tvOS 27.0, *) { return AVPlayerItem.failedToPlayToEndTimeNotification }
        return .AVPlayerItemFailedToPlayToEndTime
    }

    private func observeFailure(of item: AVPlayerItem) {
        removeObservers()
        endObserver = NotificationCenter.default.addObserver(
            forName: Self.playToEndName, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop(reason: "stream ended") }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: Self.failedToPlayToEndName, object: item, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                // 直播源挂掉时必须收摊：死流占着音频会话同样会让设备不休眠
                self?.streamError = error?.localizedDescription ?? "播放失败"
                self?.stop(reason: "stream failed")
            }
        }
    }

    private func removeObservers() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
            self.failObserver = nil
        }
    }

    // MARK: - 音频会话

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // 注意：不要用 .longFormVideo 的 policy，tvOS 上没有这个选项。
            // 也不要在 category 之外添加任何"后台"能力——那正是本故障的成因。
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // 会话配置失败也要继续播：这只是路由与中断策略，不是播放的前置条件
        }
    }

    private func deactivateAudioSession() {
        // 关键的一步。会话保持 active 就是"设备不睡"的直接原因。
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }
}
