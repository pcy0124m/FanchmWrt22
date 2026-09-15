# FanchmWrt for JDCloud RE-SP-01B（京东云无线宝一代 / MT7621）

一套开箱即用的构建工程：把 [FanchmWrt](https://github.com/fanchmwrt/fanchmwrt) 编译到京东云无线宝一代上，含**云端编译工作流**、**本地一键脚本**、**eMMC 扩容脚本**和**刷机手册**。

## 先看结论

| 问题 | 结论 |
| --- | --- |
| 要不要自己写 DTS / 设备树？ | **不用**。FanchmWrt 25.12.4 起已内置 `target/linux/ramips/dts/mt7621_jdcloud_re-sp-01b.dts` 和 `mt7621.mk` 里的 `Device/jdcloud_re-sp-01b`（镜像上限 27328k，默认带 kmod-mt7603 / kmod-mt7615-firmware / kmod-mmc-mtk / kmod-usb3）。本工程已验证这两处存在，缺一就报错停机 |
| 主要难点是什么？ | **闪存太小**。32MB NOR 里 firmware 分区只有 27MB，FanchmWrt 的 DPI / OAF 特征库 / LuCI 全家桶塞不下 |
| 怎么解决？ | 精简镜像（约 14–18MB）刷进去 → 用机身自带 64/128GB eMMC 做 extroot 扩展 overlay → 再离线安装完整功能组件 |
| 软件包装哪个命令？ | 25.12 基于 OpenWrt 快照，**默认 apk（apk-tools）**，不是 opkg；且官方源没有你这套内核版本的包，所以要离线装自己编译出来的 apk |

## 硬件参数

| 项目 | 规格 |
| --- | --- |
| SoC | MediaTek MT7621AT，双核 MIPS 1004Kc @ 880MHz |
| 内存 | 256MB DDR3（以机身批次为准） |
| 闪存 | 32MB SPI NOR |
| 板载存储 | 64GB / 128GB eMMC（`/dev/mmcblk0`，走 kmod-mmc-mtk） |
| 无线 | 2.4G MT7603EN（factory@0x0）+ 5G MT7615N（factory@0x8000） |
| 网口 | 1×GE WAN + 2×GE LAN（内置 MT7530，DSA 架构） |
| USB | 1×USB 3.0 |
| 按键 / LED | Reset = GPIO18；状态灯 红 GPIO6 / 绿 GPIO8 / 蓝 GPIO12 |

闪存分区（来自设备树）：

| 分区 | 起始 | 大小 | 说明 |
| --- | --- | --- | --- |
| u-boot | 0x0 | 192KB | 别动 |
| config | 0x30000 | 64KB | 别动 |
| factory | 0x40000 | 64KB | **无线校准数据，务必先备份** |
| firmware | 0x50000 | 27328KB | OpenWrt 就刷这里 |
| mini / oem | 0x1b00000 起 | — | 原厂残留，可不管 |

## 目录结构

```
fanchmwrt-re-sp-01b/
├── README.md
├── config/
│   ├── re-sp-01b-minimal.seed   # 精简版配置（推荐）
│   └── re-sp-01b-full.seed      # 全功能版配置（大概率超 27MB，慎选）
├── files/etc/config/            # 打进镜像的默认配置（主机名/时区/网络）
│   ├── network
│   └── system
├── scripts/
│   ├── build.sh                 # 构建主脚本（云端/本地共用）
│   ├── extroot-emmc.sh          # 路由器上执行：eMMC 扩展 overlay
│   └── install-fwx-apps.sh      # 路由器上执行：离线安装 DPI 全家桶
└── .github/workflows/build-resp01b.yml   # GitHub Actions 云编译
```

## 方式一：GitHub Actions 云编译（推荐，本地零环境）

1. 建仓库并推送：

```bash
cd fanchmwrt-re-sp-01b
git init && git add . && git commit -m "FanchmWrt for RE-SP-01B"
gh repo create fanchmwrt-resp01b --private --source=. --push
```

2. 打开仓库 → **Actions** → `FanchmWrt RE-SP-01B` → **Run workflow**（profile 选 `minimal`，mirror 保持 `true`）。

3. 等 2–4 小时（首次编译要编工具链），完成后在 Artifact 里下载：

| 文件 | 用途 |
| --- | --- |
| `fanchmwrt-ramips-mt7621-jdcloud_re-sp-01b-squashfs-sysupgrade.bin` | 正式刷机包 |
| `fanchmwrt-ramips-mt7621-jdcloud_re-sp-01b-initramfs-kernel.bin` | 内存版，用于**先验证再落 flash** |
| `fanchmwrt-apks/` | 完整功能组件的 apk，extroot 后离线安装 |

> 镜像前缀由 `CONFIG_VERSION_DIST` 决定，配置里已设为 `FanchmWrt`；删掉这行就变回默认的 `openwrt-` 前缀。

> 打 tag（`git tag v1 && git push --tags`）会自动发布 Release。
> 若 Actions 报磁盘不足：工作流里已内置清理步骤；仍失败就把 `profile` 换成精简档或改用本地编译。

## 方式二：本地编译（Ubuntu 22.04 / 24.04 / WSL2）

```bash
sudo apt update
cd ~
# 放入本工程目录后：
cd fanchmwrt-re-sp-01b
chmod +x scripts/*.sh
./scripts/build.sh --profile minimal          # 自动装依赖、拉源码、打配置、编译
```

常用参数：

| 参数 | 作用 |
| --- | --- |
| `--profile full` | 编全功能版（超体积会失败） |
| `--no-mirror` | 海外网络，feeds 不走 GitHub 镜像 |
| `--skip-deps` | 依赖已装好，跳过 apt |
| `--jobs 8` | 指定并行数，默认 `nproc` |
| `--src-dir /data/fanchmwrt` | 指定源码目录（默认 `./fanchmwrt`） |

产物在 `out/`。二次编译想改包，先 `cd fanchmwrt && make menuconfig` 再 `make -j$(nproc)`；不想重编可以直接用 Image Builder（`CONFIG_IB=y` 已开）：

```bash
cd fanchmwrt/bin/targets/ramips/mt7621
tar -xf openwrt-imagebuilder-*.tar.xz && cd openwrt-imagebuilder-*
make image PROFILE="jdcloud_re-sp-01b" PACKAGES="luci luci-i18n-base-zh-cn block-mount kmod-fs-ext4"
```

## 刷机流程

> ⚠ 全程风险自负。**第一件事是备份整颗 NOR 和 factory 分区**（编程器夹 / TTL / breed 里导出都行），没有 factory 备份就变砖风险大增。

| 步骤 | 操作 |
| --- | --- |
| 1 | 机器刷入 Breed（MT7621 通用版或 RE-SP-01B 专用版），断电按住 Reset 上电，PC 设 `192.168.1.2` 访问 `192.168.1.1` 进 Breed Web 恢复控制台 |
| 2 | **先验证**：在 Breed 里选 `initramfs-kernel.bin` 载入内存启动，能进 LuCI、认到 eMMC、无线正常再往下做 |
| 3 | **再落 flash**：Breed 控制台刷 `firmware` 分区，选 `...-squashfs-sysupgrade.bin`；闪存布局按 0x50000 起（选错布局会起不来） |
| 4 | 首次启动等 1–2 分钟，访问 `http://192.168.1.1`，默认无密码（LuCI 会提示设置） |
| 5 | 无线默认关闭：LuCI → 网络 → 无线 → 启用 2.4G/5G，国家码选 CN |

## 扩容：把 overlay 搬到 eMMC

```bash
scp scripts/extroot-emmc.sh root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'sh /tmp/extroot-emmc.sh'      # 默认划 32GB，可 SIZE_GB=64
ssh root@192.168.1.1 'df -h | grep overlay'          # 应看到几十 GB
```

之后装完整功能组件：

```bash
scp out/fanchmwrt-apks/*.apk root@192.168.1.1:/tmp/apks/
ssh root@192.168.1.1 'sh -s' < scripts/install-fwx-apps.sh
```

## 排错

| 现象 | 原因 / 处理 |
| --- | --- |
| `image is too big` | 超过 27328KB，换 `--profile minimal`，或砍掉特征库/luci 应用 |
| feeds 拉取超时 | 脚本默认换 GitHub 镜像；单独失败可手动 `git clone` 后 `./scripts/feeds update -a` |
| 编译中途报错 | 脚本会自动用 `make -j1 V=s` 重跑，看最后 50 行即可定位 |
| 刷完反复重启 | 分区布局不匹配或 factory 被擦；用 breed 重刷并恢复 factory 备份 |
| 无线搜索不到 | 默认未启用；确认 `kmod-mt7603` `kmod-mt7615-firmware` 在镜像里 |
| `/dev/mmcblk0` 不存在 | 缺 `kmod-mmc-mtk`，或硬件批次无 eMMC |
| `apk add` 报 incompatible / 找不到包 | 官方源没有这套快照版本；用自己编译的 `fanchmwrt-apks/` 离线装 |
| LuCI 菜单不显示新装的 app | `rm -rf /tmp/luci-indexcache* && /etc/init.d/uhttpd restart` |
| Actions 空间不足 | runner 默认约 20G；工作流已清理，仍不够就本地编译 |
| 某个包没编进去 | 快照版本包名会变，不存在的 `CONFIG_PACKAGE_*` 会被 `make defconfig` 静默忽略；`make menuconfig` 里搜同名确认 |

## 许可

FanchmWrt 为 GPL-2.0，重新发布固件需保留源码中的版权信息；其 OAF 应用特征文件仅供个人使用，禁止商用。
