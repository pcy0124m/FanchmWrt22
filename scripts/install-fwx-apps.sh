#!/bin/sh
# =============================================================================
#  安装 FanchmWrt 完整功能组件（DPI / 应用过滤 / 流量审计 / 家长控制 等）
#
#  前置：已在路由器上跑过 scripts/extroot-emmc.sh，overlay 已扩到 eMMC。
#
#  为什么不能直接 apk add 拉网上的包：FanchmWrt 基于 OpenWrt 快照版本，
#  官方软件源没有对应内核版本后缀的包，也没有 fanchmwrt 私有 feed 的包。
#  所以要用你自己编译产物里的 apk 离线安装。
#
#  用法（编译机上）：
#    scp out/fanchmwrt-apks/*.apk root@192.168.1.1:/tmp/apks/
#    ssh root@192.168.1.1 'sh -s' < scripts/install-fwx-apps.sh
#  或在路由器上：把本脚本放 /tmp，sh /tmp/install-fwx-apps.sh
# =============================================================================
set -e

APK_DIR="${APK_DIR:-/tmp/apks}"
LUCI_APPS="luci-app-fwx-app-center luci-app-fwx-appfilter luci-app-fwx-dashboard \
luci-app-fwx-dashboard-setting luci-app-fwx-feature luci-app-fwx-network \
luci-app-fwx-session-stat luci-app-fwx-system luci-app-fwx-traffic-stat \
luci-app-fwx-user luci-app-fwx-user-record luci-app-fwx-record \
luci-app-fwx-record-whitelist luci-app-fwx-mac-blacklist luci-app-fwx-macfilter \
luci-app-fwx-wireless luci-app-fwx-resources"

[ -d "$APK_DIR" ] || { echo "找不到 $APK_DIR，先把编译产物里的 fanchmwrt-apks 拷进来"; exit 1; }

echo ">> 可用包清单："
ls -1 "$APK_DIR" | sed 's/^/   /'

if command -v apk >/dev/null; then
  echo ">> 使用 apk 离线安装（--allow-untrusted 跳过自建源签名）"
  # shellcheck disable=SC2086
  apk add --allow-untrusted --force-overwrite $(
    for app in $LUCI_APPS; do
      ls "$APK_DIR"/${app}_*.apk 2>/dev/null
    done
  ) || true
  echo ">> 若上面有包没命中，直接全量安装目录内所有 apk："
  echo "   apk add --allow-untrusted $APK_DIR/*.apk"
elif command -v opkg >/dev/null; then
  echo ">> 使用 opkg 离线安装"
  # shellcheck disable=SC2086
  opkg install --force-depends --force-overwrite $(
    for app in $LUCI_APPS; do
      ls "$APK_DIR"/${app}_*.ipk 2>/dev/null
    done
  ) || true
else
  echo "既没有 apk 也没有 opkg？"; exit 1
fi

echo ">> 清理 LuCI 缓存并重载"
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true
/etc/init.d/rpcd restart 2>/dev/null || true
echo ">> 完成，刷新浏览器即可看到 FanchmWrt 的 DPI / 家长控制面板"
