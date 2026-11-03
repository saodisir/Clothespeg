#!/bin/zsh
# 把 DMG 传到 Cloudflare R2 备用下载源（bucket: clothespeg-dl）
#
# ── 为什么要有这条路 ──
# GitHub 在国内时通时不通，而**下不到包**是最伤的失败方式。R2 的出网流量
# 永久免费（不限量、不计费），是理想的兜底分发通道。免费额度：存储 10 GB·月 /
# Class A 写 100 万次 / Class B 读 1000 万次每月 —— 4 MB 的包能放两千多个版本。
#
# ── 跟 Flyring 那边的差别（有意为之）──
# Flyring 首页把版本号写进 JS 常量，每次发版要改 HTML。这里改成**固定对象键**：
#   Clothespeg-latest.dmg  ← 首页「备用下载」永远指这个，发版时覆盖
# 于是发版只需跑本脚本，index.html 一次都不用碰。Clothespeg 没有 Sparkle，
# 用户全靠手动下载，靠人记着改版本号迟早漏。
#
# ── 用法 ──
#   ./scripts/upload_dl.sh                      # 传 build/ 下版本号最高的那个
#   ./scripts/upload_dl.sh Clothespeg-1.11.0.dmg
#
# ── 凭据 ──
# 读 $HOME/.config/clothespeg/r2.env（chmod 600，不入库），需要两项：
#   CLOUDFLARE_API_TOKEN   权限：Account > R2 Storage > Edit
#   CLOUDFLARE_ACCOUNT_ID
# 可选 CLOTHESPEG_DL_BASE = 控制台 R2 > clothespeg-dl > Public access 里的
#   pub-<随机>.r2.dev 域名。设了才会走「用户真实路径」自检（推荐设）。
#
# ── 传四个对象 ──
#   Clothespeg-<ver>.dmg          版本存档（可回退、能给老版本做支持）
#   Clothespeg-<ver>.dmg.sha256
#   Clothespeg-latest.dmg         首页按钮指向它，每次覆盖
#   Clothespeg-latest.dmg.sha256

set -euo pipefail
cd "$(dirname "$0")/.."

BUCKET=clothespeg-dl
BUILD=build
WRANGLER=${WRANGLER:-"npx --yes wrangler"}

ENVFILE="$HOME/.config/clothespeg/r2.env"
if [[ -f "$ENVFILE" ]]; then
  # ⚠️ 必须 set -a 再 source：source 一个纯 `KEY=value` 文件只会得到 **shell 变量**，
  #    不会进环境。wrangler 是子进程，看不到 → 报 "In a non-interactive environment,
  #    it's necessary to set a CLOUDFLARE_API_TOKEN"（2026-10-30 实际踩到）。
  set -a
  # shellcheck disable=SC1090
  source "$ENVFILE"
  set +a
