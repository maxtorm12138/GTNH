#!/usr/bin/env bash
# 从 AdvancedBackups 差分备份恢复世界。恢复前请务必停止 Minecraft 服务器。
#
# 备份语义（differential）：*-full.zip 为完整快照；*-partial.zip 是在「当前链上最近一次 full」
# 的基础上只打包变动部分。恢复时先解压对应 full，再解压 partial 覆盖/合并即可，无需依次解压
# 中间多个 partial。
set -euo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-/data/backups}"
WORLD_PATH="${WORLD_PATH:-/data/save/GTNH-WORLD}"
RESTORE_TMP="${RESTORE_TMP:-/tmp/gtnh-restore.$$}"

die() { echo "[ERROR] $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: restore-backup.sh [选项]

  从 BACKUP_ROOT 下某一世界的 differential 备份中交互选择，并恢复到 WORLD_PATH。
  增量包 partial 表示相对最近一次 full 的变动；恢复增量时使用目录内最新 full + 最新 partial。

环境变量:
  BACKUP_ROOT   备份根目录 (默认: /data/backups)
  WORLD_PATH    要覆盖的存活档目录 (默认: /data/save/GTNH-WORLD，宿主机路径；
                若在容器内执行请设为 /data/GTNH-WORLD)
  RESTORE_TMP   解压临时目录 (默认: /tmp/gtnh-restore.<pid>)

选项:
  -h, --help    显示此说明
  -y, --yes     跳过最终确认（仍会提示停止服务器；慎用）
EOF
}

SKIP_FINAL_CONFIRM=false
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -y|--yes) SKIP_FINAL_CONFIRM=true; shift ;;
        *) die "未知参数: $1（使用 -h 查看帮助）" ;;
    esac
done

if [ ! -d "$BACKUP_ROOT" ]; then
    die "备份目录不存在: $BACKUP_ROOT"
fi
command -v unzip >/dev/null || die "未找到 unzip 命令，请先安装"

