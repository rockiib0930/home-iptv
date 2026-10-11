//
//  AppLaunchUITests.swift
//
//  tvOS 启动冒烟测试：App 必须能起来并显示出频道列表。
//
//  为什么只做到这一步（如实说明）：
//  * 本次故障的**行为**由 PlaybackControllerTests 断言（停止会清播放器并释放音频会话，
//    共 10 项，在 tvOS 27 模拟器上通过）；
//  * "按遥控器 Menu 关闭播放页"那一段接线属于界面行为，但 tvOS 上
//    `XCUIElement.tap()` 不可用，只能靠焦点导航（一串 press(.right)）去点卡片，
//    这种测试极其易碎，而且模拟器里也没有真实音频可以验证"声音是否停止"；
//  * 所以这一段留在真机清单里（见 FAULT-2026-10-11-box-wont-power-off.md 的验证步骤），
//    这里只守住"App 还能起来"这条底线，避免改动把启动打挂。
//

import XCTest

final class AppLaunchUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTheAppLaunchesAndShowsTheChannelList() throws {
        let app = XCUIApplication()
        app.launch()

        // 标题长这样：HomeIPTV · N 个频道
        let title = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "HomeIPTV")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 60),
                      "启动后没有出现频道列表标题（可能启动即崩溃，或订阅源拉取失败）")

        // 分类选择器也在，说明主界面渲染完整
        XCTAssertTrue(app.staticTexts["分类"].exists || app.buttons["分类"].exists,
                      "找不到分类选择器")
    }
}
