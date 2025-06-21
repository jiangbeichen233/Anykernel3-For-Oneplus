#!/bin/bash
set -e

# ========== 0. 颜色与日志 ==========
[ -t 1 ] && {
    N="\033[0m"; G="\033[32m"; R="\033[31m"; Y="\033[33m"
} || { N=""; G=""; R=""; Y=""; }
log() { echo -e "${Y}[$(date '+%T')] $1${N}"; }
err() { echo -e "${R}ERROR: $1${N}" >&2; exit 1; }

# ======= 版权声明 =======
echo -e "${G}此内核来自酷安姜北尘 免费发布请勿盗用${N}"
sleep 1

log() { echo -e "${Y}[$(date '+%T')] $1${N}"; }
err() { echo -e "${R}ERROR: $1${N}" >&2; exit 1; }

# ========== 1. 环境准备 ==========
[ "$(id -u)" -ne 0 ] && err "请以root权限运行"
export PATH="/system/bin:$PATH"
LOGFILE="/dev/null"   # 如需调试可改为实际日志路径

# ========== 2. 变量定义 ==========
AK3_DIR="$(cd "$(dirname "$0")"; pwd)"
BIN_DIR="$AK3_DIR/bin"
DTBO_TOOL="$BIN_DIR/mkdtimg"
DTC_TOOL="$BIN_DIR/dtc"
TMP_DIR="$(mktemp -d /tmp/ak3dtbo.XXXXXX)"
trap 'rm -rf "$TMP_DIR" dtb.* dts.dtb.* dtbo_new.img dtbo.img 2>/dev/null' EXIT

# ========== 3. 分区信息 ==========
current_slot=$(getprop ro.boot.slot_suffix)
[ -z "$current_slot" ] && err "未检测到A/B分区，请确认设备支持A/B系统"
target_slot=$([ "$current_slot" = "_a" ] && echo "_b" || echo "_a")
log "分区槽信息：当前槽位=${current_slot} 目标槽位=${target_slot}"

DTBO_A="/dev/block/by-name/dtbo_a"
DTBO_B="/dev/block/by-name/dtbo_b"
CUR_DTBO="/dev/block/by-name/dtbo${current_slot}"
TGT_DTBO="/dev/block/by-name/dtbo${target_slot}"

# ========== 4. 读取 & 检查 ==========
log "读取当前槽位 dtbo 分区: $CUR_DTBO"
dd if="$CUR_DTBO" of="$TMP_DIR/dtbo.img" bs=1M 2>/dev/null || err "读取分区失败"

log "检查 dtbo 是否已包含 HMBIRD_GKI"
if grep -q 'HMBIRD_GKI' "$TMP_DIR/dtbo.img"; then
    log "已包含 HMBIRD_GKI，跳过刷写"
    exit 0
fi

# ========== 5. 解包 dtbo ==========
cd "$TMP_DIR"
log "解包 dtbo.img"
"$DTBO_TOOL" dump dtbo.img -b dtb >$LOGFILE 2>&1 || err "dtbo 解包失败"

log "转换 dtb 至 dts"
for dtb in dtb.*; do
    [ -f "$dtb" ] || continue
    "$DTC_TOOL" -I dtb -O dts -@ -o "dts.$dtb" "$dtb" >$LOGFILE 2>&1 || err "DTB 转 DTS 失败"
done

log "替换标识 HMBIRD_OGKI -> HMBIRD_GKI"
sed_modified=false
for dts in dts.dtb.*; do
    [ -f "$dts" ] || continue
    sed -i 's/HMBIRD_OGKI/HMBIRD_GKI/g' "$dts"
    grep -q 'HMBIRD_GKI' "$dts" && sed_modified=true
done
$sed_modified || err "关键字符串替换未生效"

log "DTS 转回 DTB"
for dts in dts.dtb.*; do
    [ -f "$dts" ] || continue
    "$DTC_TOOL" -I dts -O dtb -@ -o "${dts#dts.}" "$dts" >$LOGFILE 2>&1 || err "DTS 转 DTB 失败"
done

log "重组 dtbo_new.img"
"$DTBO_TOOL" create dtbo_new.img dtb.* >$LOGFILE 2>&1 || err "dtbo 重组失败"
log "新 dtbo 文件大小: $(du -h dtbo_new.img | cut -f1)"

# ========== 6. 校验分区函数 ==========
verify_partition() {
    local partition="$1"
    [ -b "$partition" ] || err "无法定位分区: $partition"
    log "验证分区可写性：[ $partition ]"
    dd if=/dev/zero of="$partition" bs=1 count=1 conv=notrunc 2>/dev/null || {
        log "警告：分区可能只读，尝试解除写保护..."
        blockdev --setrw "$partition" 2>/dev/null || err "分区写保护解除失败"
    }
}

# ========== 7. 还原目标槽位 dtbo ==========
log "还原目标槽位 $TGT_DTBO"
verify_partition "$TGT_DTBO"
dd if=dtbo.img of="$TGT_DTBO" bs=1M 2>/dev/null || err "还原分区失败"
sync

# ========== 8. 刷入当前槽位 dtbo ==========
log "刷入当前槽位 $CUR_DTBO"
verify_partition "$CUR_DTBO"
dd if=dtbo_new.img of="$CUR_DTBO" bs=1M 2>/dev/null || err "刷写分区失败"
sync

# ========== 9. 校验 ==========
log "校验刷写结果"
dd if="$CUR_DTBO" of=check.img bs=1M 2>/dev/null || err "校验提取失败"
if grep -q 'HMBIRD_GKI' check.img; then
    log "${G}刷写成功，已包含 HMBIRD_GKI${N}"
else
    err "刷写后未检测到 HMBIRD_GKI"
fi

log "${G}全部完成${N}"

exit 0
