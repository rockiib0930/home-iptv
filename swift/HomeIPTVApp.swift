//
//  HomeIPTVApp.swift
//  HomeIPTV
//
//  App 入口
//

import SwiftUI

@main
struct HomeIPTVApp: App {
    @StateObject private var store = PlaylistStore()
    @StateObject private var playback = PlaybackController()

    var body: some Scene {
        WindowGroup {
            ChannelListView()
                .environmentObject(store)
                .environmentObject(playback)
                .preferredColorScheme(.dark)  // 电视默认深色
                // App 进入后台就必须停播：这是"机顶盒关不掉"的修复点之一。
                // 用通知而不是 scenePhase，是因为 scenePhase 的两个参数版
                // onChange 需要 tvOS 17，而本 App 支持 tvOS 16。
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.didEnterBackgroundNotification)) { _ in
                    playback.stop(reason: "app went to the background")
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.willTerminateNotification)) { _ in
                    playback.stop(reason: "app terminating")
                }
        }
    }
}
