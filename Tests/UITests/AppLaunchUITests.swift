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

    /// 本次故障修复的界面接线：打开频道 → 按遥控器 Menu 关闭 → 回到列表。
    ///
    /// 这个断言是实测出来的，不是猜的：在真机 Apple TV 上用
    /// `app.debugDescription` 看过三个阶段的无障碍树——
    ///   列表就绪：1 个 Window；按 select 后：**2 个**（多出播放页的 960x540 窗口）；
    ///   按 Menu 后：回到 1 个。
    /// 注意"列表元素消失"不能作为判据：被 fullScreenCover 盖住的列表在无障碍树里
    /// 依然存在，所以原来那样写会永远等不到。
    func testOpeningAChannelThenClosingThePlayerReturnsToTheList() throws {
        // 这条用例依赖 tvOS 的遥控器焦点路径，而模拟器与真机的焦点起点不同
        // （同样的 down+select 在真机上能选中频道卡片、在模拟器上不行）。
        // 它本来就是为真机写的，所以在模拟器上明确跳过，而不是改成一条
        // 在真机上反而不可靠的"宽容"断言。
        #if targetEnvironment(simulator)
        throw XCTSkip("遥控器焦点路径只在真机 Apple TV 上验证（模拟器行为不同）")
        #endif

        let app = XCUIApplication()
        app.launch()

        let title = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "HomeIPTV")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 90),
                      "频道列表没有出现（可能拉取订阅源失败）")
        XCTAssertEqual(app.windows.count, 1, "列表状态下应当只有一个窗口")

        let remote = XCUIRemote.shared
        let playerIsOpen = NSPredicate(format: "count == 2")
        var opened = false
        for _ in 0..<3 {
            remote.press(.down)
            remote.press(.select)
            if XCTWaiter().wait(
                for: [expectation(for: playerIsOpen, evaluatedWith: app.windows)],
                timeout: 15) == .completed {
                opened = true
                break
            }
        }
        XCTAssertTrue(opened, "选中频道后播放页没有出现（焦点可能没落在频道卡片上）")

        remote.press(.menu)

        let backToList = NSPredicate(format: "count == 1")
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [expectation(for: backToList, evaluatedWith: app.windows)],
                timeout: 30),
            .completed,
            "按 Menu 关闭播放页后没有回到列表——关闭路径没走到 stop()")
    }
    /// 本次故障的核心行为：离开 App 时必须把播放收掉。
    ///
    /// 为什么这条能证明"机顶盒能关机"这件事的一半：设备不睡的机制是
    /// "音频还在播 → 系统不休眠"。这条用例断言的是**离开前台后播放页确实被关掉了**
    /// （PlaybackController.stop() 同时清播放器并释放音频会话，单元测试已在断言那两步）。
    /// 修复前的版本回到前台时播放页仍在。
    func testLeavingTheAppClosesPlayback() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("遥控器焦点路径只在真机 Apple TV 上验证（模拟器行为不同）")
        #endif

        let app = XCUIApplication()
        app.launch()
        let title = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "HomeIPTV")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 90), "频道列表没有出现")

        let remote = XCUIRemote.shared
        let playerIsOpen = NSPredicate(format: "count == 2")
        var opened = false
        for _ in 0..<3 {
            remote.press(.down)
            remote.press(.select)
            if XCTWaiter().wait(
                for: [expectation(for: playerIsOpen, evaluatedWith: app.windows)],
                timeout: 15) == .completed {
                opened = true
                break
            }
        }
        XCTAssertTrue(opened, "选中频道后播放页没有出现")

        // 退到后台，再回到前台
        remote.press(.home)
        Thread.sleep(forTimeInterval: 4)
        app.activate()

        let backToList = NSPredicate(format: "count == 1")
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [expectation(for: backToList, evaluatedWith: app.windows)],
                timeout: 30),
            .completed,
            "离开 App 再回来时播放页仍在——说明后台没有停播（这正是机顶盒不睡的成因）")
    }
}
