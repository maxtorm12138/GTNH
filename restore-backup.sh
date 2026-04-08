#!/usr/bin/env bash
# 从 AdvancedBackups 差分备份恢复世界。恢复前请务必停止 Minecraft 服务器。
set -euo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-/data/backups}"
WORLD_PATH="${WORLD_PATH:-/data/save/GTNH-WORLD}"
RESTORE_TMP="${RESTORE_TMP:-/tmp/gtnh-restore.$$}"

die() { echo "[ERROR] $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: restore-backup.sh [选项]

  从 BACKUP_ROOT 下某一世界的 differential 备份中交互选择时间点，并恢复到 WORLD_PATH。

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

# 解析从链起点到选中文件（含）需依次解压的 zip 列表
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

    local i sel_idx=-1
    for i in "${!sorted[@]}"; do
        if [ "${sorted[$i]}" = "$selected" ]; then
            sel_idx=$i
            break
        fi
    done
    [ "$sel_idx" -ge 0 ] || die "所选文件不在备份列表中: $selected"

    local base name
    base=$(basename "$selected" .zip)
    if [[ "$base" == *-full ]]; then
        printf '%s\n' "$selected"
        return 0
    fi

    local j
    for (( j = sel_idx; j >= 0; j-- )); do
        name=$(basename "${sorted[j]}" .zip)
        if [[ "$name" == *-full ]]; then
            local k
            for (( k = j; k <= sel_idx; k++ )); do
                printf '%s\n' "${sorted[k]}"
            done
            return 0
        fi
    done
    die "未找到与所选 partial 对应的全量备份（*-full.zip）: $selected"
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

    echo "" >&2
    echo "可选备份（按时间先后排序，序号越大通常越新）：" >&2
    local i b stamp human
    for i in "${!sorted[@]}"; do
        b=$(basename "${sorted[i]}")
        stamp=$(basename "$b" .zip)
        stamp=${stamp%-full}
        stamp=${stamp%-partial}
        human=$(format_stamp_human "$stamp")
        if [[ "$b" == *-full.zip ]]; then
            printf '  %2d) [全量] %s  (%s)\n' "$((i + 1))" "$b" "$human" >&2
        else
            printf '  %2d) [增量] %s  (%s)\n' "$((i + 1))" "$b" "$human" >&2
        fi
    done

    local choice
    while true; do
        read -r -p "输入要恢复的序号 [1-${#sorted[@]}]: " choice || exit 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#sorted[@]} ]; then
            printf '%s\n' "${sorted[$((choice - 1))]}"
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
