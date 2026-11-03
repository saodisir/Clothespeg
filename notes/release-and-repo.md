# 发布、签名、仓库 —— 操作配方

> 从 `.workbuddy/memory/MEMORY.md` 外置而来（该文件有 10000 字符注入上限，2026-11-02 超限被截）。
> MEMORY.md 只留一条命令 + 判据 + 指向本文件的索引。

## 主页与下载

- 主页 https://clothespeg.pages.dev（CF Pages 项目名必须 `clothespeg`）。`./scripts/deploy_site.sh`。
- **推 GitHub ≠ 发布**，两件事分开做。
- 备用下载走 R2（bucket `clothespeg-dl`）：`https://pub-070a6d9e2e7d442bafe01c46def094b2.r2.dev/Clothespeg-latest.dmg`。
- `scripts/upload_dl.sh` 传 4 个对象：版本存档 + 其 `.sha256` + `latest` 覆盖副本 + 其 `.sha256`。
- **固定 latest 键 → 发版不用碰 HTML**（无 Sparkle）。
- 凭据 `~/.config/clothespeg/r2.env`（600，不入库）：`CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID`（`f94f3d5633286eed3ba2ffe6c125e512`）+ `CLOTHESPEG_DL_BASE`。
- wrangler 的 OAuth token 已过期无 scope，别依赖。
- ⚠️ `source` 纯赋值文件只有 shell 变量 → `set -a; source …; set +a`；zsh 不做词分割 → `${=WRANGLER_CMD}`。
- ⚠️ 沙箱里 `npx` 装不了包，改用缓存里的 wrangler（`~/.npm/_npx/32026684e21afda6/node_modules/.bin/wrangler`），靠 `WRANGLER=` 覆盖。curl 直连 CF API 通。
- 判据：看**退出码**不看 "Upload complete"；自检走**公共域名 curl** → 比 sha256 + 字节数 + `stapler validate`。
- r2.dev 非生产用途、有限流；绑自定义域名要备案，暂不做。

## 发版签名

- 证书 `Developer ID Application: VIZWISE (HONGKONG) LIMITED (HBNFTQP2TP)`，Team `HBNFTQP2TP`。
- **脚本不写死证书名**，发版显式传参：

```bash
SIGN_IDENTITY='Developer ID Application: VIZWISE (HONGKONG) LIMITED (HBNFTQP2TP)' \
RELEASE_TEAM=HBNFTQP2TP \
scripts/build-app.sh release && scripts/make-dmg.sh
```

- 两脚本必须同一张证书；传了 SIGN_IDENTITY 钥匙串没有 → 报错停。
- 公证能跑（v1.10.0 起 Accepted + staple），`make-dmg.sh` 自带 notarytool 与 staple，需 dangerouslyDisableSandbox。
- 被拦时绕法：`hdiutil create -srcfolder STAGE -fs HFS+ -format UDZO` + 单独 codesign。

## GitHub 仓库

- `saodisir/Clothespeg`（注意大小写）。main 是零父真根，全走主干；旧历史只在本地 note-cards / backup 分支 + `.workbuddy/backups/*.bundle`。
- **push 先试 `git -c http.version=HTTP/1.1 push`**，失败再走 API。
- 凭据：`printf "protocol=https\nhost=github.com\n\n" | git credential-osxkeychain get`；token 单字段要 `awk -F= '/^password=/{print $2}'`；沙箱内读钥匙串不稳，用 dangerouslyDisableSandbox。本机无 gh CLI。
- API 配方（模板 `/tmp/gh_release_180.py`）：
  1. 拉 tree 全量 blob sha 对比本地（**自动得改动集，勿手列**）
  2. POST blobs
  3. POST trees 带 `base_tree`（**未列路径是被继承不是删除**；mode 沿用远端）
  4. commit → ref(force=false) → tag → release
  5. asset 直传（`application/octet-stream`，**不要 multipart**）
  6. 逐 blob + DMG 回验
- 进仓库：.github / LICENSE / Package.swift / 两 README / Sources / scripts（不含 deploy_site.sh）/ website。
- 不进仓库：docs/ notes/ build/ .workbuddy/。推前逐路径 add 并查暂存清单。
- 线上 release：v1.11.0 最新 + v1.10.0 + v1.9.2 + v1.9.1 + v1.9.0 + v1.8.0 + v1.7.0 + v1.6.0，不删旧。1.9.3 从未发布。
- 版本策略：用户可见新功能 → minor；CFBundleVersion 递增。

## 许可证（双协议并存，别搞反）

- Tendedero 是 MIT 且永远 MIT；fork 新增部分 Apache-2.0（MIT 可并入 Apache，这是法律依据）。
- `LICENSE` = Apache 全文 + Provenance；`LICENSE-MIT` = 上游原样（**不是**「旧版是 MIT」）；`NOTICE` = provenance + 划分。
- 七处同时提两协议：LICENSE-MIT / LICENSE / NOTICE / 两 README / `SettingsSupport.swift`（`LicenceText.full`）/ website/licence.html。授权方 = VIZWISE (HONGKONG) LIMITED。
- ⚠️ Apache 全文三副本会漂移（已漂 3 次）；改协议要三处并排比。
- Swift `"""` 缩进：每行 lstrip 后加 4 空格。
- 删「过时标注」前先分清**过去的状态** vs **持续的事实**。
