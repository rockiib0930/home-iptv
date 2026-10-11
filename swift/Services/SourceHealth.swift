//
//  SourceHealth.swift
//  HomeIPTV
//
//  本机播放记忆：哪些线路在这台设备上真的播出来过。
//
//  为什么需要它：线上列表是"从国内某处实测"的结果（见 out/live.m3u），但真正
//  决定能不能播的是**这台 Apple TV 所在的网络**，而且直播源时刻在变。让 App 自己
//  记住"这条线播成功过 / 刚刚失败过"，下次优先用成功的、把失败的后置，
//  列表就会在两轮实测之间自我修正。
//

import Foundation

@MainActor
final class SourceHealth {

    static let shared = SourceHealth()

    private let defaultsKey = "source_health_v1"
    /// url → [成功次数, 失败次数]
    private var stats: [String: [Int]] = [:]

    private init() {
        if let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [Int]] {
            stats = stored
        }
    }

    func record(url: URL, succeeded: Bool) {
        let key = url.absoluteString
        var entry = stats[key] ?? [0, 0]
        if succeeded { entry[0] += 1 } else { entry[1] += 1 }
        // 失败次数过多就不再记（否则旧记录会一直压着这条线）
        if entry[1] > 20 { entry[1] = 20 }
        stats[key] = entry
        UserDefaults.standard.set(stats, forKey: defaultsKey)
    }

    /// 正数表示靠谱，负数表示这台设备上失败过
    func score(url: URL) -> Int {
        guard let entry = stats[url.absoluteString] else { return 0 }
        return entry[0] - entry[1]
    }

    /// 线路排序：本机播成功过的排最前，失败过的排最后；其余保持调用方给的顺序
    func sorted(_ sources: [StreamSource]) -> [StreamSource] {
        sources.enumerated().sorted { lhs, rhs in
            let left = score(url: lhs.element.url)
            let right = score(url: rhs.element.url)
            if left != right { return left > right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 某条线在这台设备上是否已被判定为不可用（失败过且从未成功）
    func isKnownBad(url: URL) -> Bool {
        guard let entry = stats[url.absoluteString] else { return false }
        return entry[0] == 0 && entry[1] > 0
    }
}
