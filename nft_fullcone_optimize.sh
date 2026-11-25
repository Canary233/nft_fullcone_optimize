#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# nft_fullcone_optimize.sh
#
# 给 OpenWrt / ImmortalWrt 源码树里的 nft-fullcone 内核模块打上
# "已确认连接直接返回" 补丁。
#
# 背景：nf_nat_handle_prerouting()/postrouting() 对每一个包都会
#   1) 抢全局自旋锁 fullconenat_lock
#   2) 遍历 1024 桶的全局 mapping 哈希表
#   3) 对已确认连接调用 nf_nat_setup_info()（内核里对 confirmed ct 直接返回）
#   4) 仍然执行 add_original_tuple_to_mapping()：每包一次 kmalloc + 链表插入
#
# 结果是在高并发 NAT（PCDN/BT/大流量 UDP）下 CPU 大量消耗在自旋锁和
# 内存分配上，而且每条连接会插入 N 条 tuple，连接销毁时只删 1 条，
# 映射表只增不减、哈希链越来越长。
#
# 修复：conntrack 已确认时直接返回，语义不变（新连接仍走完整 fullcone 逻辑）。

set -e

PROG=$(basename "$0")
PATCH_NAME="020-skip-confirmed-conntrack.patch"
SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
PATCH_SRC="$SCRIPT_DIR/$PATCH_NAME"

DO_BUILD=0
DO_REVERT=0
DO_DRY=0
PKG_DIR=""

usage() {
	cat <<EOF
用法: $PROG [选项]

必须在 OpenWrt/ImmortalWrt 源码树根目录执行（或显式指定 --package-dir）。

选项:
  --package-dir DIR   nft-fullcone 包目录（默认自动查找
                      package/network/utils/fullconenat-nft）
  --build             打完补丁后执行 make <pkg>/compile
  --revert            移除补丁并回退 PKG_RELEASE
  --dry-run           只显示将要执行的动作
  -h, --help          显示本帮助

示例:
  $PROG                 # 安装补丁
  $PROG --build         # 安装并重新编译 kmod-nft-fullcone
  $PROG --revert        # 卸载补丁
EOF
}

log() { printf '%s\n' "$*"; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		--package-dir)
			[ $# -ge 2 ] || die "--package-dir 缺少参数"
			PKG_DIR="$2"
			shift
			;;
		--build)   DO_BUILD=1 ;;
		--revert)  DO_REVERT=1 ;;
		--dry-run) DO_DRY=1 ;;
		-h|--help) usage; exit 0 ;;
		*) die "未知选项: $1（用 --help 查看用法）" ;;
	esac
	shift
done

[ -f "$PATCH_SRC" ] || die "找不到补丁文件 $PATCH_SRC（需要和脚本放在同一目录）"

# ---- 定位包目录 ----------------------------------------------------------
if [ -z "$PKG_DIR" ]; then
	for d in \
		package/network/utils/fullconenat-nft \
		package/feeds/*/fullconenat-nft \
		package/feeds/*/*/fullconenat-nft \
		feeds/*/net/fullconenat-nft \
		feeds/*/fullconenat-nft
	do
		if [ -f "$d/Makefile" ]; then
			PKG_DIR="$d"
			break
		fi
	done
fi

[ -n "$PKG_DIR" ] && [ -f "$PKG_DIR/Makefile" ] \
	|| die "找不到 nft-fullcone 包，请用 --package-dir 指定"

grep -q 'PKG_NAME:=fullconenat-nft' "$PKG_DIR/Makefile" \
	|| die "$PKG_DIR 看起来不是 nft-fullcone 包（PKG_NAME 不匹配）"

PKG_DIR=${PKG_DIR%/}
DST="$PKG_DIR/patches/$PATCH_NAME"

get_release() {
	sed -n 's/^PKG_RELEASE[[:space:]]*:*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
		"$PKG_DIR/Makefile" | head -n 1
}

bump_release() {
	rel=$(get_release)
	[ -n "$rel" ] || { log "提示: PKG_RELEASE 不是纯数字，跳过自增"; return 0; }
	new=$((rel + 1))
	if [ "$DO_DRY" = 1 ]; then
		log "[dry-run] PKG_RELEASE: $rel -> $new"
		return 0
	fi
	sed -i "s/^PKG_RELEASE[[:space:]]*:*=.*/PKG_RELEASE:=$new/" "$PKG_DIR/Makefile"
	log "PKG_RELEASE: $rel -> $new"
}

