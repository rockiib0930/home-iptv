# 故障记录：机顶盒无法关机（2026-10-11）

## 现象

用这个 App 看电视之后，机顶盒关不掉：按遥控器的电源/睡眠，声音还在，机器不睡；
必须强制断电才能关。

## 根因（两条，互相放大）

### 1. App 声明了后台音频能力

这个仓库里有**两条构建路径，各自用一份 plist**，两份都写着这个能力，
所以只改一处是不够的：

* XcodeGen 路径：`project.yml` 的 `info.properties` → 生成并使用根目录的 `Info.plist`
  （工程里是 `INFOPLIST_FILE = Info.plist`）；
* README 里的手工路径：把 `swift/` 拖进 Xcode 工程，用的是 `swift/Info.plist`。

两份原本都写着：

```xml
<key>UIBackgroundModes</key>
<array><string>audio</string></array>
```

这等于告诉系统"我离开前台后还要继续放声音"。直播播放器并不需要这个能力，
而一旦声明：**音频播放期间系统不会进入睡眠**，所以表现为"机顶盒关不掉"。

### 2. 播放器从来没被停止过

旧代码里：

```swift
@State private var player: AVPlayer?
...
ChannelCard(channel: channel) {
    player = AVPlayer(url: channel.streamURL)   // 创建后没人负责停
    presentingPlayer = true
}
.fullScreenCover(isPresented: $presentingPlayer) { PlayerView(player: player) }
```

* 遥控器按 Menu 关闭播放页，只是把 `presentingPlayer` 置 false，`AVPlayer` 继续播放；
* App 进入后台也没有任何处理；
* 完全没有 `AVAudioSession` 的配置与释放，会话一直 `active`。

于是"音频在播 + 会话活跃 + 后台能力"三件事叠在一起，设备自然不睡。

> 顺带修掉一个会绊人的历史问题：根目录的 `Info.plist` 是 XcodeGen 生成的构建产物，
> 却一直处于未跟踪状态。它已加入 `.gitignore`，避免以后有人以为"改了
> `swift/Info.plist` 就生效了"——在 XcodeGen 路径下并不生效。

### 附带的第三个问题（同一类后果）

`Timer.scheduledTimer` 建在 `.onAppear` 里、从不 `invalidate`：每次进入页面都会多一个
永远运行的定时器，并且强引用视图。已改为随视图自动取消的 `Task`。

## 修复

| # | 改动 | 文件 |
| --- | --- | --- |
| 1 | 删除 `UIBackgroundModes: [audio]`（两条构建路径的 plist 都删） | `project.yml`、`swift/Info.plist` |
| 2 | 新增 `PlaybackController`：唯一拥有播放器，且唯一负责**停止**它 | `swift/Services/PlaybackController.swift` |
| 3 | 停止播放三条路径：关闭播放页（含 Menu）/ App 进入后台 / 流结束或失败 | `ChannelListView.swift`、`HomeIPTVApp.swift` |
| 4 | 设置并**释放** `AVAudioSession`（`.playback` + `.moviePlayback`，停止时 `setActive(false)`） | `PlaybackController.swift` |
| 5 | 定时刷新由 `Timer` 改为可取消的 `Task` | `ChannelListView.swift` |
| 6 | 直播源失败时给出提示并收摊（死流占着会话同样会让设备不休眠） | `PlaybackController.swift` |

### 用的都是官方既有 API，不是自创方案

排查时对照了三份"成熟做法"，结论如下。

**1. Apple SDK 头文件里的官方开关（本文的主要依据）**

```
AVPlayer.h:
  /// Indicates that the player must be paused on going to background.
  AVPlayerAudiovisualBackgroundPlaybackPolicyPauses = 2,
  ...
  /// If set to AVPlayerAudiovisualBackgroundPlaybackPolicyPauses, player will
  /// be paused on entering background.
  @property ... audiovisualBackgroundPlaybackPolicy
      API_AVAILABLE(macos(12.0), ios(15.0), tvos(15.0), watchos(8.0), visionos(1.0));
```

也就是说"进入后台就暂停"这件事，系统本来就有专门开关。本 App 最低 tvOS 16，
直接可用，不需要自己监听生命周期去猜时机。已设置 `= .pauses`。

SDK 同处还有一句限定：`this policy only applies to items with enabled video`——
纯音频源不在其内，所以**仍保留**进入后台的显式 `stop()` 作为兜底。

**2. 同类成熟开源项目的做法（对照，不作为结论依据）**

`mikehouse/Apple-TV-Player`（187★，Swift，tvOS/iOS 的 m3u IPTV 播放器，App Store 在售）：

* 它的 Info.plist **确实声明了 `<key>UIBackgroundModes</key><array><string>audio</string></array>`**；
* 其 `StreamViewModel` 里**没有任何** `AVAudioSession` / `scenePhase` / 后台处理代码。

这正是本故障的配置形态：能力开着、播放器没人收尾。对 iOS 来说后台音频常被当作特性，
但对 tvOS 的直播播放器，代价就是"离开 App 后声音还在 → 设备不睡"。所以本 App 选择：
**不声明该能力，播放随前台结束**。

**3. 其他相关 API 的可用性（查 SDK 确认，避免乱用）**

