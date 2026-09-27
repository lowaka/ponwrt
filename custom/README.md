# XG2010G 定制层（custom/）

本目录是 `lowaka/ponwrt` 的定制层，上游是 `pbs05/ponwrt`。
所有定制都放在这里（外加一个自有的 workflow 文件），**不改上游任何文件**，
所以每 3 天自动同步上游时不会被覆盖。

| 文件 | 作用 |
| --- | --- |
| `config.fragment` | 追加到 `.config` 的插件开关：OpenClash / msd_lite / ddns-go |
| `files/` | 固件文件覆盖层。构建时整棵拷进 OpenWrt 顶层 `files/`，路径等于设备上的绝对路径 |
| `files/etc/uci-defaults/99-xg2010g-defaults.sh` | 首次开机：LAN 固定 192.168.5.1，DHCP 192.168.5.100-249 |
| `scripts/fetch-openclash-core.sh` | 构建时把最新 OpenClash 官方内核放到 `files/etc/openclash/core/clash_meta` |
| `upstream/release.yml.sha` | 上游 `release.yml` 的 blob sha 基线，同步时用来提示上游工作流变化 |

## mihomo / OpenClash 内核是怎么进固件的

OpenClash 的 LuCI 包**不带内核**，内核是运行时放在 `/etc/openclash/core/clash_meta` 的。
所以做法是：`make` 之前把内核下载到 `files/etc/openclash/core/clash_meta`。
`files/` 是 OpenWrt 官方支持的 rootfs 覆盖层（`include/image.mk` 里 `prepare_rootfs ... $(TOPDIR)/files`），
`make` 打 rootfs 时会整棵拷进去 —— 刷完机就自带内核，OpenClash 不用再联网下载，也不用手工上传。

- 来源：`vernesong/OpenClash` 的 `core` 分支 `meta/clash-linux-arm64.tar.gz`（OpenClash 官方自用内核，和界面里“更新内核”下载的是同一个）
- 体积：约 10.7 MB
- 形态：aarch64 静态 ELF（无 PT_INTERP），musl 的 OpenWrt 直接可跑
- 校验：下载后检查 ELF 魔数 / aarch64 / 是否动态链接 / 体积，任一项不合格就换下一个镜像源，全部失败则构建报错
- 留痕：内核来源与 sha256 写进 `/etc/openclash/core/.core-info`

> 对比：MetaCubeX 官方 mihomo 最新 release 也是静态 aarch64，但解包后约 57 MB，本机闪存不划算，所以不用。

## 构建流程（`.github/workflows/xg2010g-build.yml`）

1. checkout
2. 装 build 依赖 + 复用上游的 `dl` 缓存
3. `./scripts/feeds update -a && ./scripts/feeds install -a`
4. 应用定制层：`cp -a custom/files/. files/`
5. 抓内核：`bash custom/scripts/fetch-openclash-core.sh`
6. 生成 `.config`：`./scripts/kconfig.pl + + configs/an7581.config configs/release.config custom/config.fragment`
7. `make download` → `make -j"$(nproc)"`
8. 打包 `ponwrt-an7581.tar.zst` + `sha256sums`，上传 artifact 并创建 Release

## 本地复现

```sh
./scripts/feeds update -a && ./scripts/feeds install -a
mkdir -p files && cp -a custom/files/. files/
bash custom/scripts/fetch-openclash-core.sh
./scripts/kconfig.pl + + configs/an7581.config configs/release.config custom/config.fragment > .config
make defconfig
make -j"$(nproc)"
```

## 改东西

- 加减插件：改 `custom/config.fragment`，push 到 `master`；`custom/**` 的改动会按 `on.push.paths` 自动触发一次构建
- 改默认设置：往 `custom/files/` 里加文件，路径就是设备上的绝对路径去掉前导 `/`
- 内核版本：`fetch-openclash-core.sh` 每次构建都取 `core` 分支当时最新的内核；想固定版本就把 URL 换成带提交号的 raw 链接

## 上游同步（`.github/workflows/sync-upstream.yml`）

- 每 3 天（`0 19 */3 * *` = 北京时间 03:00）拉 `pbs05/ponwrt` master，有新提交就 merge 后 push
- 合并成功且确实有更新时，自动触发一次 `xg2010g-build.yml`（tag `auto-<日期>-<时间>`，预发布）
- 冲突不自动猜：合并冲突时任务直接失败并列出冲突文件，交人工处理
- 上游改了 `.github/workflows/release.yml` 时打 `::warning::`（对比 `upstream/release.yml.sha`），提醒人工核对

## 注意

- 本 fork 没有 `PONWRT_APK_PRIVATE_KEY` secret，构建时 OpenWrt 会自动生成一次性 apk 签名密钥；想和上游用同一把签名密钥，就把私钥配成仓库 secret。
- `configs/an7581.config` 会一次性构建 9 个 an7581 机型，插件是全局打开的；只关心 XG2010G 的话，忽略其它机型的镜像即可。
