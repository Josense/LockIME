#!/usr/bin/env bash
#
# LockIME 发布脚本
#
#   源码 ──► 编译 ──► 组装 .app ──► 签名 ──► 公证 ──► staple
#          └──► 制作 .dmg ──► 签名 ──► 公证 ──► staple ──► 校验
#
# 关键点：app 与 dmg 是两个独立对象，各自公证 + 各自 staple。
#         app 必须在制作 dmg **之前** 完成 staple，否则 dmg 内容会变化导致签名失效。
#
# 用法:
#   ./release.sh                  # 完整流程
#   ./release.sh --build-only     # 只编译 + 组装 + 签名（不联网公证）
#   ./release.sh --no-notarize    # 完整打包（含 dmg）但不公证，用于本地验证流程
#   ./release.sh --skip-build     # 复用已有 build/LockIME.app，从公证开始
#   ./release.sh --no-dmg         # 只发布 .app，不制作 dmg
#
# 可覆盖的环境变量:
#   VERSION=1.0.1   SIGN_ID="Developer ID Application: ..."   KEYCHAIN_PROFILE=AC_PASSWORD
#   NOTARY_LABEL=...  ARCH=arm64  DMG_LAYOUT=0
#
set -euo pipefail

# ─────────────────────────── 配置 ───────────────────────────
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP_NAME="LockIME"
VOL_NAME="LockIME"
SRC_FILES=(main.swift AppDelegate.swift LockController.swift InputSourceManager.swift)
RESOURCE_DIR="Resources"
ICON_FILE="AppIcon.icns"
SRC_PLIST="$ROOT/Info.plist"          # 唯一权威的 Info.plist

BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
STAGE="$BUILD_DIR/dmg-staging"
RW_DMG="$BUILD_DIR/$APP_NAME-rw.dmg"

VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$SRC_PLIST" 2>/dev/null || echo "1.0.0")}"
DMG="$ROOT/$APP_NAME-$VERSION.dmg"

# 未显式指定时，自动挑选钥匙串里的 Developer ID Application 证书
if [[ -z "${SIGN_ID:-}" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-AC_PASSWORD}"
NOTARY_LABEL="${NOTARY_LABEL:-$APP_NAME-$VERSION}"
ARCH="${ARCH:-$(uname -m)}"
DMG_LAYOUT="${DMG_LAYOUT:-1}"

# ─────────────────────────── 参数 ───────────────────────────
BUILD=1 NOTARIZE=1 MAKE_DMG=1
for arg in "$@"; do
  case "$arg" in
    --build-only) NOTARIZE=0; MAKE_DMG=0 ;;
    --no-notarize) NOTARIZE=0 ;;
    --skip-build) BUILD=0 ;;
    --no-dmg)     MAKE_DMG=0 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

# ─────────────────────────── 输出 ───────────────────────────
if [[ -t 1 ]]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
step() { printf "\n%s==> %s%s\n" "$B" "$*" "$N"; }
info() { printf "    %s\n" "$*"; }
ok()   { printf "    %s✓ %s%s\n" "$G" "$*" "$N"; }
warn() { printf "    %s! %s%s\n" "$Y" "$*" "$N" >&2; }
die()  { printf "\n%s✗ %s%s\n" "$R" "$*" "$N" >&2; exit 1; }

MOUNT_POINT=""
cleanup() {
  local rc=$?
  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null \
      || hdiutil detach "$MOUNT_POINT" -force -quiet 2>/dev/null || true
    MOUNT_POINT=""
  fi
  [[ $rc -eq 0 ]] || printf "\n%s✗ 发布失败 (exit %s)%s\n" "$R" "$rc" "$N" >&2
  exit $rc
}
trap cleanup EXIT

# 带超时执行（macOS 无 GNU timeout，用 perl alarm 兜底）
run_timeout() { local t=$1; shift; perl -e 'alarm shift; exec @ARGV' "$t" "$@"; }

