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

### 2. 静态门禁 `swift/check-playback-safety.sh`

```bash
bash swift/check-playback-safety.sh     # 0 = 通过，1 = 命中禁用写法
```

检查：`UIBackgroundModes` 不得出现、`isIdleTimerDisabled = true` 不得使用、
三条停止路径必须都在。反向验证过：把 `UIBackgroundModes` 加回去，脚本立刻返回 1。

> 待接线：把它挂到 GitHub Actions 上（变更 `swift/**` 或 `project.yml` 时运行）。
> 当前推送用的 token 没有 `workflow` 权限，无法创建 `.github/workflows/` 下的文件，
> 所以这一步留给仓库所有者完成，YAML 见故障报告末尾或 README。
