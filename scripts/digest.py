#!/usr/bin/env python3
"""把一天的剪贴板历史洗成一份能直接读的清单。

验证用的工具，不进 app。跑法：

    python3 scripts/digest.py            # 今天
    python3 scripts/digest.py 2026-11-07 # 某一天
    python3 scripts/digest.py --days 3   # 最近三天

它只做三件事：扔掉不是内容的、合并重复的、按时间排好。分类和措辞不归它，
那是读它的那个东西的事。

数据从哪来：`Attic` 写的 History.json，14 天保留期（默认）。图片不读像素 ——
`Pegged.ocr` 里已经有字了，Vision 早就读过了。
"""

import collections
import concurrent.futures
import datetime
import html as htmllib
import json
import os
import re
import sqlite3
import ssl
import sys
import urllib.request

HISTORY = os.path.expanduser("~/Library/Application Support/Clothespeg/History.json")

# 短于这个字数的算划词碎片，不算一条内容。「矿车。」「你。」都在这条线下面。
MIN_CHARS = 6

# 固定串：微信「提取文字」会挂一张内容是这几个字的卡，一天能挂十几张。
JUNK = {"OCR 识别结果文字"}

URL_ONLY = re.compile(r"^https?://\S+$")
URL_ANY = re.compile(r"https?://[^\s，。、）)」』]+")

# `Origin.at` 落盘时是 `timeIntervalSinceReferenceDate`（2001-01-01 起算），
# 不是 Unix 纪元。差 978307200 秒，不加这个偏移每一天都查不到东西。
COCOA_EPOCH = 978307200


def when(entry):
    return datetime.datetime.fromtimestamp(entry["origin"]["at"] + COCOA_EPOCH)


def load(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return data if isinstance(data, list) else data.get("entries", [])


def body(entry):
    """这一条的内容，和它是什么。

    返回 (文本, 种类)。图片的文本取自已经读好的 OCR —— 空字符串是「读过，
    上面没有字」，和「没读过」不同，但这里都当没有内容。
    """
    payload = entry.get("payload") or {}
    if not isinstance(payload, dict):
        return "", "?"
    if "text" in payload:
        text = (payload["text"] or {}).get("_0", "")
        return text, "code" if (payload["text"] or {}).get("isCode") else "text"
    if "image" in payload:
        return (entry.get("ocr") or "").strip(), "picture"
    if "file" in payload:
        files = (payload["file"] or {}).get("_0") or []
        names = [os.path.basename(str(u).replace("file://", "")) for u in files]
        return "\n".join(names), "file"
    if "note" in payload:
        note = payload["note"] or {}
        return str(note.get("body") or note.get("text") or ""), "note"
    return "", "?"


def tidy(text):
    """抹平空白，用来判重和判垃圾。原文不动。"""
    return re.sub(r"\s+", " ", text).strip()


def worth(text, kind):
    """这条值不值得留。规则都来自真实历史，不是想象的：

    - 太短的是划词碎片
    - 固定串是某个 app 的噪声
    - 纯文件清单没有可读内容
    """
    clean = tidy(text)
    if kind == "file":
        return False
    if clean in JUNK:
        return False
    if len(clean) < MIN_CHARS:
        return False
    return True


CACHE_DIR = os.path.expanduser("~/.cache/clothespeg-digest")
CACHE = os.path.join(CACHE_DIR, "titles.json")
AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
         "(KHTML, like Gecko) Version/17.0 Safari/605.1.15")
TITLE_CHARS = 160
DESC_CHARS = 240


