#!/bin/sh
# XG2010G 定制层：首次开机（或恢复出厂后）执行一次。
# 作用：把 LAN 管理地址固定为 192.168.5.1，DHCP 下发 192.168.5.100-249。
# 如果 LAN 地址已经被改成别的值，保持不动，避免覆盖用户自己的设置。

lan_ip="$(uci -q get network.lan.ipaddr)"

case "$lan_ip" in
	192.168.5.1)
		# 已经是目标值，什么都不用做
		;;
	""|192.168.1.1)
		uci -q set network.lan.ipaddr='192.168.5.1'
		uci -q set network.lan.netmask='255.255.255.0'
		uci -q set dhcp.lan.start='100'
		uci -q set dhcp.lan.limit='150'
		uci -q set dhcp.lan.leasetime='12h'
		uci -q commit network
		uci -q commit dhcp
		;;
	*)
		# 用户改过的地址，不碰
		;;
esac

exit 0
