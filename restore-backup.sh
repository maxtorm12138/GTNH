#!/usr/bin/env bash
# 从 AdvancedBackups 差分备份恢复世界。恢复前请务必停止 Minecraft 服务器。
#
# 语义与恢复步骤与上游一致（见 https://github.com/HeatherComputer/AdvancedBackups ）：
# - README「Backup Types」：differential 下 partial 仅含自上一次 *full* 以来变更的文件；incremental 才是基于上一档 partial。
# - 恢复逻辑同 core/.../cli/AdvancedBackupsCLI.java 的 restoreFullDifferential（非 restoreFullIncremental）：
#   选中 *-full 只还原该包；选中 *-partial 时，在时间降序列表中向更旧方向找到最近的 *-full*，
#   先还原该 full，再还原选中的 partial（与 CLI 在升序列表上从选中项向索引 0 扫描等价）。
set -euo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-/data/backups}"
WORLD_PATH="${WORLD_PATH:-/data/save/GTNH-WORLD}"
RESTORE_TMP="${RESTORE_TMP:-/tmp/gtnh-restore.$$}"
BACKUP_PAGE_SIZE="${BACKUP_PAGE_SIZE:-20}"

die() { echo "[ERROR] $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: restore-backup.sh [选项]

  从 BACKUP_ROOT 下某一世界的 differential 目录选择备份点，并恢复到 WORLD_PATH。
  行为对齐 AdvancedBackups CLI 的 differential 恢复；若配置为 incremental，请使用 mod 自带的 jar 内恢复工具（需按链依次还原）。

环境变量:
  BACKUP_ROOT   备份根目录 (默认: /data/backups)
  WORLD_PATH    要覆盖的存活档目录 (默认: /data/save/GTNH-WORLD，宿主机路径；
                若在容器内执行请设为 /data/GTNH-WORLD)
  RESTORE_TMP       解压临时目录 (默认: /tmp/gtnh-restore.<pid>)
  BACKUP_PAGE_SIZE  备份列表每页条数 (默认: 20)

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
# 排序键为去掉 -full / -partial 后的前缀；按字典序逆序 = 时间降序（最新在前）
list_backups_sorted_desc() {
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
    done | sort -t$'\t' -k1,1 -r
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

# 对齐 AdvancedBackupsCLI.restoreFullDifferential；列表按时间降序，故从选中 partial 向「更旧」方向（更大下标）找最近 full
resolve_chain() {
    local diff_dir=$1
    local selected=$2
    local -a sorted=()
    local stamp f
    while IFS=$'\t' read -r stamp f; do
        [ -n "$f" ] || continue
        sorted+=("$f")
    done < <(list_backups_sorted_desc "$diff_dir")

    [ ${#sorted[@]} -eq 0 ] && die "在 $diff_dir 未找到 *-full.zip / *-partial.zip（例如 backup_YYYY-MM-DD_HH-MM-SS-full.zip）"

    local i sel_idx=-1
    for i in "${!sorted[@]}"; do
        if [ "${sorted[$i]}" = "$selected" ]; then
            sel_idx=$i
            break
        fi
    done
    [ "$sel_idx" -ge 0 ] || die "所选文件不在备份列表中: $selected"

    local base
    base=$(basename "$selected" .zip)
    if [[ "$base" == *-full ]]; then
        printf '%s\n' "$selected"
        return 0
    fi

    local j name n=${#sorted[@]}
    for (( j = sel_idx + 1; j < n; j++ )); do
        name=$(basename "${sorted[j]}" .zip)
        if [[ "$name" == *-full ]]; then
            printf '%s\n' "${sorted[j]}"
            printf '%s\n' "$selected"
            return 0
        fi
    done
    die "在排序列表中，该 partial 之后（更旧方向）没有 *-full.zip（无法按 differential 规则恢复）: $selected"
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
    done < <(list_backups_sorted_desc "$diff_dir")

    [ ${#sorted[@]} -eq 0 ] && die "目录中无可用备份: $diff_dir"

    local total=${#sorted[@]}
    local page_size=$BACKUP_PAGE_SIZE
    [[ "$page_size" =~ ^[1-9][0-9]*$ ]] || page_size=20
    local max_page=$(( (total + page_size - 1) / page_size - 1 ))
    [ "$max_page" -lt 0 ] && max_page=0

    local page=0 start end i
    while true; do
        start=$((page * page_size))
        end=$((start + page_size - 1))
        [ "$end" -ge "$total" ] && end=$((total - 1))

        echo "" >&2
        echo "可选备份（按时间降序，序号越小越新；全局序号 1–${total}）： 第 $((page + 1))/$((max_page + 1)) 页" >&2
        local b hstamp human
        for (( i = start; i <= end; i++ )); do
            b=$(basename "${sorted[i]}")
            hstamp=$(basename "$b" .zip)
            hstamp=${hstamp%-full}
            hstamp=${hstamp%-partial}
            human=$(format_stamp_human "$hstamp")
            if [[ "$b" == *-full.zip ]]; then
                printf '  %2d) [full]  %s  (%s)\n' "$((i + 1))" "$b" "$human" >&2
            else
                printf '  %2d) [partial] %s  (%s)\n' "$((i + 1))" "$b" "$human" >&2
            fi
        done

        echo "" >&2
        if [ "$total" -le "$page_size" ]; then
            echo "输入全局序号 [1-${total}] 选择要恢复的备份。" >&2
        else
            echo "输入全局序号 [1-${total}] 选择；n 下一页；p 上一页" >&2
        fi
        local choice
        read -r -p "> " choice || exit 1
        choice=$(printf '%s' "$choice" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        case "$choice" in
            n|N)
                if [ "$page" -lt "$max_page" ]; then
                    page=$((page + 1))
                else
                    echo "[提示] 已是最后一页。" >&2
                fi
                ;;
            p|P)
                if [ "$page" -gt 0 ]; then
                    page=$((page - 1))
                else
                    echo "[提示] 已是第一页。" >&2
                fi
                ;;
            '')
                if [ "$total" -gt "$page_size" ]; then
                    if [ "$page" -lt "$max_page" ]; then
                        page=$((page + 1))
                    else
                        echo "[提示] 已是最后一页；请输入序号或 p。" >&2
                    fi
                else
                    echo "请输入序号 [1-${total}]。" >&2
                fi
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$total" ]; then
                    printf '%s\n' "${sorted[$((choice - 1))]}"
                    return 0
                fi
                echo "无效输入，请重试。" >&2
                ;;
        esac
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
