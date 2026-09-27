# HomeIPTV — Apple TV 全球高清直播源聚合服务

> 不做 App，做"内容订阅源"。Apple TV 端直接用已上架的开源播放器订阅本服务输出的 m3u。

---

## 为什么是这个方案（决策结论）

| 约束 | 现实 | 结论 |
|---|---|---|
| 开发机是 Windows | tvOS 必须用 macOS + Xcode 编译签名 | 不能本地编译 |
| 硬件预算限树莓派档 | 不买 Mac Mini / MacBook | 不能走原生 App 路线 |
| Apple TV 没有浏览器 | tvOS 无 Safari，WebApp 打不开 | 不能做网页版 |
| 目标是"自动扫描全球高清视频" | 已有 iptv-org 等开源社区每天自动维护 | **直接订阅 + 二次聚合，不重复造轮子** |

**最终形态**：
```
GitHub Actions（每 6 小时）
   │  拉 iptv-org / fanmingming 等公开源
   │  并发探活、按延迟排序、去重
   ▼
GitHub Pages 静态托管 m3u
   │
   │  订阅 URL
   ▼
Apple TV 上的 aptv（已上架 App Store，免费开源）
```

- **0 元**：GitHub Actions 免费额度 + GitHub Pages 免费托管，连树莓派都可以不用。
- **自动更新**：每 6 小时自动跑一次，死链自动剔除，新源自动收录。
- **全球高清**：iptv-org 覆盖 200+ 国家 4000+ 公开频道，fanmingming 补国内 IPv4/IPv6 源。
- **零原生开发**：不用写一行 Swift，不用买 Mac，不用过 App Store 审核。

---

## 部署步骤（10 分钟）

### 1. 建仓库
在 GitHub 新建一个 Public 仓库（比如叫 `home-iptv`），把本目录三个文件推上去：
```
aggregate.py
.github/workflows/update.yml
README.md
```

### 2. 开启 GitHub Pages
仓库 → Settings → Pages → Source 选 **GitHub Actions**。

### 3. 触发一次
仓库 → Actions → 选 "更新直播源并发布" → Run workflow。
等跑完（约 3-5 分钟），访问：
```
https://<你的用户名>.github.io/home-iptv/index.m3u     # 全量
https://<你的用户名>.github.io/home-iptv/hd.m3u        # 仅存活快速源（推荐）
https://<你的用户名>.github.io/home-iptv/cn.m3u        # 中文频道
```

之后每 6 小时自动更新，无需手动操作。

---

## Apple TV 端怎么用

1. 在 Apple TV App Store 搜索并安装 **APTV**（免费，开发者 Kimentanm，开源）。
   - 下载地址：https://apps.apple.com/app/aptv/id1630403500
   - 源码：https://github.com/Kimentanm/aptv
2. 打开 APTV → 设置 → **播放列表 / Playlist** → 添加远程 URL。
3. 粘贴上面的 `hd.m3u` 地址。
4. 完成。APTV 会自动定时刷新播放列表，EPG（节目单）可在设置里再填：
   ```
   https://iptv-org.github.io/epg/guides/cn.xml.gz
   ```

> 为什么不自己写 App：APTV 已经原生支持 tvOS 遥控、4K/HDR/HEVC 硬解、时移回看、iCloud 同步收藏，且已通过 Apple 审核上架。自己从零写 tvOS 工程在 Windows 上根本没法编译签名，性价比为零。

---

## 加一层树莓派加速（可选）

如果你在国内访问 GitHub Pages 慢、或想要局域网内秒开：

在树莓派上跑一个反向代理/缓存，把上面的 m3u 地址本地镜像一份：
```bash
# 树莓派上一行（需要 nginx）
# 把 https://<你的用户名>.github.io/home-iptv/ 反代到 http://树莓派IP:8080/
```
然后 APTV 里订阅 `http://树莓派IP:8080/hd.m3u`。
树莓派同时可以做测速节点，把最快的源推到最前面。

---

## 文件说明

| 文件 | 作用 |
|---|---|
| `aggregate.py` | 聚合脚本：拉上游 → 解析 m3u → 去重 → 并发探活 → 排序输出 |
| `.github/workflows/update.yml` | 每 6 小时自动跑一次并发布到 Pages |
| `out/index.m3u` | 全量频道（含可能失效的，播放器自己兜底） |
| `out/hd.m3u` | **推荐订阅**：仅存活且延迟 < 3.5s 的频道，按速度排序 |
| `out/cn.m3u` | 中文频道子集 |
| `out/summary.json` | 本次运行统计（总数/存活数/平均延迟） |

---

## 合规红线（必须遵守）

- 本项目只聚合 **iptv-org、fanmingming/live** 等仓库收录的 **Free-To-Air 公开频道**，这些频道本身就是面向互联网公开广播的。
- **不要**在 `UPSTREAMS` 里加入盗版 IPTV 套餐源、加密付费频道、版权体育直播——会触发 DMCA，GitHub 会删仓库。
- 个人家庭自用，不要二次售卖、不要公开分发到大型社交平台引流。
