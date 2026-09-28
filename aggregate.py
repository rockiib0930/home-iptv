# -*- coding: utf-8 -*-
"""
全球高清直播源聚合器
====================
定时拉取多个上游公开 FTA (Free-To-Air) 直播源仓库，去重、并发探活、按可用性排序，
输出标准 M3U 播放列表，供 Apple TV 上的开源播放器（aptv / StreamVision 等）订阅。

设计原则：
- 不存储任何视频文件，只聚合公开可访问的 HLS/m3u8 地址；
- 上游已经由 iptv-org 等社区维护并自动去死链，本脚本只做"多源合并 + 二次探活 + 排序"；
- 纯标准库实现，无需 pip install，GitHub Actions 上开箱即跑；
- 输出到 ./out/ 目录，由 GitHub Pages 静态托管。

用法:
    python aggregate.py
输出:
    out/index.m3u          全量合并（推荐给 Apple TV 订阅的主地址）
    out/hd.m3u             仅保留可用且延迟达标的频道
    out/cn.m3u             中文频道聚合
    out/UNSUPPORTED.md      被剔除的源及原因（调试用）
"""
import concurrent.futures as cf
import gzip
import io
import re
import socket
import ssl
import time
import urllib.request
from pathlib import Path

# ---------- 上游源（全部为开源社区维护、CC0/公开 FTA 协议） ----------
# 国内可用源优先：iptv-org CN 频道 + fanmingming 国内直播源
UPSTREAMS = [
    {
        "name": "iptv-org-cn",
        "url": "https://iptv-org.github.io/iptv/countries/cn.m3u",
        "scope": "cn",
    },
    {
        "name": "fanmingming-index",
        "url": "https://cdn.jsdelivr.net/gh/fanmingming/live@main/tv/m3u/index.m3u",
        "scope": "cn",
    },
    {
        "name": "fanmingming-ipv6",
        "url": "https://cdn.jsdelivr.net/gh/fanmingming/live@main/tv/m3u/ipv6.m3u",
        "scope": "cn",
    },
]

# ---------- 探活参数 ----------
PROBE_TIMEOUT = 4.0          # 单源探测超时（秒）
PROBE_WORKERS = 25           # 并发数（GitHub Actions runner 带宽有限，别太大）
HEALTHY_MIN_MS = 0           # 延迟低于此值视为"极速"，仅用于排序权重
HEALTHY_MAX_MS = 3500        # 高于此值视为不可用，剔除

OUT_DIR = Path(__file__).parent / "out"
UA = "Mozilla/5.0 (compatible; HomeIPTV/1.0; +https://example.com)"

# ---------- 正则 ----------
RE_EXTINF = re.compile(
    r'#EXTINF:(?P<dur>[^,]*?)\s*(?P<attrs>[^,]*),(?P<name>.+)'
)
RE_ATTR = re.compile(r'([a-zA-Z0-9-_]+)="([^"]*)"')


# ============================================================
# 1. 拉取与解析
# ============================================================
def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(req, timeout=30, context=ctx) as r:
        data = r.read()
    if url.endswith(".gz") or data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    return data.decode("utf-8", errors="replace")


def parse_m3u(text: str, source: str, scope: str):
    """把一份 m3u 文本解析成频道列表。每个频道是 dict。"""
    channels = []
    lines = text.splitlines()
    i = 0
    cur = None
    while i < len(lines):
        line = lines[i].strip()
        if not line:
            i += 1
            continue
        if line.startswith("#EXTINF:"):
            m = RE_EXTINF.match(line)
            if m:
                attrs = dict(RE_ATTR.findall(m.group("attrs")))
                cur = {
                    "name": m.group("name").strip(),
                    "tvg_id": attrs.get("tvg-id", ""),
                    "tvg_name": attrs.get("tvg-name", ""),
                    "logo": attrs.get("tvg-logo", ""),
                    "group": attrs.get("group-title", "未分类"),
                    "url": "",
                    "source": source,
                    "scope": scope,
                }
        elif line.startswith("#"):
            # 其他标签（#EXTGRP 等）暂不处理
            pass
        elif cur is not None:
            cur["url"] = line
            channels.append(cur)
            cur = None
        i += 1
    return channels


# ============================================================
# 2. 去重
# ============================================================
def dedup(channels):
    """按 (频道名, 分组) 去重；同频道多源保留第一个。"""
    seen = set()
    out = []
    for c in channels:
        key = (c["name"].lower().strip(), c["group"].lower().strip())
        if key in seen:
            continue
        seen.add(key)
        out.append(c)
    return out