# 文件名示例：backup_2026-03-30_11-18-14-partial.zip、backup_2026-04-04_10-18-52-full.zip
# 排序键为去掉 -full / -partial 后的前缀（如 backup_2026-03-30_11-18-14），按字典序即时间序
list_backups_sorted_asc() {
    local diff_dir=$1
    local f base stamp
    shopt -s nullglob
    local zips=( "$diff_dir"/*.zip )
    shopt -u nullglob
    for f in "${zips[@]}"; do
        base=$(basename "$f" .zip)
        case "$base" in
            *-full)    stamp=${base%-full} ;;
            *-partial) stamp=${base%-partial} ;;
            *) continue ;;
        esac
        printf '%s\t%s\n' "$stamp" "$f"
    done | sort -t$'\t' -k1,1
}

# 将排序键或旧式纯数字时间戳转为可读时间
format_stamp_human() {
    local stamp=$1
    local human sec
    # backup_2026-03-30_11-18-14 -> 2026-03-30 11:18:14
    if [[ "$stamp" =~ ^backup_([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})$ ]]; then
        human="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}:${BASH_REMATCH[4]}"
    elif [[ "$stamp" =~ ^[0-9]{13}$ ]]; then
        sec=$((stamp / 1000))
        human=$(date -r "$sec" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || true
        [ -n "$human" ] || human=$(date -d "@$sec" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || true
        [ -n "$human" ] || human=$stamp
    elif [[ "$stamp" =~ ^[0-9]{10}$ ]]; then
        human=$(date -r "$stamp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || true
        [ -n "$human" ] || human=$(date -d "@$stamp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || true
        [ -n "$human" ] || human=$stamp
    else
        human=$stamp
    fi
    printf '%s' "$human"
}

# 增量恢复：只解压「最新 full + 最新 partial」——partial 为基于该链上 full 的差分，与 sync-backups 一致
# 全量恢复：仅解压所选的那一个 *-full.zip
# __INCREMENTAL_LATEST__：走上述两包
resolve_chain() {
    local diff_dir=$1
    local selected=$2
    local -a sorted=()
    local stamp f
    while IFS=$'\t' read -r stamp f; do
        [ -n "$f" ] || continue
        sorted+=("$f")
    done < <(list_backups_sorted_asc "$diff_dir")

    [ ${#sorted[@]} -eq 0 ] && die "在 $diff_dir 未找到 *-full.zip / *-partial.zip（例如 backup_YYYY-MM-DD_HH-MM-SS-full.zip）"

    if [ "$selected" = "__INCREMENTAL_LATEST__" ]; then
        local newest_full="" newest_partial="" b
        for f in "${sorted[@]}"; do
            b=$(basename "$f" .zip)
            [[ "$b" == *-full ]] && newest_full="$f"
            [[ "$b" == *-partial ]] && newest_partial="$f"
        done
        [ -n "$newest_full" ] || die "未找到 *-full.zip，无法做增量恢复"
        [ -n "$newest_partial" ] || die "未找到 *-partial.zip，无法做增量恢复"
        printf '%s\n' "$newest_full"
        printf '%s\n' "$newest_partial"
        return 0
    fi

    local base
    base=$(basename "$selected" .zip)
    if [[ "$base" == *-full ]]; then
        printf '%s\n' "$selected"
        return 0
    fi

    die "内部错误：未知的恢复选项"
}

pick_world() {
    local -a worlds=()
    local d
    for d in "$BACKUP_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -d "${d}differential" ] || continue
        worlds+=("$(basename "$d")")
    done
    [ ${#worlds[@]} -eq 0 ] && die "在 $BACKUP_ROOT 下未找到含 differential 子目录的世界"

    if [ ${#worlds[@]} -eq 1 ]; then
        printf '%s\n' "${worlds[0]}"
        return 0
    fi

    echo "请选择要恢复的世界：" >&2
    local i
    for i in "${!worlds[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${worlds[i]}" >&2
    done
    local choice
    while true; do
        read -r -p "输入序号 [1-${#worlds[@]}]: " choice || exit 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#worlds[@]} ]; then
            printf '%s\n' "${worlds[$((choice - 1))]}"
            return 0
        fi
        echo "无效输入，请重试。" >&2
    done
}

pick_backup() {
    local diff_dir=$1
    local -a sorted=()
    local stamp f
    while IFS=$'\t' read -r stamp f; do
        [ -n "$f" ] || continue
        sorted+=("$f")
    done < <(list_backups_sorted_asc "$diff_dir")

    [ ${#sorted[@]} -eq 0 ] && die "目录中无可用备份: $diff_dir"

    local -a full_paths=()
    local newest_full="" newest_partial="" b
    for f in "${sorted[@]}"; do
        b=$(basename "$f" .zip)
        [[ "$b" == *-full ]] && { full_paths+=("$f"); newest_full="$f"; }
        [[ "$b" == *-partial ]] && newest_partial="$f"
    done

    [ ${#full_paths[@]} -gt 0 ] || die "目录中无 *-full.zip，无法恢复"

    echo "" >&2
    echo "可选备份（全量：任选其一；增量：仅最新 full + 最新 partial，与同步脚本一致）：" >&2
    local i hstamp human
    for i in "${!full_paths[@]}"; do
        b=$(basename "${full_paths[i]}")
        hstamp=$(basename "$b" .zip)
        hstamp=${hstamp%-full}
        human=$(format_stamp_human "$hstamp")
        printf '  %2d) [全量] %s  (%s)\n' "$((i + 1))" "$b" "$human" >&2
    done

    local max_choice=${#full_paths[@]}
    if [ -n "$newest_partial" ]; then
        max_choice=$((max_choice + 1))
        local hf hp
        hf=$(basename "$newest_full")
        hp=$(basename "$newest_partial")
        printf '  %2d) [增量·最新] %s + %s\n' "$max_choice" "$hf" "$hp" >&2
    fi

    local choice
    while true; do
        read -r -p "输入要恢复的序号 [1-${max_choice}]: " choice || exit 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$max_choice" ]; then
            if [ -n "$newest_partial" ] && [ "$choice" -eq "$max_choice" ]; then
                printf '%s\n' "__INCREMENTAL_LATEST__"
            else
                printf '%s\n' "${full_paths[$((choice - 1))]}"
            fi
            return 0
        fi
        echo "无效输入，请重试。" >&2
    done
}

world=$(pick_world)
DIFF_DIR="$BACKUP_ROOT/$world/differential"
[ -d "$DIFF_DIR" ] || die "差分目录不存在: $DIFF_DIR"

selected=$(pick_backup "$DIFF_DIR")
CHAIN=()
while IFS= read -r line; do
    [ -n "$line" ] || continue
    CHAIN+=("$line")
done < <(resolve_chain "$DIFF_DIR" "$selected")

echo ""
echo "将按顺序解压以下 ${#CHAIN[@]} 个文件到临时目录，再替换存活档："
for _f in "${CHAIN[@]}"; do echo "  - $(basename "$_f")"; done
echo "  目标世界目录: $WORLD_PATH"
echo ""

if [ "$SKIP_FINAL_CONFIRM" != true ]; then
    read -r -p "确认已停止服务器，并继续恢复？[y/N] " ans || exit 1
    case "$ans" in
        [yY][eE][sS]|[yY]) ;;
        *) echo "已取消。"; exit 0 ;;
    esac
fi

rm -rf "$RESTORE_TMP"
mkdir -p "$RESTORE_TMP/extract"
for _f in "${CHAIN[@]}"; do
    echo "[UNZIP] $(basename "$_f")"
    unzip -o -q "$_f" -d "$RESTORE_TMP/extract"
done

ts=$(date +%Y%m%d%H%M%S)
if [ -d "$WORLD_PATH" ]; then
    backup_path="${WORLD_PATH}.pre-restore-${ts}"
    echo "[BACKUP] 将当前存档移至: $backup_path"
    mv "$WORLD_PATH" "$backup_path"
else
    echo "[INFO] 目标目录不存在，将新建: $WORLD_PATH"
fi

mkdir -p "$WORLD_PATH"
shopt -s dotglob
if [ -d "$RESTORE_TMP/extract/$world" ]; then
    echo "[RESTORE] 使用 zip 内子目录: $world"
    cp -a "$RESTORE_TMP/extract/$world"/. "$WORLD_PATH/"
else
    cp -a "$RESTORE_TMP/extract"/. "$WORLD_PATH/"
fi
shopt -u dotglob

rm -rf "$RESTORE_TMP"
echo ""
echo "[完成] 已从备份恢复至: $WORLD_PATH"
echo "请检查无误后再启动服务器。"
