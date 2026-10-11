//
//  PlaylistParserTests.swift
//
//  覆盖"频道重复"的修复：一个逻辑频道只应该出现一次，多条线路挂在它下面。
//

import XCTest
@testable import HomeIPTV

final class PlaylistParserTests: XCTestCase {

    private func parse(_ text: String) -> [Channel] {
        M3UParser.parse(text: text)
    }

    // MARK: - 去重

    func testSameChannelWithDifferentQualitiesBecomesOneEntry() {
        let channels = parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="CCTV1.cn@SD" group-title="综合",CCTV-1
        http://a.example/1.m3u8
        #EXTINF:-1 tvg-id="CCTV1.cn@HD" group-title="综合",CCTV-1
        http://b.example/1.m3u8
        #EXTINF:-1 tvg-id="CCTV1.cn@FHD" group-title="综合",CCTV-1
        http://c.example/1.m3u8
        """)
        XCTAssertEqual(channels.count, 1, "同一 tvg-id 的三条源应当合成一个频道")
        XCTAssertEqual(channels[0].sources.count, 3)
        XCTAssertEqual(channels[0].name, "CCTV-1")
    }

    func testNameSuffixesAreIgnoredWhenThereIsNoTvgID() {
        let channels = parse("""
        #EXTM3U
        #EXTINF:-1,湖南卫视
        http://a.example/hn.m3u8
        #EXTINF:-1,湖南卫视 HD
        http://b.example/hn.m3u8
        #EXTINF:-1,湖南卫视高清
        http://c.example/hn.m3u8
        """)
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].sources.count, 3)
    }

    func testDifferentChannelsAreNotMerged() {
        let channels = parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="CCTV1.cn" group-title="综合",CCTV-1
        http://a.example/1.m3u8
        #EXTINF:-1 tvg-id="CCTV2.cn" group-title="综合",CCTV-2
        http://b.example/2.m3u8
        """)
        XCTAssertEqual(channels.count, 2)
    }

    func testTheSameURLIsNotAddedTwice() {
        let channels = parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="CCTV1.cn@SD" group-title="综合",CCTV-1
        http://a.example/1.m3u8
        #EXTINF:-1 tvg-id="CCTV1.cn@SD" group-title="综合",CCTV-1
        http://a.example/1.m3u8
        """)
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].sources.count, 1, "同一条 URL 不应重复计数")
    }

    // MARK: - 线路质量与国内可播

    func testQualityComesFromTheTvgIDSuffixOrTheName() {
        let channels = parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="A.cn@FHD" group-title="G",频道A
        http://a.example/a.m3u8
        #EXTINF:-1 group-title="G",频道B 1080p
        http://b.example/b.m3u8
        #EXTINF:-1 group-title="G",频道C 标清
        http://c.example/c.m3u8
        """)
        let byName = Dictionary(uniqueKeysWithValues: channels.map { ($0.name, $0) })
        XCTAssertEqual(byName["频道A"]?.qualityLabel, "FHD")
        XCTAssertEqual(byName["频道B"]?.qualityLabel, "FHD")
        XCTAssertEqual(byName["频道C"]?.qualityLabel, "SD")
    }

    func testChineseChannelsAndHostsAreMarkedAsDomestic() {
        let channels = parse("""
        #EXTM3U
        #EXTINF:-1 group-title="卫视",湖南卫视
        http://a.example/hn.m3u8
        #EXTINF:-1 tvg-id="CCTV1.cn" group-title="General",CCTV-1
        http://b.example/1.m3u8
        #EXTINF:-1 group-title="News",France 24
        http://france24.example/f.m3u8
        """)
        let byName = Dictionary(uniqueKeysWithValues: channels.map { ($0.name, $0) })
        XCTAssertTrue(byName["湖南卫视"]?.isCN ?? false, "中文频道应标为国内")
        XCTAssertTrue(byName["CCTV-1"]?.isCN ?? false, ".cn 的 tvg-id 应标为国内")
        XCTAssertFalse(byName["France 24"]?.isCN ?? true, "外语频道不应标为国内")
    }

    func testDomesticSourcesAreListedFirst() {
        let channels = parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="CCTV1.cn@HD" group-title="General",CCTV-1
        https://overseas.example/1.m3u8
        #EXTINF:-1 tvg-id="CCTV1.cn@SD" group-title="General",CCTV-1
        http://58.248.112.205:8006/cctv1.m3u8
        """)
        let sources = try? XCTUnwrap(channels.first?.sources)
        XCTAssertEqual(sources?.count, 2)
        XCTAssertTrue(sources?.first?.isCN ?? false, "国内线路应排在最前")
    }

    // MARK: - 真实数据

    func testTheBundledSnapshotIsDeduped() throws {
        // 用 App 包里真正带的那份快照跑一遍：它必须能解析，且频道数明显少于源条数，
        // 否则说明去重没生效（这就是用户看到的"频道重复"）。
        let bundle = Bundle(for: PlaybackController.self)
        let url = try XCTUnwrap(bundle.url(forResource: "bootstrap", withExtension: "m3u"),
                                "内置快照没有打进 App 包")
        let text = try String(contentsOf: url, encoding: .utf8)
        let channels = M3UParser.parse(text: text)
        let sources = channels.reduce(0) { $0 + $1.sources.count }

        XCTAssertGreaterThan(channels.count, 100, "内置快照频道太少，可能解析失败")
        XCTAssertLessThan(channels.count, sources,
                          "频道数应当少于线路数：说明同一频道的多条源已经被合并且 \(channels.count)/\(sources)")
        XCTAssertEqual(Set(channels.map(\.key)).count, channels.count, "不应有重复的频道 key")
        XCTAssertTrue(channels.contains { $0.isCN }, "快照里应当有国内频道")

        // 多线路频道是"更容易播得动"的那个子集，界面上有独立分类，这里守住它有实际数量
        let multi = channels.filter { $0.sources.count > 1 }
        XCTAssertGreaterThan(multi.count, 10, "多线路频道太少，自动换线就没意义了")
    }

    func testDisplayNameDropsQualityMarkersWithoutLeavingDanglingPunctuation() {
        XCTAssertEqual(M3UParser.displayName("湖南卫视 HD"), "湖南卫视")
        XCTAssertEqual(M3UParser.displayName("CCTV-4K HD"), "CCTV")
        XCTAssertEqual(M3UParser.displayName("CCTV-1"), "CCTV-1")
        XCTAssertEqual(M3UParser.displayName("CCTV-5 体育"), "CCTV-5 体育")
    }
}
