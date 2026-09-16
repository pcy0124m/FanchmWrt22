#!/usr/bin/env bash
# =============================================================================
#  FanchmWrt for JDCloud RE-SP-01B（京东云无线宝一代 / MT7621）构建脚本
#
#  适用于：Ubuntu 22.04 / 24.04（物理机、虚拟机、WSL2、GitHub Actions 均可）
#  产出：openwrt-ramips-mt7621-jdcloud_re-sp-01b-squashfs-sysupgrade.bin 等
#
#  用法：
#    ./scripts/build.sh --profile minimal          # 精简版（推荐）
#    ./scripts/build.sh --profile full             # 全功能版（可能超 27MB）
#    ./scripts/build.sh --no-mirror                # 海外网络，不换 GitHub 镜像
#    ./scripts/build.sh --skip-deps --profile minimal   # 依赖已装好
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_URL="${REPO_URL:-https://github.com/fanchmwrt/fanchmwrt.git}"
REPO_BRANCH="${REPO_BRANCH:-fanchmwrt-25.12.4}"
SRC_DIR="${SRC_DIR:-$ROOT_DIR/fanchmwrt}"
PROFILE="${PROFILE:-minimal}"
JOBS="${JOBS:-$(nproc)}"
USE_MIRROR="${USE_MIRROR:-1}"
SKIP_DEPS="${SKIP_DEPS:-0}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
DEVICE_NAME="jdcloud_re-sp-01b"

log()  { printf '\033[1;32m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)      PROFILE="${2:?缺少参数}"; shift 2 ;;
    --src-dir)      SRC_DIR="$2"; shift 2 ;;
    --out-dir)      OUT_DIR="$2"; shift 2 ;;
    --jobs)         JOBS="$2"; shift 2 ;;
    --mirror)       USE_MIRROR=1; shift ;;
    --no-mirror)    USE_MIRROR=0; shift ;;
    --skip-deps)    SKIP_DEPS=1; shift ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *)              die "未知参数: $1" ;;
  esac
done

CONFIG_SEED="$ROOT_DIR/config/re-sp-01b-${PROFILE}.seed"
[[ -f "$CONFIG_SEED" ]] || die "找不到配置文件: $CONFIG_SEED（可选值: minimal / full）"

# -----------------------------------------------------------------------------
# 1. 编译依赖
# -----------------------------------------------------------------------------
install_deps() {
  [[ "$SKIP_DEPS" == "1" ]] && { log "跳过依赖安装"; return; }
  command -v apt-get >/dev/null 2>&1 || { warn "非 Debian 系系统，请自行安装编译依赖"; return; }
  log "安装编译依赖（需要 sudo）"
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -qq
  # 必需项：失败即停
  sudo apt-get install -y --no-install-recommends \
    build-essential clang flex bison g++ gawk gcc-multilib g++-multilib gettext git \
    libncurses-dev libssl-dev libelf-dev libtool-bin libtool autoconf automake \
    patch pkgconf make cmake ninja-build ccache curl wget file unzip bzip2 xz-utils \
    zlib1g-dev python3 python3-pip python3-setuptools python3-pyelftools \
    device-tree-compiler rsync swig
  # 可选项：个别发行版没有也无所谓
  sudo apt-get install -y --no-install-recommends \
    squashfs-tools zstd p7zip-full subversion gperf help2man intltool texinfo \
    || warn "部分可选依赖未安装，通常不影响编译"
  sudo apt-get clean
}

