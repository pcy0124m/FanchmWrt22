#!/bin/sh
# =============================================================================
#  RE-SP-01B 用 USB 移动硬盘扩展 overlay（在路由器上执行，不是编译机）
#
#  背景：机身 32MB NOR 只有 27MB 给 firmware，装不下 FanchmWrt 全家桶。
#        若机器没有 eMMC（或不想动 eMMC），可把 overlay 搬到 USB 移动硬盘，
#        效果完全一样。镜像需已带 kmod-usb2 / kmod-usb-storage / block-mount
#        （re-sp-01b-minimal.seed 已包含这三项）。
#
#  用法：
#    1) scp 本脚本到路由器：scp scripts/extroot-usb.sh root@192.168.12.1:/tmp/
#    2) ssh root@192.168.12.1 'sh /tmp/extroot-usb.sh'
#    3) 脚本会重启，重启后执行: mount | grep overlay  应看到 /dev/sda1 on /overlay
#
#  可调：DISK=/dev/sdb sh /tmp/extroot-usb.sh
#
#  ⚠ 2.5" 移动硬盘务必确认供电：路由 USB 口常带不动，建议带源 USB hub / 外接电源，
#    否则表现为硬盘认不出或频繁掉盘。
#  ⚠ 此操作会重建 $DISK 分区表，盘上原有数据全部丢失！
# =============================================================================
set -e

DISK="${DISK:-/dev/sda}"
PART="${PART:-${DISK}1}"

echo "==========================================================="
echo " 目标磁盘 : $DISK   分区 : $PART"
echo " ⚠ 此操作会重建 $DISK 的分区表，盘上原有数据全部丢失！"
echo "==========================================================="
printf '确认继续请输入 yes: '
read -r confirm
[ "$confirm" = "yes" ] || { echo "已取消"; exit 1; }

# --- 0. 前提检查 -------------------------------------------------------------
[ -b "$DISK" ] || { echo "找不到 $DISK，确认移动硬盘已插入且内核已加载 kmod-usb2/kmod-usb-storage"; exit 1; }

command -v block >/dev/null || { echo "缺少 block 工具：apk add block-mount blockd"; exit 1; }

if ! command -v parted >/dev/null; then
  echo ">> 未找到 parted，尝试安装（需要网络或本地 apk）"
  if command -v apk >/dev/null; then
    apk add parted || apk add --allow-untrusted /tmp/apks/parted*.apk || \
      { echo "安装 parted 失败，请手动上传 parted apk 后重试"; exit 1; }
  else
    opkg update && opkg install parted || \
      { echo "安装 parted 失败，请手动上传 parted ipk 后重试"; exit 1; }
  fi
fi

# --- 1. 分区 ----------------------------------------------------------------
echo ">> 写入 MBR 分区表并创建占满整盘的主分区"
parted -s "$DISK" -- mklabel msdos
parted -s "$DISK" -- mkpart primary ext4 1MiB 100%
partprobe "$DISK" 2>/dev/null || true
sleep 2
[ -b "$PART" ] || { echo "分区 $PART 未出现，检查 parted 输出"; exit 1; }

# --- 2. 格式化 --------------------------------------------------------------
echo ">> 格式化为 ext4"
mkfs.ext4 -F -L extroot "$PART"

# --- 3. 配置 fstab 并迁移 overlay ------------------------------------------
echo ">> 写入 fstab 并复制当前 overlay"
eval "$(block info "$PART" | grep -o -e 'UUID="[^"]*"')"
eval "$(block info | grep -o -e 'MOUNT="[^"]*/overlay"')"
[ -n "${UUID:-}" ] || { echo "取不到分区 UUID"; exit 1; }
[ -n "${MOUNT:-}" ] || MOUNT="/overlay"

uci -q delete fstab.extroot
uci set fstab.extroot='mount'
uci set fstab.extroot.uuid="$UUID"
uci set fstab.extroot.target="$MOUNT"
uci set fstab.extroot.enabled='1'
uci commit fstab

mkdir -p /mnt/extroot
mount "$PART" /mnt/extroot
tar -C "$MOUNT" -cf - . | tar -C /mnt/extroot -xf -
umount /mnt/extroot

echo ">> 完成，即将重启。重启后执行 mount | grep overlay 确认 /overlay 已挂在移动硬盘上"
sync
reboot
