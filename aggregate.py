# -*- coding: utf-8 -*-
"""
全球高清直播源聚合器（多线路版）
====================================
定时拉取多个上游公开 FTA 直播源仓库，按规范显示名聚合同频道多线路、
并发探活、剔除死链、央视靠前排序，输出标准 M3U 播放列表。

多线路：同一频道来自不同上游的多个 URL 全部保留并写入 m3u（重复 EXTINF + 多 URL），
Apple TV 端按 displayName 聚合，起播失败自动切换备用线路。

用法:
    python aggregate.py
输出:
    out/index.m3u          全量可用（多线路）
    out/hd.m3u / cn.m3u    兼容别名
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

# ---------- 上游源（开源社区维护的公开 FTA 源） ----------
UPSTREAMS = [
    {
        "name": "iptv-org-global",
        "url": "https://iptv-org.github.io/iptv/index.m3u",
        "scope": "global",
    },
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

PROBE_TIMEOUT = 4.0
PROBE_WORKERS = 25
HEALTHY_MAX_MS = 3500

OUT_DIR = Path(__file__).parent / "out"
UA = "Mozilla/5.0 (compatible; HomeIPTV/1.0; +https://example.com)"

RE_EXTINF = re.compile(
    r'#EXTINF:(?P<dur>[^,]*?)\s*(?P<attrs>[^,]*),(?P<name>.+)'
)
RE_ATTR = re.compile(r'([a-zA-Z0-9-_]+)="([^"]*)"')


def clean_name(name: str) -> str:
    """上游脏数据清洗：UA 残片、[Not 24/7]、分辨率、多余空格"""
    name = name.strip()
    if '",' in name:
        name = name.split('",')[-1].strip()
    # 去掉 [Not 24/7] 等运营说明
    name = re.sub(r'\[[^\]]*\]', '', name)
    # 去掉 (720p) (1080p) (600p) (576i) 等分辨率
    name = re.sub(r'\s*\(\d+[pi]\)', '', name)
    # 压缩多余空格
    name = re.sub(r'\s+', ' ', name).strip()
    return name


def display_key(name: str) -> str:
    """聚合键：规范显示名。CCTV-1综合 / CCTV-1 / CCTV-1 (1080p) 视为同一频道"""
    n = clean_name(name)
    m = re.match(r'(CCTV)[- ]?(\d+[K+]*)', n, re.IGNORECASE)
    if m:
        return f"{m.group(1)}-{m.group(2)}".upper()
    # 卫视：去掉"卫视"前后修饰？保留完整名（湖南卫视/浙江卫视唯一）
    return n.lower()


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
                    "name": clean_name(m.group("name")),
                    "tvg_id": attrs.get("tvg-id", ""),
                    "tvg_name": attrs.get("tvg-name", ""),
                    "logo": attrs.get("tvg-logo", ""),
                    "group": attrs.get("group-title", "未分类"),
                    "url": "",
                    "source": source,
                    "scope": scope,
                }
        elif line.startswith("#"):
            pass
        elif cur is not None:
            cur["url"] = line
            channels.append(cur)
            cur = None
        i += 1
    return channels


# ============================================================
# 2. 多线路聚合（同规范显示名的频道合并，保留全部线路）
# ============================================================
def aggregate(channels):
    buckets = {}
    for c in channels:
        key = display_key(c["name"])
        if key not in buckets:
            buckets[key] = []
        bucket = buckets[key]
        if not any(b["url"] == c["url"] for b in bucket):
            bucket.append(c)
    out = []
    for key, bucket in buckets.items():
        first = dict(bucket[0])
        first["urls"] = [b["url"] for b in bucket]
        first["url"] = first["urls"][0]
        out.append(first)
    return out


# ============================================================
# 3. 并发探活（多线路分别探活，剔除死线路）
# ============================================================
def probe(c):
    results = []
    for url in c["urls"]:
        entry = dict(c)
        entry["url"] = url
        if not url or not (url.startswith("http://") or url.startswith("https://")):
            entry["ok"] = False
            entry["ms"] = 99999
            results.append(entry)
            continue
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        t0 = time.time()
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": UA, "Accept": "*/*"}, method="HEAD"
            )
            with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT, context=ctx) as r:
                status = r.status
            entry["ms"] = int((time.time() - t0) * 1000)
            entry["ok"] = status < 400
        except Exception:
            try:
                t0 = time.time()
                req = urllib.request.Request(url, headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT, context=ctx) as r:
                    chunk = r.read(64 * 1024)
                entry["ms"] = int((time.time() - t0) * 1000)
                entry["status"] = 200
                entry["ok"] = len(chunk) > 0
            except Exception as e:
                entry["ok"] = False
                entry["ms"] = 99999
                entry["err"] = type(e).__name__
        results.append(entry)
    return results


# ============================================================
# 4. 输出 m3u（同频道多线路重复 EXTINF + 多 URL）
# ============================================================
def write_m3u(path: Path, channels):
    lines = ["#EXTM3U"]
    for c in channels:
        urls = [u for u in c["urls"] if u]
        if not urls:
            continue
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
        for u in urls:
            lines.append(f'#EXTINF:-1 {attr_str},{c["name"]}')
            lines.append(u)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    import os
    QUICK = os.environ.get("QUICK", "1") == "1"  # QUICK=1 跳过探活（本地快速验证）
    socket.setdefaulttimeout(PROBE_TIMEOUT)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

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

    # global 源只保留中文相关频道（CJK 名 或 CCTV/CGTN），避免混入海量外语台
    all_channels = [c for c in all_channels
                    if c["scope"] != "global"
                    or re.search(r"[\u4e00-\u9fff]", c["name"])
                    or re.match(r"(CCTV|CGTN)", c["name"], re.IGNORECASE)]
    print(f"global 过滤后: {len(all_channels)}")

    before = len(all_channels)
    all_channels = aggregate(all_channels)
    print(f"aggregate: {before} -> {len(all_channels)} channels")

    if QUICK:
        print("QUICK=1 跳过探活，全部视为存活")
        alive = all_channels
        dead = []
    else:
        print(f"probing {len(all_channels)} channels with {PROBE_WORKERS} workers ...")
        flat_results = []
        with cf.ThreadPoolExecutor(max_workers=PROBE_WORKERS) as ex:
            for i, res in enumerate(ex.map(probe, all_channels)):
                flat_results.append(res)
        # 重组：频道保留存活线路
        alive = []
        dead = []
        for res in flat_results:
            good = [e for e in res if e["ok"] and e["ms"] <= HEALTHY_MAX_MS]
            if good:
                ch = dict(res[0])
                ch["urls"] = [e["url"] for e in good]
                ch["url"] = ch["urls"][0]
                ch["ms"] = min(e["ms"] for e in good)
                alive.append(ch)
            else:
                dead.append(res[0])
        print(f"alive: {len(alive)}, dead: {len(dead)}")

    def sort_key(c):
        n = c["name"]
        m = re.match(r'(?:CCTV|中央电视台|中央)[ -]?(\d+)', n, re.IGNORECASE)
        if m:
            return (0, int(m.group(1)), c.get("ms", 9999))
        return (1, 0, c.get("ms", 9999))
    alive.sort(key=sort_key)

    write_m3u(OUT_DIR / "index.m3u", alive)
    write_m3u(OUT_DIR / "hd.m3u", alive)
    write_m3u(OUT_DIR / "cn.m3u", alive)

    multi = sum(1 for c in alive if len(c["urls"]) > 1)
    total_lines = sum(len(c["urls"]) for c in alive)
    print(f"多线路频道: {multi}/{len(alive)}, 总线路: {total_lines}")

    import json
    summary = {
        "generated_at": int(time.time()),
        "upstream_count": len(UPSTREAMS),
        "total_aggregate": len(alive),
        "multi_source": multi,
        "total_lines": total_lines,
        "alive": len(alive),
        "dead": len(dead),
        "quick_mode": QUICK,
    }
    (OUT_DIR / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print("summary:", summary)
    print("done ->", OUT_DIR)


if __name__ == "__main__":
    main()