# ---- 卸载 ----------------------------------------------------------------
if [ "$DO_REVERT" = 1 ]; then
	if [ -f "$DST" ]; then
		[ "$DO_DRY" = 1 ] || rm -f "$DST"
		log "已移除 $DST"
	else
		log "补丁未安装，无需移除"
	fi
	rel=$(get_release)
	if [ -n "$rel" ] && [ "$rel" -gt 1 ]; then
		new=$((rel - 1))
		if [ "$DO_DRY" = 1 ]; then
			log "[dry-run] PKG_RELEASE: $rel -> $new"
		else
			sed -i "s/^PKG_RELEASE[[:space:]]*:*=.*/PKG_RELEASE:=$new/" "$PKG_DIR/Makefile"
			log "PKG_RELEASE: $rel -> $new"
		fi
	fi
	log "完成后请重新编译并刷机: make $PKG_DIR/clean && make $PKG_DIR/compile"
	exit 0
fi

# ---- 安装 ----------------------------------------------------------------
log "包目录: $PKG_DIR"
rel=$(get_release)
log "当前 PKG_RELEASE: ${rel:-<非数字>}"

if [ -f "$DST" ]; then
	log "补丁已安装: $DST（跳过复制和 release 自增）"
else
	if [ "$DO_DRY" = 1 ]; then
		log "[dry-run] 复制 $PATCH_NAME -> $DST"
	else
		mkdir -p "$PKG_DIR/patches"
		cp "$PATCH_SRC" "$DST"
		log "已安装: $DST"
	fi
	bump_release
fi

# ---- 校验（如果能找到已解压的源码） --------------------------------------
SRC_PARENT=$(ls -d build_dir/target-*/linux-*/fullconenat-nft-* 2>/dev/null | head -n 1 || true)
if [ -n "$SRC_PARENT" ] && [ -f "$SRC_PARENT/src/nf_nat_fullcone.c" ]; then
	if grep -q 'if (nf_ct_is_confirmed(ct))' "$SRC_PARENT/src/nf_nat_fullcone.c"; then
		log "校验: 已解压源码中已包含修复"
	elif [ "$DO_DRY" = 1 ]; then
		log "[dry-run] 跳过 patch --dry-run 校验"
	elif patch -p1 --dry-run -d "$SRC_PARENT" < "$DST" >/dev/null 2>&1; then
		log "校验: 补丁可以干净地应用到已解压源码"
	else
		log "警告: 补丁无法应用到 $SRC_PARENT（源码版本可能不同），"
		log "      建议先 make $PKG_DIR/clean 后重试。"
	fi
else
	log "提示: 未找到已解压源码，跳过校验（首次编译时会自动应用）"
fi

# ---- 可选：编译 ----------------------------------------------------------
if [ "$DO_BUILD" = 1 ]; then
	jobs=$(nproc 2>/dev/null || echo 4)
	if [ "$DO_DRY" = 1 ]; then
		log "[dry-run] make $PKG_DIR/compile -j$jobs"
	else
		log "开始编译: make $PKG_DIR/compile -j$jobs"
		make "$PKG_DIR/compile" -j"$jobs"
		ko=$(find build_dir -path "*fullconenat-nft*" -name nft_fullcone.ko 2>/dev/null | head -n 1 || true)
		[ -n "$ko" ] && log "生成模块: $ko"
	fi
fi

cat <<EOF

完成。后续步骤:
  1. 重新编译并刷机（kmod-nft-fullcone 已包含修复）:
       make $PKG_DIR/compile
  2. 运行中的设备可临时热替换模块（会短暂中断 NAT）:
       uci set firewall.@defaults[0].fullcone=0 && uci commit firewall
       /etc/init.d/firewall reload
       rmmod nft_fullcone
       insmod <新编译的 nft_fullcone.ko>
       uci set firewall.@defaults[0].fullcone=1 && uci commit firewall
       /etc/init.d/firewall reload

注意: 卸载补丁时请重新 make clean 后再编译，否则 build_dir 里
      仍是打过补丁的源码。
EOF