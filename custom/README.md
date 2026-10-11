# XG2010G 定制层（custom/）

本目录是 `lowaka/ponwrt` 的定制层，上游是 `pbs05/ponwrt`。
所有定制都放在这里（外加一个自有的 workflow 文件），**不改上游任何文件**，
所以每 3 天自动同步上游时不会被覆盖。

| 文件 | 作用 |
| --- | --- |
| `feeds.conf.custom` | 额外 feed：`kenzok8/openwrt-daede`（daed 的 LuCI 面板只在它这里） |
| `config.fragment` | **主要定制入口**：daed / IPTV / DDNS / 主题的插件开关 + daed 必需的内核开关 |
| `config.device` | 只编译 XG2010G 一个机型（上游默认选 9 个 an7581 机型） |
| `config.trim` | 去掉与本机无关的内容（USB / 无线 / 其它机型的 U-Boot 等） |
| `files/` | 固件文件覆盖层。构建时整棵拷进 OpenWrt 顶层 `files/`，路径等于设备上的绝对路径 |
| `files/etc/uci-defaults/99-xg2010g-defaults.sh` | 首次开机：LAN 固定 192.168.5.1、DHCP 150-249、apk 源固定为官方 |
| `upstream/release.yml.sha` | 上游 `release.yml` 的 blob sha 基线，同步时用来提示上游工作流变化 |

## 插件定稿（2026-10-11）

**透明代理只采用 daed**（eBPF/TC 数据面），OpenClash 与 Nikki 完全移除。

| 用途 | 选择 | 说明 |
| --- | --- | --- |
| 透明代理 | **daed** + `luci-app-daede` | eBPF 数据面在内核态，最省资源；实测常驻 146 MB、10% 单核 |
| 代理数据 | `v2ray-geoip` / `v2ray-geosite` | daed 的路由规则用到 `geoip:cn` / `geosite:cn` |
| IPTV | **rtp2httpd** + `luci-app-rtp2httpd` | 组播转单播 + **RTSP 时移回看** + FCC 快速换台 |
| DDNS | `ddns-go` + `luci-app-ddns-go` | 实测 12.7 MB / 空载 CPU 0.033%（Lucky 是 37 MB / 0.200%） |
| 主题 | **Aurora** | 由 workflow 克隆到 `package/luci-theme-aurora` |

**为什么不一次装多个代理**：daed / OpenClash / Nikki 会争抢 DNS 接管、TPROXY 与
nftables 规则、路由表，**同一时间只应启用一个**。

**移除 OpenClash 的连带影响（重要）**：OpenClash 是**整个 feed 树里唯一依赖 `ruby` 的包**，
移除后 Ruby 全家桶（`libruby`、`ruby-*`、`lyaml`、`libyaml`，约 4.9 MiB）就没有任何依赖方了，
`bash` / `unzip` 也只是为它而装。**以后若要重新装 OpenClash，必须先把这套 Ruby 装回来，
否则它起不来。** Nikki 用 Go 写的 mihomo 内核，不需要 Ruby。

## daed 的内核前提（最容易踩的坑）

`immortalwrt/packages` 的 `net/daed/Makefile` 里写得很明确：

```
# You need enable KERNEL_DEBUG_INFO_BTF and KERNEL_BPF_EVENTS
```

而上游 `configs/an7581.config` **恰恰是反的**：

```
CONFIG_KERNEL_DEBUG_INFO_REDUCED=y      ← 与 DEBUG_INFO_BTF 互斥，必须先关掉
# CONFIG_KERNEL_BPF_EVENTS is not set
# CONFIG_KERNEL_BPF_STREAM_PARSER is not set
```

不修的话 daed **编译能过、运行时会失败**——它需要 `/sys/kernel/btf/vmlinux` 才能把
路由规则编译成 BPF 程序。所以 `config.fragment` 里覆盖了这四项，workflow 的
`Configure` 步骤会**断言**它们生效，缺一个就直接让构建失败，避免又出一个"能刷不能跑"的固件。

BPF 工具链上游已经是「用宿主机 LLVM」的正确配置
（`CONFIG_DEVEL=y` + `BPF_TOOLCHAIN_HOST=y` + `USE_LLVM_HOST=y`），
省去从源码编译 LLVM 的 30~60 分钟；workflow 只做断言、不重复设置。

