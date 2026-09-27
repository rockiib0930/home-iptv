# 在 MacBook Pro (192.168.3.210) 上起 tvOS 工程的步骤

> 本机是 Windows，以下操作在那台 Mac 上执行。代码骨架已在 `swift/` 目录，直接拖进 Xcode 工程即可。

## 第一步：建工程（5 分钟）

1. 在 Mac 上打开 Xcode → **File → New → Project**
2. 选 **tvOS → App**（不是 iOS！）
3. 填信息：
   - Product Name: `HomeIPTV`
   - Team: 选你已有的开发者账号
   - Interface: **SwiftUI**
   - Language: **Swift**
   - 取消勾选 "Use Core Data" / "Tests"
4. 保存到 `~/Projects/HomeIPTV/`

## 第二步：把骨架代码拖进去

把本仓库 `swift/` 目录下所有文件拖进 Xcode 工程导航区，勾选 **"Copy items if needed"** 和 **"Create groups"**：

```
HomeIPTVApp.swift          ← 替换 Xcode 自动生成的同名文件
Models/Channel.swift
Services/PlaylistStore.swift
Views/ChannelListView.swift
Views/PlayerView.swift
```

拖完后删掉 Xcode 自动生成的 `ContentView.swift`（我们用 `ChannelListView` 代替了它）。

## 第三步：改订阅地址

打开 `swift/Services/PlaylistStore.swift`，找到这一行：

```swift
@AppStorage("playlistURL") var playlistURL = "https://iptv-org.github.io/iptv/index.m3u"
```

**开发调试阶段**先保持这个值（直接用 iptv-org 官方全球源，不用等自己的 GitHub Pages 部署好）。
**上架前**换成你自己的聚合服务地址：
```
https://<你的GitHub用户名>.github.io/home-iptv/hd.m3u
```

## 第四步：连 Apple TV 真机调试

1. Apple TV 上：**设置 → 遥控器和设备 → 远程 App 和设备**，保持这个界面打开（配对模式）
2. Mac 上：Xcode → **Window → Devices and Simulators**
3. 用同一根 USB-C 线连 Apple TV（或同一 Wi-Fi 下自动发现）
4. Xcode 顶部设备选你的 Apple TV → 点 ▶️ Run

> 第一次装会要在 Apple TV 上：**设置 → 通用 → 设备管理 → 信任开发者证书**。

## 第五步：跑起来后你应该看到

- 左侧分类侧栏（全部 / News / Sports / ...）
- 右侧频道网格，每个卡片有 logo + 名字
- 遥控器点中任意频道 → 全屏播放 HLS 直播流
- 右上角"刷新"按钮手动更新列表；每 6 小时自动更新

## 第六步：上架流程（按你 B4 业务线既有节奏）

1. Xcode → Product → Archive → 上传到 App Store Connect
2. 在 ASC 填描述、截图、隐私问卷（要声明"只聚合公开免费频道"）
3. TestFlight 内部测试 → 提交审核
4. 定价按你 B4 业务线统一 **$1**

## 关键 Info.plist 配置

如果未来要加局域网源（比如树莓派 `http://192.168.x.x:8080/hd.m3u`），需要在 Info.plist 加 ATS 例外：

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

当前默认订阅是 `https://` 开头的 GitHub Pages，不需要这个例外。

## 后续可迭代功能（按优先级）

1. **EPG 节目单**：拉 `https://iptv-org.github.io/epg/guides/cn.xml.gz`，用 `SwiftyXMLParser` 解析，在频道卡片下方显示"正在播出/接下来"
2. **收藏夹**：用 `@AppStorage` 存收藏的频道 ID，置顶显示
3. **多订阅源**：设置页允许用户添加自己的 m3u URL
4. **播放失败自动切源**：AVPlayer 报错时自动在同组频道里切下一个
5. **画中画/后台播放**：tvOS 上默认支持
