#!/bin/sh
# 构建时把最新的 OpenClash 官方 mihomo(Meta) 内核打进固件。
# 产物：files/etc/openclash/core/clash_meta  ->  rootfs 里的 /etc/openclash/core/clash_meta
#
# 来源是 OpenClash 自己的 core 分支（vernesong/OpenClash），也就是 OpenClash 界面里
# “更新内核”时下载的同一个文件：aarch64 静态 ELF，约 10.7MB，musl 的 OpenWrt 直接可跑。
# 之所以在编译期下载：这样刷完机就自带内核，不用联网下载、也不用手工上传。
set -eu

CORE_DIR="files/etc/openclash/core"
mkdir -p "$CORE_DIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MIRRORS="
https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz
https://cdn.jsdelivr.net/gh/vernesong/OpenClash@core/meta/clash-linux-arm64.tar.gz
https://ghfast.top/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz
https://gh-proxy.com/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz
"

# 校验：ELF 魔数 + aarch64 + 静态链接 + 体积合理
check_core() {
	_core="$1"
	[ -s "$_core" ] || { echo "::warning::内核文件为空"; return 1; }

	_magic="$(od -An -tx1 -N4 "$_core" | tr -d ' \n')"
	[ "$_magic" = "7f454c46" ] || { echo "::warning::不是 ELF 文件（magic=$_magic）"; return 1; }

	_machine="$(od -An -tx1 -j18 -N2 "$_core" | tr -d ' \n')"
	[ "$_machine" = "b700" ] || { echo "::warning::不是 aarch64（e_machine=$_machine）"; return 1; }

	if command -v readelf >/dev/null 2>&1 && readelf -l "$_core" 2>/dev/null | grep -q INTERP; then
		echo "::warning::内核是动态链接的（存在 PT_INTERP），musl 的 OpenWrt 上跑不起来"
		return 1
	fi

	_size="$(wc -c < "$_core" | tr -d ' ')"
	if [ "$_size" -lt 5000000 ] || [ "$_size" -gt 40000000 ]; then
		echo "::warning::内核体积异常：$_size 字节"
		return 1
	fi
	return 0
}

ok=0
used=""
for url in $MIRRORS; do
	echo "== 尝试下载 OpenClash 内核：$url"
	rm -f "$TMP/core.tar.gz" "$TMP/clash"
	if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 300 \
		-o "$TMP/core.tar.gz" "$url" &&
		tar -xzf "$TMP/core.tar.gz" -C "$TMP" &&
		check_core "$TMP/clash"; then
		install -m 0755 "$TMP/clash" "$CORE_DIR/clash_meta"
		ok=1
		used="$url"
		break
	fi
done

if [ "$ok" != "1" ]; then
	echo "::error::OpenClash 内核下载/校验失败（所有镜像源都不可用）" >&2
	exit 1
fi

{
	echo "source=$used"
	echo "size=$(wc -c < "$CORE_DIR/clash_meta" | tr -d ' ')"
	echo "md5=$(md5sum "$CORE_DIR/clash_meta" | cut -d' ' -f1)"
	echo "sha256=$(sha256sum "$CORE_DIR/clash_meta" | cut -d' ' -f1)"
	echo "fetched=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$CORE_DIR/.core-info"

echo "== 内核已就位：$(ls -l "$CORE_DIR/clash_meta")"
cat "$CORE_DIR/.core-info"
