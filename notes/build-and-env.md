# 构建、日志与排查

> 从 `.workbuddy/memory/MEMORY.md` 外置而来（2026-11-03 重建时拆出）。
> 相关：`notes/release-and-repo.md`（发版与仓库）。

## 命令行环境

- macOS 无 `timeout`；长命令用 `run_in_background`。
- zsh 里变量不能叫 `path`；循环里用 `env VAR=… $BIN`（`A_$s=1` 这种带展开的赋值不合法）。
- `swift build` 必须带 `--disable-sandbox`，且工具调用要 `dangerouslyDisableSandbox`。
- `xcrun swift` 脚本模式会卡死，用 `xcrun swiftc` 编成二进制跑。
- 中文字体 `/System/Library/Fonts/STHeiti Medium.ttc`（**`PingFang.ttc` 不存在**）。
- ⚠️ **shell 里的 `grep` 在本机会假阴性**（同一个文件明明有内容却返回空，2026-11-03 连栽两次）。
  查代码一律用 Grep 工具，别用 bash grep。

## 构建

- ⚠️ **改完一律跑 `scripts/build-app.sh debug`，别用 `cp` 换二进制**（破签名 → SIGKILL 137）。
- 连跑会撞 SwiftPM 锁；判据看**退出码 + `codesign -v build/Clothespeg.app`**，别信 tail 最后一行。
- ⚠️ **`.strings` 重复键静默后胜，`plutil -lint` 不报**（已栽两次）→ 改完跑
  `scripts/check-strings.swift`。（它只报 unused，**不报 duplicate**，别指望它查这个。）

## 日志

- `~/Library/Application Support/Clothespeg/logs/Clothespeg.log`（1 MB 转 `Clothespeg.old.log`）。
  ⚠️ 注意中间还有一级 `logs/`，直接拼 `…/Clothespeg/Clothespeg.log` 会找不到。
- 读取要在 `dangerouslyDisableSandbox` 下做，否则沙盒把 `~/Library/Application Support` 读成「不存在」，
  报的是 `No such file` 而不是权限错 —— 很容易被当成「日志没写」。
- 自检产物：`CLOTHESPEG_CAPTURE_SELFTEST=/tmp/capture.txt build/Clothespeg.app/Contents/MacOS/Clothespeg`。

## 排查「改动没生效」

顺序：**二进制时间戳**（`stat -f %Sm`）→ **源码 mtime 比二进制新就是没构建**（2026-11-03 就撞过：
`CaptureOverlay.swift` 09:43 落盘，二进制 09:42，用户测的是中间态）→ `strings` 找新标记 →
最后 `pkill -x Clothespeg; open build/Clothespeg.app`（`ps` / `pgrep` 在本机常无权限）。