def lookup(url):
    """一个链接的标题和描述，或者两个空串。

    HTML 到此为止：送出去的是一句话，不是一整页。抓不到就空着 —— 一个编出来
    的标题比没有标题坏得多，读的人没法分辨。
    """
    try:
        request = urllib.request.Request(url, headers={"User-Agent": AGENT})
        with urllib.request.urlopen(request, timeout=12) as answer:
            page = answer.read(600_000).decode("utf-8", "ignore")
    except Exception:
        return ["", ""]

    def clean(match, limit):
        if not match:
            return ""
        text = htmllib.unescape(re.sub(r"\s+", " ", match.group(1)))
        return text.strip()[:limit]

    title = clean(re.search(r"<title[^>]*>(.*?)</title>", page, re.S), TITLE_CHARS)
    desc = clean(re.search(
        r'<meta[^>]+(?:name|property)=["\'](?:og:)?description["\'][^>]+content=["\'](.*?)["\']',
        page, re.S), DESC_CHARS)
    return [title or desc, desc]


def titles_for(urls):
    """并发抓，按 URL 缓存。同一个链接一个月抓一次就够，抓过的存在本机。"""
    try:
        with open(CACHE, encoding="utf-8") as f:
            cache = json.load(f)
    except (OSError, ValueError):
        cache = {}
    todo = [u for u in urls if u not in cache]
    if todo:
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            for url, found in zip(todo, pool.map(lookup, todo)):
                cache[url] = found
        try:
            os.makedirs(CACHE_DIR, exist_ok=True)
            with open(CACHE, "w", encoding="utf-8") as f:
                json.dump(cache, f, ensure_ascii=False, indent=1)
        except OSError:
            pass
    return cache


SAFARI = os.path.expanduser("~/Library/Safari/History.db")

# 一天几百次访问，逐条列出来没人看，也没信息量 —— 今天 328 次访问里 219 次
# 是同一个素材站。所以浏览记录只报「按站聚合」：谁占了时间，看了什么。
# 逐条的原始 URL 不落盘，也不进日报。
SITE_MIN_VISITS = 2
TITLES_PER_SITE = 6


def safari_sites(since, until):
    """某个时间段里的浏览，按站聚合。Safari 没开也能读。

    读的是只读快照（`immutable=1`）：Safari 正在写这个库的时候，加锁的正常
    打开会失败，而快照模式读到的是一份一致的旧版，够用了。
    """
    if not os.path.exists(SAFARI):
        return None
    try:
        db = sqlite3.connect("file:%s?immutable=1" % SAFARI, uri=True, timeout=2)
        rows = db.execute(
            "select v.visit_time, i.url, v.title from history_visits v "
            "join history_items i on i.id = v.history_item "
            "where v.visit_time > ? and v.visit_time < ?",
            (since.timestamp() - COCOA_EPOCH, until.timestamp() - COCOA_EPOCH)).fetchall()
        db.close()
    except sqlite3.Error:
        return None

    sites = collections.OrderedDict()
    pages = set()
    skipped = 0
    for _, url, title in rows:
        if not re.match(r"^https?://", url or ""):
            skipped += 1
            continue
        host = (url.split("/")[2] if "://" in url else url).lower()
        if host.startswith("127.0.0.1") or host.startswith("localhost") or ":" in host:
            skipped += 1
            continue
        pages.add(url)
        site = sites.setdefault(host, {"visits": 0, "pages": set(), "titles": []})
        site["visits"] += 1
        site["pages"].add(url)
        said = (title or "").strip()
        if said and said not in site["titles"] and len(site["titles"]) < TITLES_PER_SITE:
            site["titles"].append(said)

    ordered = sorted(sites.items(), key=lambda kv: -kv[1]["visits"])
    return {
        "visits": len(rows),
        "pages": len(pages),
        "skipped": skipped,
        "sites": [(host, s["visits"], len(s["pages"]), s["titles"])
                  for host, s in ordered if s["visits"] >= SITE_MIN_VISITS],
        "quiet": sum(1 for _, s in ordered if s["visits"] < SITE_MIN_VISITS),
    }


