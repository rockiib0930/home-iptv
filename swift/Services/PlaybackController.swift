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

/// 音频会话的可替换封装。
///
/// 之所以抽出来：这次故障的核心就是"会话从不释放"，而它偏偏是最难观察的一环。
/// 有了这层接口，测试可以断言"停止时确实调用了 deactivate"，而不是只相信代码看起来对。
protocol AudioSessionControlling {
    func activate() throws
    func deactivate()
}

/// 真机使用的实现
struct SystemAudioSession: AudioSessionControlling {
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        // 注意：不要用 .longFormVideo 的 policy，tvOS 上没有这个选项。
        // 也不要在 category 之外添加任何"后台"能力——那正是本故障的成因。
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
    }

    func deactivate() {
        // 关键的一步。会话保持 active 就是"设备不睡"的直接原因。
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }
}

@MainActor
final class PlaybackController: ObservableObject {

    private let audioSession: AudioSessionControlling

    init(audioSession: AudioSessionControlling = SystemAudioSession()) {
        self.audioSession = audioSession
    }

    /// 播放页是否呈现。只读：关闭动作必须走 `stop(reason:)`，否则又会留下
    /// 一个还在出声的播放器。
    @Published private(set) var isPresenting = false
    /// 播放失败的原因，供界面提示
    @Published private(set) var streamError: String?
    /// 最近一次停止的原因（写日志/排查用）
    @Published private(set) var lastStopReason: String?
    /// 当前播放的频道名与线路信息（播放页覆盖层用）
    @Published private(set) var channelName: String = ""
    @Published private(set) var sourceLabel: String = ""
    @Published private(set) var sourceIndex: Int = 0
    @Published private(set) var sourceCount: Int = 0
    /// 自动换线时给用户的提示（例如"线路 1 失败，已切到线路 2"）
    @Published private(set) var notice: String?
    /// 播放页信息条是否显示（约 6 秒后自动淡出）
    @Published private(set) var isShowingInfo = false

    private(set) var player: AVPlayer?
    private var infoTask: Task<Void, Never>?
    /// 当前频道的全部线路，失败时用来回退
    private var channel: Channel?
    /// 当前正在播的线路地址（用于把播放结果记进本机健康记忆）
    private var currentURL: URL?
    private var statusObservation: NSKeyValueObservation?
    /// 我们是否真的激活过音频会话。
    ///
    /// 只在激活过之后才释放：对一个从未激活的会话调用 `setActive(false)` 会向系统
    /// 广播"我要让出音频"，可能打断正在放歌的其他 App——而这次故障的修复要点本来就是
    /// "只碰自己的东西"。
    private var audioSessionActive = false
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?

    // MARK: - 播放

    /// 播放一个逻辑频道的首选线路
    func play(channel newChannel: Channel) {
        play(channel: newChannel, sourceIndex: 0)
    }

    /// 指定从第几条线路开始播（用户在长按菜单里选了具体线路）
    func play(channel newChannel: Channel, sourceIndex index: Int) {
        channel = newChannel
        sourceCount = newChannel.sources.count
        channelName = newChannel.name
        notice = nil
        startSource(at: min(max(index, 0), max(newChannel.sources.count - 1, 0)))
    }

    /// 手动/自动切到下一条线路
    func switchSource() {
        guard let channel else { return }
        let next = sourceIndex + 1
        guard next < channel.sources.count else {
            streamError = "全部 \(channel.sources.count) 条线路都无法播放"
            stop(reason: "no working source")
            return
        }
        startSource(at: next)
    }

    private func startSource(at index: Int) {
        guard let channel, channel.sources.indices.contains(index) else { return }
        sourceIndex = index
        let source = channel.sources[index]
        currentURL = source.url
        sourceLabel = source.label(index: index)
        play(url: source.url)
        showInfo()
    }

    /// 信息条显示一会儿就收起来，不挡画面
    private func showInfo() {
        isShowingInfo = true
        infoTask?.cancel()
        infoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.isShowingInfo = false
        }
    }

    func play(url: URL) {
        // 换台前先把上一路彻底停掉，避免两个 AVPlayer 同时持有一个音频会话
        stop(reason: "switching channel")

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.allowsExternalPlayback = true
        // 官方 API，语义即"进入后台就暂停"。SDK 原文（AVPlayer.h）：
        //   Pauses: "Indicates that the player must be paused on going to background."
        //   "If set to ...Pauses, player will be paused on entering background."
        // 可用性：tvos(15.0)，本 App 最低 tvOS 16，因此直接可用。
        // 注意 SDK 同处的限定："this policy only applies to items with enabled video"——
        // 纯音频源不在其内，所以下面仍保留进入后台的显式 stop 作为兜底。
        newPlayer.audiovisualBackgroundPlaybackPolicy = .pauses
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

    func clearNotice() {
        notice = nil
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
        // 记播放结果：status 变成 readyToPlay 说明这条线在这台设备上能用；
        // 变成 failed 则记一次失败。下次排序就会优先用成功的、后置失败的。
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, let url = self.currentURL else { return }
                switch item.status {
                case .readyToPlay:
                    SourceHealth.shared.record(url: url, succeeded: true)
                case .failed:
                    SourceHealth.shared.record(url: url, succeeded: false)
                default:
                    break
                }
            }
        }
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
                self?.handleFailure(error)
            }
        }
    }

    /// 源挂掉时的处置：还有备用线路就自动切过去（国内很多源时好时坏，
    /// 让用户手动换线体验太差），一条都不剩才报错收摊。
    /// 注意死流占着音频会话同样会让设备不休眠，所以最后一定要 stop()。
    private func handleFailure(_ error: Error?) {
        guard let channel else {
            streamError = error?.localizedDescription ?? "播放失败"
            stop(reason: "stream failed")
            return
        }
        let hasSpare = sourceIndex + 1 < channel.sources.count
        if hasSpare {
            let failed = sourceIndex + 1
            notice = "线路 \(failed) 无法播放，已自动切到线路 \(failed + 1)"
            startSource(at: sourceIndex + 1)
            showInfo()   // 换线是要让用户看见的
        } else {
            streamError = error?.localizedDescription ?? "播放失败"
            stop(reason: "stream failed")
        }
    }

    private func removeObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
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
        // 会话配置失败也要继续播：这只是路由与中断策略，不是播放的前置条件
        do {
            try audioSession.activate()
            audioSessionActive = true
        } catch {
            audioSessionActive = false
        }
    }

    private func deactivateAudioSession() {
        guard audioSessionActive else { return }
        audioSession.deactivate()
        audioSessionActive = false
    }
}