fi
if [[ -z "${CLOUDFLARE_API_TOKEN:-}" || -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
  echo "✗ 缺凭据：需要在 $ENVFILE 里给 CLOUDFLARE_API_TOKEN 和 CLOUDFLARE_ACCOUNT_ID" >&2
  echo "  （Token 权限：Account → R2 Storage → Edit）" >&2
  exit 1
fi

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
  # ⚠️ build/ 下还有 .app 和别的杂项，只认 Clothespeg-<数字>.dmg；
  #    sort -V 按版本号排，sort 会把它排成 1.9.10 < 1.11.0，普通字典序会排反。
  NAME=$(ls -1 "$BUILD"/Clothespeg-*.dmg 2>/dev/null | grep -E 'Clothespeg-[0-9.]+\.dmg$' | sort -V | tail -1 | xargs -n1 basename)
fi

if [[ -z "$NAME" || ! -f "$BUILD/$NAME" ]]; then
  echo "✗ 找不到要上传的 DMG（找的是 ${BUILD}/${NAME:-*}）" >&2
  echo "  先跑 build-app.sh release && make-dmg.sh 出包。" >&2
  exit 1
fi

DMG="$BUILD/$NAME"
SIZE=$(stat -f%z "$DMG")
VER="${NAME#Clothespeg-}"; VER="${VER%.dmg}"

echo "== R2 上传 =="
echo "  bucket : $BUCKET"
echo "  文件   : ${NAME}（${SIZE} 字节，版本 ${VER}）"
echo

# 版本存档的校验文件跟包放一起（留在 build/，方便本地复查）。
# ⚠️ shasum 输出是 "<hash>  <path>"，path 会带 build/ 前缀，下载者按它对不上，
#    所以重算一遍只留文件名。
( cd "$BUILD" && shasum -a 256 "$NAME" > "$NAME.sha256" )
LOCAL_SHA=$(cut -d' ' -f1 < "$DMG.sha256")
echo "  哈希     : $LOCAL_SHA"
echo

# latest 副本放临时目录，不污染 build/（那里只该有真正的构建产物）。
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
cp "$DMG" "$TMPD/Clothespeg-latest.dmg"
( cd "$TMPD" && shasum -a 256 Clothespeg-latest.dmg > Clothespeg-latest.dmg.sha256 )

put() {
  local key=$1 file=$2 log
  log=$(mktemp)
  # ⚠️ 判据用**退出码**，不 grep "Upload complete" —— wrangler 的完成文案随版本改
  #    （有时 "Upload complete."、有时带进度条），靠字符串匹配会静默误判成失败。
  echo -n "  ↑ ${key} … "
  if $WRANGLER r2 object put "${BUCKET}/${key}" --file "$file" --remote > "$log" 2>&1; then
    echo "ok"
    rm -f "$log"
  else
    echo "失败"
    tail -5 "$log" >&2
    rm -f "$log"
    return 1
  fi
}

# 不做「已存在就跳过」：Class A 写免费额度 100 万次/月，一次发版只写 4 次，
# 判断存在性的成本比直接覆盖高，而且 latest 键**必须**每次覆盖，跳过是错的。
put "$NAME"                          "$DMG"
put "$NAME.sha256"                   "$DMG.sha256"
put "Clothespeg-latest.dmg"          "$TMPD/Clothespeg-latest.dmg"
put "Clothespeg-latest.dmg.sha256"   "$TMPD/Clothespeg-latest.dmg.sha256"
echo

# ── 自检：必须走用户真实会走的路径 ──
# 只验「wrangler 读回来的字节对」是不够的 —— 那证明不了 Public access 开着。
# 能下载到才叫能下载。
verify() {
  local key=$1 label=$2
  local tmp
  # ⚠️ 临时文件带 .dmg 后缀：xcrun stapler 靠扩展名判断类型，无后缀会报
  #    "validate action failed"，看着像包坏了，其实只是认不出。
  if [[ "$key" == *.dmg ]]; then tmp="$(mktemp -t clothespeg-dl-verify).dmg"; else tmp=$(mktemp -t clothespeg-dl-verify); fi
  if [[ -n "${CLOTHESPEG_DL_BASE:-}" ]]; then
    local code
    code=$(curl -sL --max-time 120 -o "$tmp" -w "%{http_code}" "${CLOTHESPEG_DL_BASE}/${key}" || echo 000)
    if [[ "$code" != "200" ]]; then
      echo "✗ ${label}：HTTP $code（${CLOTHESPEG_DL_BASE}/${key}）" >&2
      rm -f "$tmp"; return 1
    fi
  else
    $WRANGLER r2 object get "${BUCKET}/${key}" --file "$tmp" --remote >/dev/null 2>&1
  fi
  local got_size got_sha
  got_size=$(stat -f%z "$tmp")
  got_sha=$(shasum -a 256 "$tmp" | cut -d' ' -f1)
  rm -f "$tmp"
  if [[ "$got_sha" != "$LOCAL_SHA" || "$got_size" != "$SIZE" ]]; then
    echo "✗ ${label}：取回的不一致（${got_size} 字节 / ${got_sha:0:16}…）" >&2
    return 1
  fi
  echo "✓ ${label}：${got_size} 字节，逐字节一致"
}

if [[ -n "${CLOTHESPEG_DL_BASE:-}" ]]; then
  echo "== 自检（走公共域名，等价于用户下载）=="
else
  echo "== 自检（直连 R2 —— CLOTHESPEG_DL_BASE 未设，无法验证公共访问是否生效）=="
fi
verify "$NAME" "${NAME}"
verify "Clothespeg-latest.dmg" "Clothespeg-latest.dmg"

# 钉章在往返后还在吗？上传/下载不改字节，理论上不会丢，但值得每次确认。
TMP2="$(mktemp -t clothespeg-staple).dmg"
if [[ -n "${CLOTHESPEG_DL_BASE:-}" ]]; then
  curl -sL --max-time 120 -o "$TMP2" "${CLOTHESPEG_DL_BASE}/Clothespeg-latest.dmg"
else
  $WRANGLER r2 object get "${BUCKET}/Clothespeg-latest.dmg" --file "$TMP2" --remote >/dev/null 2>&1
fi
if xcrun stapler validate "$TMP2" >/dev/null 2>&1; then
  echo "✓ 公证钉章在取回的包上仍然有效"
else
  echo "⚠️ 取回的包 stapler validate 失败 —— 值得看一眼（原包若本来没公证，这条会失败）" >&2
fi
rm -f "$TMP2"

echo
if [[ -n "${CLOTHESPEG_DL_BASE:-}" ]]; then
  echo "  下载地址："
  echo "    ${CLOTHESPEG_DL_BASE}/Clothespeg-latest.dmg"
  echo "    ${CLOTHESPEG_DL_BASE}/Clothespeg-latest.dmg.sha256"
else
  echo "  下一步：把 R2 公共域名写进 $ENVFILE 再跑一次，才会打印下载地址并做公共访问自检："
  echo "    CLOTHESPEG_DL_BASE=https://pub-xxxx.r2.dev"
  echo "  （域名在 Dashboard > R2 > ${BUCKET} > Public access 里看，不要手猜）"
fi