def render_safari(found):
    if not found or not found["sites"]:
        return ""
    out = ["## 浏览（Safari）", ""]
    out.append("%d 次访问 · %d 个页面 · %d 个站"
               % (found["visits"], found["pages"], len(found["sites"])))
    out.append("")
    for host, visits, pages, titles in found["sites"]:
        out.append("- **%s** · %d 次 · %d 个页面" % (host, visits, pages))
        if titles:
            out.append("  " + " / ".join(titles))
    if found["quiet"]:
        out.append("")
        out.append("（另有 %d 个站只访问了一次，没列）" % found["quiet"])
    out.append("")
    return "\n".join(out)


def shape(text, kind):
    clean = tidy(text)
    if kind == "picture":
        return "图"
    if URL_ONLY.match(clean):
        return "链接"
    if kind == "code":
        return "代码"
    if URL_ANY.search(clean):
        return "含链接"
    return "文字"


def collect(entries, since, until):
    kept = collections.OrderedDict()
    dropped = collections.Counter()
    total = 0
    for entry in entries:
        try:
            at = when(entry)
        except (KeyError, TypeError, ValueError):
            continue
        if not (since <= at < until):
            continue
        total += 1
        text, kind = body(entry)
        if not worth(text, kind):
            dropped["短于 %d 字 / 固定串 / 文件" % MIN_CHARS] += 1
            continue
        key = tidy(text)
        if key in kept:
            kept[key]["count"] += 1
            kept[key]["times"].append(at.strftime("%H:%M"))
            continue
        kept[key] = {
            "at": at,
            "app": entry["origin"].get("app") or "?",
            "text": text if kind != "picture" else text,
            "kind": kind,
            "where": shape(text, kind),
            "count": 1,
            "times": [at.strftime("%H:%M")],
        }
    return list(kept.values()), total, dropped


def render(items, day, total, dropped):
    out = []
    out.append("## %s" % day)
    out.append("")
    out.append("原始 %d 条 → 去重去噪后 %d 条（丢掉 %d）"
               % (total, len(items), sum(dropped.values())))
    out.append("")
    for item in items:
        heading = "%s · %s · %s" % (item["times"][0], item["app"], item["where"])
        if item["count"] > 1:
            heading += " · 复制了 %d 次（%s）" % (item["count"], ", ".join(item["times"]))
        out.append("### " + heading)
        if item.get("title"):
            out.append("**" + item["title"] + "**")
        out.append(item["text"].strip())
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def main(argv):
    days = 1
    wanted = None
    fetch = True
    safari = True
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--days":
            i += 1
            days = int(argv[i])
        elif arg == "--no-fetch":
            fetch = False
        elif arg == "--no-safari":
            safari = False
        elif re.match(r"^\d{4}-\d{2}-\d{2}$", arg):
            wanted = arg
        i += 1

    entries = load(HISTORY)
    now = datetime.datetime.now()

    if wanted:
        start = datetime.datetime.strptime(wanted, "%Y-%m-%d")
        spans = [(wanted, start, start + datetime.timedelta(days=1))]
    else:
        spans = []
        for back in range(days - 1, -1, -1):
            day = (now - datetime.timedelta(days=back)).strftime("%Y-%m-%d")
            start = datetime.datetime.strptime(day, "%Y-%m-%d")
            spans.append((day, start, start + datetime.timedelta(days=1)))

    # 跨这几天的去重：同一个链接昨天也复制过，只算它第一次出现的那天。
    seen = set()
    blocks = []
    for day, since, until in spans:
        items, total, dropped = collect(entries, since, until)
        fresh = []
        for item in items:
            key = tidy(item["text"])
            if key in seen:
                continue
            seen.add(key)
            fresh.append(item)
        if fetch and fresh:
            asked = [item["text"].strip() for item in fresh if item["where"] == "链接"]
            found = titles_for(asked) if asked else {}
            for item in fresh:
                got = found.get(item["text"].strip())
                if got and got[0]:
                    item["title"] = got[0]
        blocks.append(render(fresh, day, total, dropped))
        if safari:
            browsed = render_safari(safari_sites(since, until))
            if browsed:
                blocks.append(browsed)
    sys.stdout.write("\n".join(blocks))


if __name__ == "__main__":
    main(sys.argv[1:])