# 签名并在时间戳服务抖动时自动重试
sign() {  # sign <target> [extra codesign args...]
  local target="$1"; shift
  local i out rc
  for i in 1 2 3 4 5; do
    set +e
    out="$(codesign --force --timestamp --sign "$SIGN_ID" "$@" "$target" 2>&1)"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/    /'
      return 0
    fi
    warn "签名失败（第 $i/5 次，常见于时间戳服务抖动），2s 后重试…"
    sleep 2
  done
  printf '%s\n' "$out" | sed 's/^/    /' >&2
  return 1
}

# ─────────────────────────── 前置检查 ───────────────────────────
step "环境检查"
[[ -n "$SIGN_ID" ]] || die "找不到 Developer ID Application 证书，请用 SIGN_ID=... 指定"
info "版本      : $VERSION"
info "签名身份  : $SIGN_ID"
info "公证 profile: $KEYCHAIN_PROFILE"
info "架构      : $ARCH"
for f in "${SRC_FILES[@]}"; do
  [[ -f "$ROOT/$f" ]] || die "缺少源文件: $f"
done
[[ -f "$SRC_PLIST" ]] || die "缺少 Info.plist"
[[ -d "$ROOT/$RESOURCE_DIR" ]] || die "缺少 $RESOURCE_DIR/ 目录"
ok "环境就绪"

# 提前验证公证凭据，避免编译半天才发现密码错
if [[ $NOTARIZE -eq 1 ]]; then
  step "验证公证凭据"
  if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    die "钥匙串 profile '$KEYCHAIN_PROFILE' 不可用。
    先创建：xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\" \\
              --apple-id <你的 Apple ID> --team-id <TEAMID> --password <App 专用密码>"
  fi
  ok "公证凭据可用"
fi

# ─────────────────────────── 1. 编译 ───────────────────────────
if [[ $BUILD -eq 1 ]]; then
  step "编译 (swiftc -O)"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  BIN="$BUILD_DIR/$APP_NAME"
  swiftc -O -target "$ARCH-apple-macos13.0" -o "$BIN" "${SRC_FILES[@]}"
  ok "编译完成: $(file -b "$BIN" | cut -d, -f1-2)"
else
  step "跳过编译（--skip-build）"
  [[ -f "$APP/Contents/MacOS/$APP_NAME" ]] || die "build/$APP_NAME.app 不存在，无法跳过编译"
  ok "复用已有 $APP"
fi

# ─────────────────────────── 2. 组装 .app ───────────────────────────
if [[ $BUILD -eq 1 ]]; then
  step "组装 .app bundle"
  BIN="$BUILD_DIR/$APP_NAME"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
  cp "$SRC_PLIST" "$APP/Contents/Info.plist"
  # 资源（.icns / png），排除 .DS_Store
  while IFS= read -r -d '' res; do
    cp "$res" "$APP/Contents/Resources/"
  done < <(find "$ROOT/$RESOURCE_DIR" -maxdepth 1 -type f ! -name '.DS_Store' -print0)
  ok "bundle 已组装"
  find "$APP" -type f | sed "s|$APP|    .|"
fi

# ─────────────────────────── 3. 签名 .app ───────────────────────────
step "签名 .app"
sign "$APP" --options runtime --identifier "com.open.lockime"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
ok "签名校验通过"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier|Timestamp' | sed 's/^/    /' || true

SPCTL_OUT="$(spctl -a -vvv -t exec "$APP" 2>&1)" || true
printf '%s\n' "$SPCTL_OUT" | sed 's/^/    /'
if grep -q 'accepted' <<<"$SPCTL_OUT"; then
  ok "Gatekeeper: 已公证"
else
  warn "Gatekeeper 暂未通过（公证前属于正常，继续）"
fi