* `AVPlayerViewController.updatesNowPlayingInfoCenter`：`API_UNAVAILABLE(tvos)` —— tvOS 上不能用；
* `allowsPictureInPicturePlayback`：tvOS 14+ 可用，但它是"离开前台还出声"的另一条路径，
  本 App 明确关掉；
* `UIApplication.isIdleTimerDisabled`：tvOS 上**可用**，但本 App 主动不碰（见上）。

### 一个刻意保留的取舍

iOS 上"切后台继续放声音"对部分用户算特性。本 App 没有开这个口子，因为：
① 需求是"保证设备能关"，② 直播播放器没有必须在后台出声的理由，
③ 少一个能力就少一条把设备钉醒的路径。若将来确实要 iOS 后台音频，
正确做法是按平台分别配置 plist，而不是把 tvOS 也一起打开。

### 刻意不做的事

* **不**使用 `UIApplication.isIdleTimerDisabled`。它能让长时间播放时屏幕不变暗，但只要
  有一处没恢复成 `false`，设备就永远不能休眠——和本故障是同一种后果，代价却更隐蔽。
  宁可让屏幕按系统策略变暗，也要保证设备任何时候都能关。
* **不**请求任何后台能力。这个 App 的播放必须随前台结束而结束。

## 怎么验证修好了

1. 打开任意频道，确认正常播放；
2. 按遥控器 **Menu** 关闭播放页 → 声音必须立即停止；
3. 按 **TV/Home** 回到主屏 → 声音必须立即停止；
4. 让机顶盒待机（遥控器电源/睡眠）→ 应当能正常进入待机，不再需要强制断电；
5. 播放一个已经失效的直播源 → 应弹出"播放失败"提示，且**不再有声音残留**。

## 机器门禁

两层，缺一不可：

### 1. 单元测试 `Tests/PlaybackControllerTests.swift`（10 项）

```bash
xcodegen generate
xcodebuild test -scheme HomeIPTV -destination 'platform=tvOS Simulator,name=Apple TV'
```

断言的是行为而不是文本：

* 停止时必须清掉播放器、**释放音频会话**、界面状态归位；
* 换台要先收掉上一路；
* 流失败会弹提示并收摊；
* 从没播过时不碰音频会话（不去打断其他 App 的声音）；
* **产物级不变量**：`Bundle(for:)` 读到的 Info.plist 里不得有 `UIBackgroundModes` 的 audio
  ——无论谁通过哪条构建路径把它加回来，这条都会失败。

这套测试在开发过程中确实抓到过一个实现缺陷：最初的 `stop()` 会在"从没播放过"的情况下
也去释放音频会话（`setActive(false)` 会向系统广播让出音频，可能打断别的 App），
5 个用例同时失败把它拦了下来。

另有一个启动冒烟 UI 测试（`Tests/UITests/AppLaunchUITests.swift`）：App 必须能起来并
渲染出频道列表，避免后续改动把启动打挂。

还有一条**只在真机 Apple TV 上跑**的界面用例：打开频道 → 按遥控器 Menu 关闭 → 回到列表。
它验证的正是"关闭播放页必须走到 stop()"这段接线——单元测试覆盖不到。

断言方式是实测出来的：在真机 Apple TV 上用 `app.debugDescription` 看了三个阶段的无障碍树：

| 阶段 | Window 数 |
| --- | --- |
| 列表就绪 | 1（Main） |
| 按 select 打开频道 | **2**（多出播放页的 960×540 窗口） |
| 按 Menu 关闭 | 1（Main） |

注意**不能**用"列表元素消失"当判据：被 `fullScreenCover` 盖住的列表在无障碍树里依然存在
（第一版就是这么写错的，一直等不到）。模拟器上遥控器焦点的起点与真机不同，同样的
down+select 选不中频道卡片，所以这条用例在模拟器上明确 skip 并写明原因。

**这两层测试都在 tvOS 27 模拟器上实际跑过并通过。**

**并且已经在一台真实的 Apple TV（机顶盒 192.168.3.36，Apple TV 4K，tvOS 27.0）上跑通**：
11 项单元测试 + 2 项 UI 测试全部通过（含上面那条 Menu 关闭用例）。

> 覆盖不到的一段，如实说明：「按遥控器 Menu 关闭播放页 → 停止播放」属于界面接线行为。
> TVOS 上 `XCUIElement.tap()` 不可用，只能靠焦点导航去点卡片，写出来极其易碎；
> 模拟器里也没有真实音频可供判断"声音是否停止"。所以这一段留在下面的真机清单里。

### 2. 静态门禁 `swift/check-playback-safety.sh`

```bash
bash swift/check-playback-safety.sh     # 0 = 通过，1 = 命中禁用写法
```

检查：`UIBackgroundModes` 不得出现、`isIdleTimerDisabled = true` 不得使用、
三条停止路径必须都在。反向验证过：把 `UIBackgroundModes` 加回去，脚本立刻返回 1。

> 待接线：把它挂到 GitHub Actions 上（变更 `swift/**` 或 `project.yml` 时运行）。
> 当前推送用的 token 没有 `workflow` 权限，无法创建 `.github/workflows/` 下的文件，
> 所以这一步留给仓库所有者完成，YAML 见故障报告末尾或 README。