## apk 源固定为官方

上游 `package/emortal/default-settings/files/99-default-settings-chinese` 会：
把 `apk_mirror` 默认成 `https://mirrors.vsean.net/openwrt`（**只是 302 跳到
`mirrors.pku.edu.cn` 的中转层**），然后拿它无差别替换整个 `distfeeds.list`。

而 `distfeeds.list` 里混着**只有源码、没有二进制索引**的 feed
（上游的 `pon_drivers` / `pon_userspace`，以及本仓库加的 `daede`），
替换后这些条目必然 404，每次 `apk update` 刷一片
`ERROR: wget: exited with error 8`。实测：官方源上 `luci` 能取到、
`daede` 也是 404 —— 说明这些条目**在任何服务器上都不该存在**，
它们在构建期已编入镜像，运行时不需要 feed。

`99-xg2010g-defaults.sh` 以 `99-` 开头，排在 `99-default-settings-chinese` 之后
（`/etc/uci-defaults` 按文件名排序 source），因此在首次开机时覆盖它：改 `apk_mirror`、
把 `distfeeds.list` 里的镜像换回官方、并删掉那几条注定 404 的源码型 feed 条目。

> 末尾的 `exit 0` 不能省：`/etc/init.d/boot` 用 `( . "./$file" ) && applied=...`
> 判定成功，返回非 0 的文件不会被清理、下次开机会重跑。

## 构建流程（`.github/workflows/xg2010g-build.yml`）

1. checkout
2. 装 build 依赖 + 复用上游的 `dl` 缓存
3. **拼接 feeds**：`cat feeds.conf.default custom/feeds.conf.custom > feeds.conf`，
   预检裸 `#` 行、确认 `daede` feed 在
4. `./scripts/feeds update -a && ./scripts/feeds install -a`
5. 应用定制层：`cp -a custom/files/. files/`
6. **克隆 Aurora 主题**到 `package/luci-theme-aurora`
7. 生成 `.config`：`kconfig.pl + + configs/an7581.config configs/release.config custom/config.fragment`，
   再叠加 `custom/config.device` + `custom/config.trim`
8. 机型收敛双保险 + `make defconfig` + **机型数必须等于 1** + **内核 BTF 断言**
9. `make download` → `make -j"$(nproc)"`
10. 校验 manifest：daed / luci-app-daede / v2ray-geo* / rtp2httpd / ddns-go / Aurora 必须在，
    OpenClash / Nikki / mihomo / msd_lite / udpxy / lucky 必须不在
11. 打包 `ponwrt-xg2010g.tar.zst`（**只含 sysupgrade 镜像 + manifest + sha256sums**）
12. 上传 artifact 并创建 Release

## 本地复现

```sh
./scripts/feeds update -a && ./scripts/feeds install -a
mkdir -p files && cp -a custom/files/. files/
git clone --depth 1 https://github.com/eamonxg/luci-theme-aurora.git package/luci-theme-aurora
cat feeds.conf.default custom/feeds.conf.custom > feeds.conf   # 再 update/install 一次
./scripts/kconfig.pl + + configs/an7581.config configs/release.config custom/config.fragment > .config
./scripts/kconfig.pl + + .config custom/config.device custom/config.trim > .config.new
mv .config.new .config
make defconfig
make -j"$(nproc)"
```

## 改东西

- 加减插件：改 `custom/config.fragment`，push 到 `master`；`custom/**` 的改动会按
  `on.push.paths` 自动触发一次构建
- 改默认设置：往 `custom/files/` 里加文件，路径就是设备上的绝对路径去掉前导 `/`
- 加 feed：写进 `custom/feeds.conf.custom`（**不要出现「裸 # 行」**，
  `scripts/feeds` 的 `s/#.+$//` 会把它判成语法错误）

## 上游同步（`.github/workflows/sync-upstream.yml`）

- 每 3 天（`0 19 */3 * *` = 北京时间 03:00）拉 `pbs05/ponwrt` master，有新提交就 merge 后 push
- 合并成功且确实有更新时，自动触发一次 `xg2010g-build.yml`（tag `auto-<日期>-<时间>`，预发布）
- 冲突不自动猜：合并冲突时任务直接失败并列出冲突文件，交人工处理
- 上游改了 `.github/workflows/release.yml` 时打 `::warning::`（对比 `upstream/release.yml.sha`），提醒人工核对

