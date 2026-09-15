#!/bin/sh
# =============================================================================
#  RE-SP-01B 板载 eMMC 扩展 overlay（在路由器上执行，不是编译机）
#
#  背景：机身 32MB NOR 只有 27MB 给 firmware，装不下 FanchmWrt 全家桶。
#        但这台机器焊了 64/128GB eMMC（/dev/mmcblk0），把 overlay 搬过去即可。
#
#  用法：
#    1) scp 本脚本到路由器：scp scripts/extroot-emmc.sh root@192.168.1.1:/tmp/
#    2) ssh root@192.168.1.1 'sh /tmp/extroot-emmc.sh'
#    3) 脚本会重启，重启后 df -h 应看到 /overlay 变成几十 GB
#
#  可调：SIZE_GB=64 sh /tmp/extroot-emmc.sh   （默认 32GB）
# =============================================================================
set -e

DISK="${DISK:-/dev/mmcblk0}"
PART="${PART:-${DISK}p1}"
SIZE_GB="${SIZE_GB:-32}"

echo "==========================================================="
echo " 目标磁盘 : $DISK   分区 : $PART   容量 : ${SIZE_GB}GB"
echo " ⚠ 此操作会重建 $DISK 的分区表，盘上原有数据全部丢失！"
echo "==========================================================="
printf '确认继续请输入 yes: '
read -r confirm
[ "$confirm" = "yes" ] || { echo "已取消"; exit 1; }

# --- 0. 前提检查 -------------------------------------------------------------
[ -b "$DISK" ] || { echo "找不到 $DISK，确认内核已加载 kmod-mmc-mtk"; exit 1; }

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
echo ">> 写入 GPT 分区表并创建 ${SIZE_GB}GB 主分区"
parted -s "$DISK" -- mklabel gpt
parted -s "$DISK" -- mkpart extroot ext4 1MiB "${SIZE_GB}GiB"
partprobe "$DISK" 2>/dev/null || true
sleep 2
[ -b "$PART" ] || { echo "分区 $PART 未出现，检查 parted 输出"; exit 1; }

# 若盘太小导致 32GiB 越界，退化为使用全部空间
if ! parted -s "$DISK" print | grep -q "$PART"; then
  echo ">> ${SIZE_GB}GB 超出磁盘容量，改用 100% 空间"
  parted -s "$DISK" -- mklabel gpt
  parted -s "$DISK" -- mkpart extroot ext4 1MiB 100%
  sleep 2
fi

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

echo ">> 完成，即将重启。重启后执行 df -h 检查 /overlay 容量"
sync
reboot