# ─────────────────────────── 4. 公证 + staple .app ───────────────────────────
if [[ $NOTARIZE -eq 1 ]]; then
  step "公证 .app（上传 zip 给 Apple）"
  APP_ZIP="$BUILD_DIR/$APP_NAME-$VERSION-app.zip"
  rm -f "$APP_ZIP"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  info "上传中，通常 1–5 分钟…"

  set +e
  SUBMIT_OUT="$(xcrun notarytool submit "$APP_ZIP" \
      --keychain-profile "$KEYCHAIN_PROFILE" --wait 2>&1)"
  SUBMIT_RC=$?
  set -e
  printf '%s\n' "$SUBMIT_OUT" | sed 's/^/    /'

  APP_SUB_ID="$(printf '%s\n' "$SUBMIT_OUT" | awk '/^ *id: /{print $2; exit}')"
  if [[ $SUBMIT_RC -ne 0 ]] || ! printf '%s\n' "$SUBMIT_OUT" | grep -q 'status: Accepted'; then
    [[ -n "$APP_SUB_ID" ]] && xcrun notarytool log "$APP_SUB_ID" \
      --keychain-profile "$KEYCHAIN_PROFILE" 2>&1 | sed 's/^/    /' || true
    die "app 公证未通过"
  fi
  ok "app 公证通过 (id: $APP_SUB_ID)"

  step "staple 到 .app"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP" 2>&1 | sed 's/^/    /'
  codesign -dv --verbose=2 "$APP" 2>&1 | grep -i 'notarization' | sed 's/^/    /' || true
  ok "app 已装订票据（离线可用）"

  # 装订后签名依然要合法
  codesign --verify --deep --strict "$APP"
  ok "staple 后签名仍有效"
else
  step "跳过公证（未开启公证）"
fi

# ─────────────────────────── 5. 制作 .dmg ───────────────────────────
if [[ $MAKE_DMG -eq 1 ]]; then
  step "制作 .dmg"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  rm -f "$DMG" "$RW_DMG"
  # ditto 保留扩展属性，确保 app 的 staple 票据原样带入
  ditto "$APP" "$STAGE/$APP_NAME.app"
  ln -s /Applications "$STAGE/Applications"

  # 先卸掉同名旧卷，避免新卷被命名为 "LockIME 1" 导致后续 AppleScript 指错卷
  while IFS= read -r stale; do
    [[ -n "$stale" ]] && hdiutil detach "$stale" -force -quiet 2>/dev/null || true
  done < <(ls -d /Volumes/"$VOL_NAME" 2>/dev/null; ls -d /Volumes/"$VOL_NAME"[\ ]* 2>/dev/null || true)

  # 先做可读写镜像 → 设置卷图标/布局 → 再压缩成只读 UDZO
  hdiutil create -srcfolder "$STAGE" -volname "$VOL_NAME" \
    -fs HFS+ -format UDRW -ov "$RW_DMG" -quiet

  MOUNT_POINT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" \
    | awk -F'\t' '/\/Volumes\//{print $NF; exit}')"
  [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]] || die "无法挂载临时 dmg"
  ACTUAL_VOL="$(basename "$MOUNT_POINT")"
  info "已挂载到: $MOUNT_POINT"

  # 卷图标：必须在 Finder 布局之后设置，否则 Finder 重写 .DS_Store 时会删掉 .VolumeIcon.icns
  set_volume_icon() {
    [[ -f "$ROOT/$RESOURCE_DIR/$ICON_FILE" ]] || return 0
    cp "$ROOT/$RESOURCE_DIR/$ICON_FILE" "$MOUNT_POINT/.VolumeIcon.icns"
    if xcrun --find SetFile >/dev/null 2>&1; then
      xcrun SetFile -a C "$MOUNT_POINT" && ok "已设置卷图标"
    else
      warn "未找到 SetFile，跳过卷图标（需要 Xcode 命令行工具）"
    fi
  }

  # Finder 窗口布局（失败不影响发布）
  if [[ "$DMG_LAYOUT" == "1" ]]; then
    if run_timeout 30 osascript >/dev/null 2>&1 <<OSA; then
tell application "Finder"
  tell disk "$ACTUAL_VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 160, 800, 560}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set position of item "$APP_NAME.app" of container window to {150, 200}
    set position of item "Applications" of container window to {450, 200}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
      ok "已设置 dmg 窗口布局"
    else
      warn "Finder 布局设置未生效（无 GUI 会话或未授权自动化），跳过"
    fi
  fi

  # 布局完成后再贴卷图标
  set_volume_icon

  # 清掉挂载过程产生的系统垃圾（保留 .DS_Store，它保存 Finder 布局）
  rm -rf "$MOUNT_POINT/.fseventsd" "$MOUNT_POINT/.Trashes" 2>/dev/null || true
  sync
  hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null \
    || hdiutil detach "$MOUNT_POINT" -force -quiet
  MOUNT_POINT=""

  hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
  rm -f "$RW_DMG"
  ok "已生成 $(basename "$DMG") ($(du -h "$DMG" | cut -f1))"

  # ── 6. 签名 dmg ──
  step "签名 .dmg"
  sign "$DMG"
  codesign --verify --verbose=2 "$DMG" 2>&1 | sed 's/^/    /'
  ok "dmg 签名校验通过"
