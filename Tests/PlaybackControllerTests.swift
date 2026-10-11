//
//  PlaybackControllerTests.swift
//
//  这次故障（机顶盒无法关机）的核心是"播放既不停止、音频会话也不释放"，
//  所以这里断言的不是"代码看起来对"，而是"停止时确实做了那几件事"：
//  播放器被清掉、会话被释放、界面状态归位。
//

import AVFoundation
import XCTest
@testable import HomeIPTV

/// 音频会话替身：记录调用顺序，不碰真实会话
final class SpyAudioSession: AudioSessionControlling {
    enum Call { case activate, deactivate }
    private(set) var calls: [Call] = []
    var activateError: Error?

    func activate() throws {
        calls.append(.activate)
        if let activateError { throw activateError }
    }

    func deactivate() {
        calls.append(.deactivate)
    }
}

@MainActor
final class PlaybackControllerTests: XCTestCase {

    private let stream = URL(string: "https://example.invalid/live.m3u8")!

    private func makeController() -> (PlaybackController, SpyAudioSession) {
        let spy = SpyAudioSession()
        return (PlaybackController(audioSession: spy), spy)
    }

    // MARK: - 初始状态

    func testStartsIdle() {
        let (controller, spy) = makeController()
        XCTAssertFalse(controller.isPresenting)
        XCTAssertNil(controller.player)
        XCTAssertNil(controller.streamError)
        XCTAssertTrue(spy.calls.isEmpty, "还没播过就不该动音频会话")
    }

    // MARK: - 开始播放

    func testPlayPresentsThePlayerAndActivatesTheSession() {
        let (controller, spy) = makeController()
        controller.play(url: stream)
        XCTAssertTrue(controller.isPresenting)
        XCTAssertNotNil(controller.player)
        XCTAssertEqual(spy.calls, [.activate])
    }

    func testPlayDoesNotStartWithoutAnAudioSessionEither() {
        // 会话配置失败不是播放的前置条件；直播照样要能播
        let spy = SpyAudioSession()
        spy.activateError = NSError(domain: "test", code: 1)
        let controller = PlaybackController(audioSession: spy)
        controller.play(url: stream)
        XCTAssertTrue(controller.isPresenting)
        XCTAssertNotNil(controller.player)
    }

    // MARK: - 停止：本次故障的正面回归

    func testStopReleasesPlayerAndAudioSession() {
        let (controller, spy) = makeController()
        controller.play(url: stream)

        controller.stop(reason: "test")

        XCTAssertFalse(controller.isPresenting, "播放页必须关掉")
        XCTAssertNil(controller.player, "播放器必须被清掉，否则声音还在走")
        XCTAssertEqual(spy.calls, [.activate, .deactivate],
                       "停止时必须释放音频会话——会话存活就是设备不休眠的直接原因")
        XCTAssertEqual(controller.lastStopReason, "test")
    }

    func testStopIsIdempotent() {
        let (controller, spy) = makeController()
        controller.play(url: stream)
        controller.stop(reason: "first")
        controller.stop(reason: "second")
        // 第二次停止不该再释放一次会话，也不该覆盖原因
        XCTAssertEqual(spy.calls, [.activate, .deactivate])
        XCTAssertEqual(controller.lastStopReason, "first")
    }

    func testStopBeforeAnyPlaybackIsHarmless() {
        let (controller, spy) = makeController()
        controller.stop(reason: "nothing was playing")
        XCTAssertFalse(controller.isPresenting)
        XCTAssertNil(controller.player)
        XCTAssertTrue(spy.calls.isEmpty, "没播过就不该去动会话")
    }

    func testSwitchingChannelStopsThePreviousStreamFirst() {
        let (controller, spy) = makeController()
        controller.play(url: stream)
        let first = controller.player
        controller.play(url: URL(string: "https://example.invalid/other.m3u8")!)

        XCTAssertFalse(controller.player === first, "换台必须换播放器")
        XCTAssertEqual(spy.calls, [.activate, .deactivate, .activate],
                       "换台要先收掉上一路的会话，再起新的")
    }

    // MARK: - 流失败：死流占着会话同样会让设备不休眠

    func testStreamFailureStopsPlaybackAndSurfacesTheReason() {
        let (controller, spy) = makeController()
        controller.play(url: stream)
        let item = try? XCTUnwrap(controller.player?.currentItem)

        NotificationCenter.default.post(
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey:
                        NSError(domain: "test", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "stream died"])])

        let settled = expectation(description: "failure handled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertNotNil(controller.streamError)
        XCTAssertFalse(controller.isPresenting)
        XCTAssertNil(controller.player)
        XCTAssertEqual(spy.calls.last, .deactivate)
    }

    func testClearingTheErrorDoesNotTouchPlayback() {
        let (controller, _) = makeController()
        controller.play(url: stream)
        controller.stop(reason: "stream failed")
        controller.clearStreamError()
        XCTAssertNil(controller.streamError)
        XCTAssertFalse(controller.isPresenting)
    }

    // MARK: - 产物级不变量：这类故障最怕"某天又被加回来"

    func testTheAppDoesNotDeclareBackgroundAudio() throws {
        // 读的是**构建产物的 Info.plist**，不是源码：
        // 无论谁通过哪条构建路径把它加回来，这个断言都会失败。
        let bundle = Bundle(for: PlaybackController.self)
        let modes = bundle.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        XCTAssertFalse(modes.contains("audio"),
                       "App 不能声明后台音频：播放期间系统不会休眠，机顶盒就关不掉")
    }
}
