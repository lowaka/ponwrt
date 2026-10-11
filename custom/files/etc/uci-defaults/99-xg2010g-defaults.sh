#!/bin/sh
# XG2010G 定制层：首次开机（或恢复出厂后）执行一次。
#
# 做两件事：
#   1. LAN 管理地址固定 192.168.5.1，DHCP 下发 192.168.5.150-249
#   2. apk 源固定为官方 downloads.immortalwrt.org，不走第三方中转
#
# 只在首次开机 / 刷机后首次启动执行（/etc/init.d/boot 会 source 一遍然后删除），
# 所以改这里不影响已经刷好的设备，只影响之后新刷的。

# ---------- 1. LAN 地址与 DHCP 池 ----------
lan_ip="$(uci -q get network.lan.ipaddr)"

case "$lan_ip" in
	192.168.5.1)
		# 已经是目标值，什么都不用做
		;;
	""|192.168.1.1)
		uci -q set network.lan.ipaddr='192.168.5.1'
		uci -q set network.lan.netmask='255.255.255.0'
		# 池起点取 150 而不是 100：静态绑定里有 .101/.102/.103/.104/.111，
		# 落在 .150-.249 之外，与动态池完全错开。dnsmasq 虽然会把静态绑定
		# 从动态池里排除掉（不会直接冲突），但没必要把静态地址放在池子里面。
		uci -q set dhcp.lan.start='150'
		uci -q set dhcp.lan.limit='100'
		uci -q set dhcp.lan.leasetime='12h'
		uci -q commit network
		uci -q commit dhcp
		;;
	*)
		# 用户改过的地址，不碰
		;;
esac

# ---------- 2. apk 源固定为官方 ----------
# 上游 package/emortal/default-settings/files/99-default-settings-chinese 会做：
#     apk_mirror="$(uci -q get system.@imm_init[0].apk_mirror)"
#     [ -z "$apk_mirror" ] && apk_mirror="https://mirrors.vsean.net/openwrt"
#     uci -q set system.@imm_init[0].apk_mirror="$apk_mirror"
#     sed -i.bak "s,https://downloads.immortalwrt.org,$apk_mirror,g" \
#         /etc/apk/repositories.d/distfeeds.list
#
# 两个问题：
#   1. 硬编码第三方镜像。mirrors.vsean.net 只是 302 跳到 mirrors.pku.edu.cn，
#      等于让路由器依赖一个我们不掌握的中转主机。
#   2. 主机名替换是无差别的，而 distfeeds.list 里混着只有源码、没有二进制索引的
#      feed（上游 ponwrt 的 pon_drivers / pon_userspace，以及本仓库加的 daede），
#      替换后这些条目必然 404，每次 apk update 刷一片 ERROR。
#
# 本文件名以 99- 开头，排在 99-default-settings-chinese 之后
# （/etc/uci-defaults 按文件名排序 source），所以能在上游写入默认值之后覆盖它。
# 末尾的 exit 0 是必需的：/etc/init.d/boot 用 `( . "./$file" ) && applied=...`
# 判定，返回非 0 的文件不会被清理、下次开机会重跑。
OFFICIAL='https://downloads.immortalwrt.org'

if [ -f /etc/config/system ]; then
	uci -q get system.@imm_init[0] >/dev/null 2>&1 || uci -q add system imm_init
	cur="$(uci -q get system.@imm_init[0].apk_mirror)"
	if [ "$cur" != "$OFFICIAL" ]; then
		uci -q set system.@imm_init[0].apk_mirror="$OFFICIAL"
		uci -q commit system
		logger -t xg2010g-defaults "apk_mirror set to $OFFICIAL (was: ${cur:-unset})"
	fi
fi

# 把 distfeeds.list 里已指向第三方镜像的行换回官方，并删掉那些注定 404 的
# 源码型 feed 条目（它们在构建期已编入镜像，运行时不需要 feed）。
D=/etc/apk/repositories.d/distfeeds.list
if [ -f "$D" ]; then
	sed -i 's,https://mirrors.vsean.net/openwrt,https://downloads.immortalwrt.org,g' "$D"
	for f in daede dae pon_drivers pon_userspace; do
		sed -i "\|/packages/aarch64_cortex-a53/$f/packages.adb|d" "$D"
	done
fi

exit 0