fi

# ─────────────────────────── 7. 公证 + staple .dmg ───────────────────────────
if [[ $NOTARIZE -eq 1 && $MAKE_DMG -eq 1 ]]; then
  step "公证 .dmg"
  info "上传中，通常 1–5 分钟…"
  set +e
  SUBMIT_OUT="$(xcrun notarytool submit "$DMG" \
      --keychain-profile "$KEYCHAIN_PROFILE" --wait 2>&1)"
  SUBMIT_RC=$?
  set -e
  printf '%s\n' "$SUBMIT_OUT" | sed 's/^/    /'

  DMG_SUB_ID="$(printf '%s\n' "$SUBMIT_OUT" | awk '/^ *id: /{print $2; exit}')"
  if [[ $SUBMIT_RC -ne 0 ]] || ! printf '%s\n' "$SUBMIT_OUT" | grep -q 'status: Accepted'; then
    [[ -n "$DMG_SUB_ID" ]] && xcrun notarytool log "$DMG_SUB_ID" \
      --keychain-profile "$KEYCHAIN_PROFILE" 2>&1 | sed 's/^/    /' || true
    die "dmg 公证未通过"
  fi
  ok "dmg 公证通过 (id: $DMG_SUB_ID)"

  step "staple 到 .dmg"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG" 2>&1 | sed 's/^/    /'
  ok "dmg 已装订票据（离线可用）"
fi

# ─────────────────────────── 8. 最终校验 ───────────────────────────
step "最终校验（模拟用户机器）"
FAIL=0
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else warn "未通过: $1"; FAIL=1; fi; }

check "app 签名有效"          "codesign --verify --deep --strict '$APP'"
if [[ $NOTARIZE -eq 1 ]]; then
  check "app 已 staple"       "xcrun stapler validate '$APP'"
  check "app Gatekeeper 通过" "spctl -a -t exec '$APP'"
fi
if [[ $MAKE_DMG -eq 1 ]]; then
  check "dmg 签名有效"        "codesign --verify '$DMG'"
  if [[ $NOTARIZE -eq 1 ]]; then
    check "dmg 已 staple"     "xcrun stapler validate '$DMG'"
    check "dmg Gatekeeper 通过" "spctl -a -t open --context context:primary-signature '$DMG'"
    # 挂载 dmg，确认里面的 app 也带票据
    MP="$(hdiutil attach "$DMG" -nobrowse -readonly | awk -F'\t' '/\/Volumes\//{print $NF; exit}')"
    if [[ -n "$MP" ]]; then
      check "dmg 内 app 已 staple"  "xcrun stapler validate '$MP/$APP_NAME.app'"
      check "dmg 内 app Gatekeeper" "spctl -a -t exec '$MP/$APP_NAME.app'"
      check "dmg 卷图标存在"        "test -f '$MP/.VolumeIcon.icns'"
      hdiutil detach "$MP" -quiet 2>/dev/null || hdiutil detach "$MP" -force -quiet
    fi
  fi
fi

printf "\n%s────────────────────────────────────────%s\n" "$B" "$N"
if [[ $FAIL -eq 0 ]]; then
  if [[ $NOTARIZE -eq 0 ]]; then
    printf "%s✓ 编译/组装/打包/签名完成（未公证）%s\n" "$G" "$N"
  else
    printf "%s✓ 发布完成%s\n" "$G" "$N"
  fi
  [[ $MAKE_DMG -eq 1 ]] && printf "  产物: %s\n" "$DMG"
  printf "  可分发: %s\n" "$APP"
else
  printf "%s! 发布完成，但有校验项未通过（见上）%s\n" "$Y" "$N"
  exit 1
fi
