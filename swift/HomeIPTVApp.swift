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

    var body: some Scene {
        WindowGroup {
            ChannelListView()
                .environmentObject(store)
                .preferredColorScheme(.dark)  // 电视默认深色
        }
    }
}