# -----------------------------------------------------------------------------
# 2. 拉取 FanchmWrt 源码
# -----------------------------------------------------------------------------
fetch_source() {
  if [[ -d "$SRC_DIR/.git" ]]; then
    log "源码已存在: $SRC_DIR（跳过 clone）"
  else
    log "克隆 FanchmWrt 分支 $REPO_BRANCH → $SRC_DIR"
    git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$SRC_DIR"
  fi

  # 确认上游确实支持本机型（25.12.4 起自带 DTS + 镜像定义）
  grep -q "define Device/${DEVICE_NAME}" \
    "$SRC_DIR/target/linux/ramips/image/mt7621.mk" \
    || die "上游未找到 Device/${DEVICE_NAME}，请检查分支是否正确"
  [[ -f "$SRC_DIR/target/linux/ramips/dts/mt7621_${DEVICE_NAME}.dts" ]] \
    || die "上游未找到 mt7621_${DEVICE_NAME}.dts"

  if [[ "$USE_MIRROR" == "1" && -f "$SRC_DIR/feeds.conf.default" ]]; then
    log "将 feeds 源切换到 GitHub 镜像（国内网络更稳，commit hash 保持一致）"
    cp "$SRC_DIR/feeds.conf.default" "$SRC_DIR/feeds.conf.default.bak"
    sed -i \
      -e 's#https://git.openwrt.org/feed/#https://github.com/openwrt/#g' \
      -e 's#https://git.openwrt.org/project/luci.git#https://github.com/openwrt/luci.git#g' \
      "$SRC_DIR/feeds.conf.default"
  fi

  # 追加第三方 feed：iStore 应用商店 + 网页文件管理器（非 FanchmWrt 官方）
  # 重复执行（如本地二次编译）时避免重复追加
  if ! grep -q "src-git istore" "$SRC_DIR/feeds.conf.default"; then
    log "追加第三方 feed（istore / filemanager）"
    cat >> "$SRC_DIR/feeds.conf.default" <<'EOF'

# 第三方：iStore 应用商店 与 网页文件管理器（编译失败可整段注释掉）
src-git istore https://github.com/linkease/istore.git
src-git filemanager https://github.com/sirpdboy/luci-app-filemanager.git
EOF
  fi
}

# -----------------------------------------------------------------------------
# 3. feeds + 配置 + 自定义文件
# -----------------------------------------------------------------------------
prepare_tree() {
  cd "$SRC_DIR"
  log "更新 feeds"
  ./scripts/feeds update -a
  ./scripts/feeds install -a

  log "写入配置: $CONFIG_SEED"
  cp "$CONFIG_SEED" "$SRC_DIR/.config"
  make defconfig >/dev/null

  if [[ -d "$ROOT_DIR/files" ]]; then
    log "注入自定义文件（files/ → 镜像 /）"
    mkdir -p "$SRC_DIR/files"
    cp -a "$ROOT_DIR/files/." "$SRC_DIR/files/"
  fi
}

# -----------------------------------------------------------------------------
# 4. 编译
# -----------------------------------------------------------------------------
build() {
  cd "$SRC_DIR"
  # 复用 CI 缓存的下载目录（避免重复拉取源码包）
  export DL_DIR="${ROOT_DIR}/fanchmwrt-dl"
  mkdir -p "$DL_DIR"
  log "预下载源码包（make download）"
  make download -j"$JOBS" V=s || warn "部分源码包下载失败，继续尝试编译"

  log "开始编译（-j$JOBS，首次约 1.5~3 小时）"
  if ! make -j"$JOBS" ; then
    warn "并行编译失败，改用单线程重跑以定位错误"
    make -j1 V=s
  fi
}

# -----------------------------------------------------------------------------
# 5. 收集产物
# -----------------------------------------------------------------------------
collect() {
  local img_dir="$SRC_DIR/bin/targets/ramips/mt7621"
  [[ -d "$img_dir" ]] || die "未找到产物目录: $img_dir"
  mkdir -p "$OUT_DIR"
  cp -a "$img_dir"/. "$OUT_DIR"/ 2>/dev/null || true
  # FanchmWrt 私有 feed 打出的 apk（extroot 后安装完整功能要用）
  local pkg_dir="$SRC_DIR/bin/packages/mipsel_24kc/fanchmwrt"
  if [[ -d "$pkg_dir" ]]; then
    mkdir -p "$OUT_DIR/fanchmwrt-apks"
    cp -a "$pkg_dir"/. "$OUT_DIR/fanchmwrt-apks"/ 2>/dev/null || true
  fi

  log "产物已输出到 $OUT_DIR"
  find "$OUT_DIR" -maxdepth 1 -name "*.bin" -printf '  %f  (%k KB)\n' | sort
}

install_deps
fetch_source
prepare_tree
build
collect
log "完成。下一步：刷机（见 README.md）或执行 scripts/extroot-emmc.sh 扩展存储。"
