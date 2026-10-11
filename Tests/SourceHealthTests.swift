//
//  SourceHealthTests.swift
//
//  本机播放记忆：列表是"从国内实测"出来的，但真正决定能不能播的是设备所在的网络，
//  所以设备自己也要记。这里守住"成功的排前、失败的排后"这条排序规则。
//

import XCTest
@testable import HomeIPTV

@MainActor
final class SourceHealthTests: XCTestCase {

    private func source(_ host: String) -> StreamSource {
        StreamSource(url: URL(string: "http://\(host)/live.m3u8")!,
                     provider: "", quality: "HD", isCN: true)
    }

    override func setUp() {
        super.setUp()
        // 每个用例从干净状态开始，避免互相干扰
        UserDefaults.standard.removeObject(forKey: "source_health_v1")
    }

    func testUnknownSourcesKeepTheirOriginalOrder() {
        let sources = [source("a.example"), source("b.example"), source("c.example")]
        let sorted = SourceHealth.shared.sorted(sources)
        XCTAssertEqual(sorted.map(\.url.host), ["a.example", "b.example", "c.example"])
    }

    func testASourceThatWorkedMovesAhead() {
        let good = source("good.example")
        SourceHealth.shared.record(url: good.url, succeeded: true)

        let sorted = SourceHealth.shared.sorted([source("a.example"), good, source("c.example")])
        XCTAssertEqual(sorted.first?.url.host, "good.example",
                       "在这台设备上播成功过的线路应当排到最前")
    }

    func testASourceThatFailedMovesLast() {
        let bad = source("bad.example")
        SourceHealth.shared.record(url: bad.url, succeeded: false)

        let sorted = SourceHealth.shared.sorted([bad, source("a.example"), source("c.example")])
        XCTAssertEqual(sorted.last?.url.host, "bad.example",
                       "失败过的线路应当排到最后")
    }

    func testRepeatedSuccessesOutrankASingleSuccess() {
        let often = source("often.example")
        let once = source("once.example")
        SourceHealth.shared.record(url: often.url, succeeded: true)
        SourceHealth.shared.record(url: often.url, succeeded: true)
        SourceHealth.shared.record(url: once.url, succeeded: true)

        let sorted = SourceHealth.shared.sorted([once, often])
        XCTAssertEqual(sorted.first?.url.host, "often.example")
    }

    func testKnownBadOnlyWhenItNeverWorked() {
        let neverWorked = source("dead.example")
        let flaky = source("flaky.example")
        SourceHealth.shared.record(url: neverWorked.url, succeeded: false)
        SourceHealth.shared.record(url: flaky.url, succeeded: true)
        SourceHealth.shared.record(url: flaky.url, succeeded: false)

        XCTAssertTrue(SourceHealth.shared.isKnownBad(url: neverWorked.url))
        XCTAssertFalse(SourceHealth.shared.isKnownBad(url: flaky.url),
                       "曾经播成功过就不算已知不可用")
        XCTAssertFalse(SourceHealth.shared.isKnownBad(
            url: URL(string: "http://never-seen.example/x.m3u8")!))
    }
}