## 注意

- 本 fork 没有 `PONWRT_APK_PRIVATE_KEY` secret，构建时 OpenWrt 会自动生成一次性 apk 签名密钥；
  想和上游用同一把签名密钥，就把私钥配成仓库 secret。
- **ponwrt 只支持 XG2010G，不支持 XR1710G**：上游 `target/linux/airoha/dts/` 里有
  `an7581-gemtek-xg2010g.dts`，没有 XR1710G 的 dts，`an7581.mk` 里也没有对应设备块。
  XR1710G 是 Wi-Fi 路由器（带 MT7996），走的是另一条线
  （`naoki66/ImmortalWrt-for-Gemtek-brightspeed` 那个 fork）。

## 只编 XG2010G（2026-10-01 调整）

上游 `configs/an7581.config` 一次选中 **9 个 an7581 机型**，加上打包步骤原本把整个
`bin/targets/airoha/an7581`（含 9 个机型的镜像和 packages 目录）塞进压缩包，
所以产物很大。现在改成只编 XG2010G：

| 改动 | 说明 |
| --- | --- |
| 新增 `custom/config.device` | 明确只选 `CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_gemtek_xg2010g=y`，并把其余 8 个机型写成 `# ... is not set`（kconfig.pl 的 add 语义是后面的文件覆盖前面，包含关闭项） |
| `xg2010g-build.yml` 的配置步骤 | 先用上游方式生成 `.config`，再叠加 `custom/config.device`，然后用一条 `sed` 把除 XG2010G 以外的所有 `DEVICE...=y` 全部改成 `is not set`（上游以后新增机型也会被这条覆盖） |
| 机型数量校验 | `make defconfig` 之后统计已选机型数，**不等于 1 就直接让构建失败**，避免又编出多机型 |
| 打包步骤 | 只打包 `*xg2010g*sysupgrade*` + `.manifest` + `sha256sums`，产物名 `ponwrt-xg2010g.tar.zst` |
| dl 缓存 key | 加入 `custom/feeds.conf.custom` 与 `custom/config.device`，配置变了会重新拉源码 |

> 刷机走 U-Boot TFTP/HTTP，用不到 recovery 镜像，所以打包时不再包含它。
> 想连 recovery 一起要，把 `files=(*xg2010g*sysupgrade* ...)` 换回 `files=(*xg2010g* ...)`。

## 去掉与本机无关的包（2026-10-01 追加）

XG2010G 没有 USB 口、没有风扇、没有 WiFi 射频。把"会真正装进固件"的包表拉出来核对：

- **USB / 无线那一批**（`kmod-usb3`、`kmod-usb-core`、`kmod-usb-storage`、`kmod-usb-storage-uas`、
  `kmod-usb-ledtrig-usbport`、`kmod-mt7915e`、`kmod-mt7916-firmware`、`kmod-mac80211`、`wpad-openssl` …）
  在上游 `configs/an7581.config` 里都是 **`=m`** —— 只编译成软件包、**不装进固件**，所以镜像里本来就没有它们。
- **风扇**：`fan2go` / `fancontrol` / `lm-sensors` / `kmod-hwmon-nct7802` 全部未选中。
- 真正会被装进固件、且与本机无关的残留只有几项，于是新增 `custom/config.trim`：

| 关闭项 | 原因 | 影响 |
| --- | --- | --- |
| `u-boot-an7581_nokia_xg-040g-md` | 给 Nokia XG-040G-MD 用的 U-Boot（9 机型配置的遗留）。`package/boot/uboot-airoha` 的 `Package/u-boot/install` 是空段，不进 rootfs，但会白触发一次 U-Boot 编译 | 省一次编译 |
| `luci-app-passwall_INCLUDE_*`（8 项） | PassWall 本体并没有选入固件，这些子选项是无效残留 | 无（清噪声） |
| `luci-app-rclone_INCLUDE_*`（2 项） | 同上 | 无 |
| `MAC80211_DEBUGFS` / `MAC80211_MESH` | 本机无 WiFi 射频（mac80211 本身是 `=m`） | 无 |

构建日志里可以看到结果：`Configure` 步骤打印插件与内核开关状态，
`Verify firmware content` 步骤打印**镜像内软件包总数**以及"应当缺席"的包（正常为空）。
