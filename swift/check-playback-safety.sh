#!/usr/bin/env bash
#
# 播放安全静态检查 —— "机顶盒无法关机" 故障的回归门禁。
#
# 用法：bash swift/check-playback-safety.sh
# 退出码：0 = 通过，1 = 命中禁用写法
#
# 之所以查这几条：2026-10-11 的故障成因是「声明后台音频 + 播放器从不停止 +
# 音频会话从不释放」，系统在音频播放期间不会休眠，于是机顶盒关不掉。
# 这类改动只需要一行 plist 就能重新引入，所以由脚本挡住。
# 详见 swift/FAULT-2026-10-11-box-wont-power-off.md

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
root=$(pwd)
fail=0

note() { printf '%s\n' "$*"; }
bad()  { printf '❌ %s\n' "$*"; fail=1; }
ok()   { printf '✅ %s\n' "$*"; }

# 1) 后台音频能力：只可能声明在 plist 或工程描述里
if grep -n "UIBackgroundModes" project.yml swift/Info.plist 2>/dev/null; then
  bad "声明了 UIBackgroundModes。后台音频会让系统在播放期间不休眠，机顶盒会关不掉。"
else
  ok "未声明后台音频能力（project.yml / swift/Info.plist 均干净）"
fi

# 2) 休眠计时器：一旦没恢复成 false，设备永远无法休眠
if grep -rn --include='*.swift' "isIdleTimerDisabled *= *true" swift; then
  bad "使用了 isIdleTimerDisabled = true。没有恢复成 false 时设备无法休眠，属于同一类故障。"
else
  ok "未占用休眠计时器"
fi

# 3) 停止播放的三条路径必须都在
check_contains() { # <file> <pattern> <desc>
  if grep -q "$2" "$1" 2>/dev/null; then
    ok "$3"
  else
    bad "$3 —— 在 $1 中找不到 $2"
  fi
}
check_contains swift/Services/PlaybackController.swift "func stop(reason" "PlaybackController 提供 stop(reason:)"
check_contains swift/Services/PlaybackController.swift "deactivateAudioSession" "停止时释放音频会话"
check_contains swift/Views/ChannelListView.swift      "playback.stop"          "关闭播放页会停止播放"
check_contains swift/HomeIPTVApp.swift                "didEnterBackgroundNotification" "进入后台会停止播放"
check_contains swift/Services/PlaybackController.swift "failedToPlayToEndTime"  "流失败会收摊"

if [ "$fail" -eq 0 ]; then
  # 变量后面紧跟中文括号时必须写成 ${root}：
  # bash 会把非 ASCII 字节当成变量名的一部分，配合 set -u 直接报未定义变量
  note "播放安全检查通过（${root}）"
else
  note "播放安全检查未通过（${root}）"
fi
exit "$fail"
