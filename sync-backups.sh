#!/usr/bin/env bash
set -euo pipefail

SRC="/data/backups"
DST="/tmp/gtnh-backup-stag"

if [ ! -d "$SRC" ]; then
    echo "[ERROR] Source directory not found: $SRC"
    exit 1
fi

copied=0
skipped=0
errors=0

for world_dir in "$SRC"/*/; do
    [ -d "$world_dir" ] || continue
    world_name=$(basename "$world_dir")

    diff_dir="$world_dir/differential"
    if [ ! -d "$diff_dir" ]; then
        echo "[WARN] No differential directory for $world_name, skipping"
        continue
    fi

    echo "=== Processing world: $world_name ==="

    # 获取所有备份文件并按时间排序（最新的在前）
    all_files=$(ls -1 "$diff_dir"/*.zip 2>/dev/null | sort -r || true)
    
    if [ -z "$all_files" ]; then
        echo "  [WARN] No zip files found in $diff_dir"
        continue
    fi
    
    # 找最新的文件
    latest=$(echo "$all_files" | head -n1)
    latest_basename=$(basename "$latest")
    
    # 判断最新文件类型
    if [[ "$latest_basename" == *-partial.zip ]]; then
        # 最新是 partial，需要找到对应的 full 一起同步
        # 提取时间戳（假设文件名格式为: 时间戳-suffix.zip）
        latest_time=$(echo "$latest_basename" | sed 's/-partial\.zip$//')
        
        # 找该 partial 对应的 full（往前找最近的 full）
        target_full=$(echo "$all_files" | grep -- "-full\.zip$" | head -n1 || true)
        
        files_to_sync=()
        if [ -n "$target_full" ]; then
            files_to_sync+=("$target_full")
        fi
        files_to_sync+=("$latest")
        
        echo "  [INFO] Latest is partial, syncing with corresponding full"
    else
        # 最新是 full，只同步这个 full
        files_to_sync=("$latest")
        echo "  [INFO] Latest is full, syncing only full"
    fi
    
    # 同步选中的文件
    for src_file in "${files_to_sync[@]}"; do
        filename=$(basename "$src_file")
        src_size=$(stat -c%s "$src_file")
        dst_dir="$DST/$world_name"
        dst_file="$dst_dir/$filename"

        mkdir -p "$dst_dir"

        if [ -f "$dst_file" ]; then
            dst_size=$(stat -c%s "$dst_file")
            if [ "$src_size" -eq "$dst_size" ]; then
                echo "  [SKIP] Already up-to-date: $filename ($(numfmt --to=iec "$src_size"))"
                skipped=$((skipped + 1))
                continue
            fi
        fi

        echo "  [COPY] $filename ($(numfmt --to=iec "$src_size"))"
        if cp "$src_file" "$dst_file"; then
            copied=$((copied + 1))
        else
            echo "  [ERROR] Failed to copy $filename"
            errors=$((errors + 1))
        fi
    done
done

echo ""
echo "=== Summary ==="
echo "  Copied:  $copied"
echo "  Skipped: $skipped"
echo "  Errors:  $errors"

COS_BUCKET="cos://gtnh-backup-1251522369"
COS_REGION="ap-nanjing"
COS_PATH="/"

echo ""
echo "=== Uploading to Tencent COS ==="
coscli sync "$DST" "${COS_BUCKET}${COS_PATH}" -r -e "cos.${COS_REGION}.myqcloud.com" --disable-log
echo "[DONE] COS upload complete"

MAX_PARTIAL=8
MAX_FULL=3

echo ""
echo "=== Purging old backups on COS ==="
COS_ENDPOINT="cos.${COS_REGION}.myqcloud.com"
for world_dir in "$SRC"/*/; do
    [ -d "$world_dir" ] || continue
    world_name=$(basename "$world_dir")
    cos_prefix="${COS_BUCKET}${COS_PATH}${world_name}/"

    all_files=$(coscli ls "${cos_prefix}" -e "$COS_ENDPOINT" --disable-log 2>/dev/null \
        | awk -F'|' 'NR>2 {gsub(/^[ \t]+|[ \t]+$/, "", $1); if ($1 ~ /\.zip$/) print $1}')

    for suffix in partial full; do
        if [ "$suffix" = "partial" ]; then
            max=$MAX_PARTIAL
        else
            max=$MAX_FULL
        fi

        files=$(echo "$all_files" | grep -- "-${suffix}\\.zip\$" | sort -r || true)
        count=$(echo "$files" | grep -c . || true)

        if [ "$count" -le "$max" ]; then
            echo "  [OK] $world_name: $count ${suffix}(s), within limit ($max)"
            continue
        fi

        to_delete=$(echo "$files" | tail -n +"$((max + 1))")
        del_count=$(echo "$to_delete" | grep -c . || true)
        echo "  [PURGE] $world_name: $count ${suffix}s, removing $del_count oldest (keep $max)"

        while IFS= read -r obj; do
            [ -z "$obj" ] && continue
            echo "    Deleting: $obj"
            coscli rm "${COS_BUCKET}/${obj}" -e "$COS_ENDPOINT" --disable-log
        done <<< "$to_delete"
    done
done
echo "[DONE] Purge complete"

echo ""
echo "=== Cleaning up local staging ==="
rm -rf "$DST"
echo "[DONE] Removed $DST"