# ============================================================
# 3. 并发探活（HEAD 优先，失败回退 GET range）
# ============================================================
def probe(c):
    url = c["url"]
    if not url or not (url.startswith("http://") or url.startswith("https://")):
        c["ok"] = False
        c["ms"] = 99999
        return c
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    t0 = time.time()
    try:
        req = urllib.request.Request(
            url,
            headers={"User-Agent": UA, "Accept": "*/*"},
            method="HEAD",
        )
        with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT, context=ctx) as r:
            c["status"] = r.status
        c["ms"] = int((time.time() - t0) * 1000)
        c["ok"] = c["status"] < 400
    except Exception:
        # HEAD 被拒绝的源（很多 HLS 服务器只认 GET），退一次 GET
        try:
            t0 = time.time()
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT, context=ctx) as r:
                chunk = r.read(64 * 1024)  # 只读前 64KB，能开始吐数据就算活
            c["ms"] = int((time.time() - t0) * 1000)
            c["status"] = 200
            c["ok"] = len(chunk) > 0
        except Exception as e:
            c["ok"] = False
            c["ms"] = 99999
            c["err"] = type(e).__name__
    return c


# ============================================================
# 4. 输出 m3u
# ============================================================
def write_m3u(path: Path, channels):
    lines = ["#EXTM3U"]
    for c in channels:
        attrs = []
        if c.get("tvg_id"):
            attrs.append(f'tvg-id="{c["tvg_id"]}"')
        if c.get("tvg_name"):
            attrs.append(f'tvg-name="{c["tvg_name"]}"')
        if c.get("logo"):
            attrs.append(f'tvg-logo="{c["logo"]}"')
        if c.get("group"):
            attrs.append(f'group-title="{c["group"]}"')
        attr_str = " ".join(attrs)
        lines.append(f'#EXTINF:-1 {attr_str},{c["name"]}')
        lines.append(c["url"])
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    import os
    QUICK = os.environ.get("QUICK", "0") == "1"  # QUICK=1 跳过探活，本地快速验证用
    socket.setdefaulttimeout(PROBE_TIMEOUT)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # 拉所有上游
    all_channels = []
    fetch_log = []
    for up in UPSTREAMS:
        try:
            text = fetch(up["url"])
            chs = parse_m3u(text, up["name"], up["scope"])
            fetch_log.append(f"[OK] {up['name']}: {len(chs)} channels")
            all_channels.extend(chs)
        except Exception as e:
            fetch_log.append(f"[FAIL] {up['name']}: {type(e).__name__} {e}")

    print("\n".join(fetch_log))

    # 去重
    before = len(all_channels)
    all_channels = dedup(all_channels)
    print(f"dedup: {before} -> {len(all_channels)}")

    # 探活
    if QUICK:
        print("QUICK=1 跳过探活，全部视为存活")
        alive = all_channels
        dead = []
    else:
        print(f"probing {len(all_channels)} channels with {PROBE_WORKERS} workers ...")
        results = []
        with cf.ThreadPoolExecutor(max_workers=PROBE_WORKERS) as ex:
            for i, c in enumerate(ex.map(probe, all_channels)):
                results.append(c)
                if (i + 1) % 200 == 0:
                    print(f"  probed {i+1}/{len(all_channels)}")

        alive = [c for c in results if c["ok"] and c["ms"] <= HEALTHY_MAX_MS]
        dead = [c for c in results if not (c["ok"] and c["ms"] <= HEALTHY_MAX_MS)]

    # 排序：中央台(CCTV/中央)最前，按频道号数字升序；其余地方台按延迟排
    def sort_key(c):
        n = c["name"]
        m = re.match(r'(?:CCTV|中央电视台|中央)[ -]?(\d+)', n, re.IGNORECASE)
        if m:
            return (0, int(m.group(1)), c.get("ms", 9999))
        return (1, 0, c.get("ms", 9999))
    alive.sort(key=sort_key)
    print(f"alive: {len(alive)}, dead: {len(dead)}")

    # index.m3u = 探活后存活的国内频道（按延迟排序）
    write_m3u(OUT_DIR / "index.m3u", alive)
    # hd.m3u 同 index（保留兼容）
    write_m3u(OUT_DIR / "hd.m3u", alive)
    # cn.m3u 同 index
    write_m3u(OUT_DIR / "cn.m3u", alive)

    # 调试日志
    (OUT_DIR / "UNSUPPORTED.md").write_text(
        "# 被标记不可用的频道（前 200 条，调试用）\n\n"
        + "\n".join(f"- {c['name']} ({c['url'][:80]}) ms={c.get('ms')} err={c.get('err','')}"
                     for c in dead[:200]),
        encoding="utf-8",
    )

    # 汇总
    summary = {
        "generated_at": int(time.time()),
        "upstream_count": len(UPSTREAMS),
        "total_dedup": len(all_channels),
        "alive": len(alive),
        "dead": len(dead),
        "avg_ms_alive": (
            round(sum(c.get("ms", 0) for c in alive) / max(len(alive), 1), 1)
            if not QUICK else None
        ),
        "quick_mode": QUICK,
    }
    import json
    (OUT_DIR / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print("summary:", summary)
    print("done ->", OUT_DIR)


if __name__ == "__main__":
    main()
