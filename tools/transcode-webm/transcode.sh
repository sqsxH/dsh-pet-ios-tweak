#!/usr/bin/env bash
# transcode.sh — 批量把 dsh-pet 的 VP9-alpha WebM 转成 iOS 可用透明序列帧
# 关键: 必须用 -c:v libvpx-vp9 解码, 默认 vp9 解码器会丢失 alpha 平面!
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# 目录约定(可用环境变量覆盖)
SRC_DIR="${SRC_DIR:-}"
OUT_ROOT="${OUT_ROOT:-}"
FPS="${FPS:-24}"            # 目标帧率; 12~24 均可, 越低体积越小
SCALE="${SCALE:-320}"       # 目标宽度(px), -1 表示保持原始; 高度按比例
FORMAT="${FORMAT:-webp}"    # webp | png
WEBP_Q="${WEBP_Q:-80}"      # WebP 质量 0-100
KEEP_FRAMES="${KEEP_FRAMES:-1}"  # 1=保留中间 PNG 帧, 0=转 WebP 后删除
STRICT_ALPHA="${STRICT_ALPHA:-1}" # 1=应用 -1 修正背景 alpha (匹配 dsh-pet SVG 滤镜)

usage() {
  sed -n '2,20p' "$0" | sed -E 's/^# ?//'
  echo "用法:"
  echo "  SRC_DIR=/path/to/webm OUT_ROOT=/path/to/out ./transcode.sh [动画名 ...]"
  echo "  不带参数则转换 SRC_DIR 下全部 .webm"
  echo "环境变量: SRC_DIR OUT_ROOT FPS SCALE FORMAT(webp|png) WEBP_Q KEEP_FRAMES STRICT_ALPHA"
  echo "注意: 必须用 bash 执行 (Git Bash / WSL / MSYS2), 不要在 cmd 里跑。"
}
[ "${1:-}" = "--help" ] && { usage; exit 0; }

# 定位 ffmpeg/ffprobe: 优先 PATH, 其次常见 winget 安装位置
find_bin() {
  local name="$1" p
  if p="$(command -v "$name" 2>/dev/null)"; then echo "$p"; return; fi
  for p in "$LOCALAPPDATA/Microsoft/WinGet/Links/$name.exe"            "/c/Users/$USER/AppData/Local/Microsoft/WinGet/Links/$name.exe"; do
    [ -x "$p" ] && { echo "$p"; return; }
  done
  echo "错误: 找不到 $name, 请先安装并加入 PATH (见 README)" >&2
  exit 1
}
FFMPEG="${FFMPEG:-$(find_bin ffmpeg)}"
FFPROBE="${FFPROBE:-$(find_bin ffprobe)}"

if [ -z "$SRC_DIR" ] || [ -z "$OUT_ROOT" ]; then
  echo "错误: 必须设置 SRC_DIR 和 OUT_ROOT" >&2; usage >&2; exit 1
fi
[ -d "$SRC_DIR" ] || { echo "错误: 源目录不存在: $SRC_DIR" >&2; exit 1; }
mkdir -p "$OUT_ROOT"

# 若 SCALE=-1 则用源分辨率(逐文件在循环里探测)
scale_filter() {
  local infile="$1"
  if [ "$SCALE" = "-1" ]; then
    local w="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 -- "$infile")"
    echo "$w"
  else
    echo "$SCALE"
  fi
}

transcode_one() {
  local infile="$1"
  local base="$(basename -- "$infile")"
  local name="${base%.*}"                       # 中文文件名原样保留
  local anim_dir="$OUT_ROOT/$name"
  local frames_dir="$anim_dir/frames"
  mkdir -p "$frames_dir"

  local w="$(scale_filter "$infile")"
  local vf="select=gte(t\,0),fps=$FPS,scale=$w:-2:flags=lanczos,format=yuva420p"
  # dsh-pet 的 webm 背景 alpha 恒为 1/255; 与 SVG feFuncA intercept=-0.0039 一致, 精确归零
  [ "$STRICT_ALPHA" = "1" ] && vf="$vf,lutyuv=a='clip(val-1,0,255)'"

  echo "==> [$name] -> $frames_dir (fps=$FPS, width=$w, fmt=$FORMAT)"
  # 关键: -c:v libvpx-vp9 才会输出 alpha 平面; 默认解码器会丢掉它
  "$FFMPEG" -nostdin -y -hide_banner -loglevel error \
    -c:v libvpx-vp9 -i "$infile" \
    -vf "$vf" -vsync 0 -pix_fmt rgba \
    "$frames_dir/frame_%05d.png"

  local count="$(find "$frames_dir" -maxdepth 1 -name 'frame_*.png' | wc -l | tr -d ' ')"
  [ "$count" -gt 0 ] || { echo "错误: $name 未产出帧" >&2; return 1; }

  # anim.json: 供 tweak 读取的动画元数据
  local duration="$(awk -v n="$count" -v f="$FPS" 'BEGIN{printf "%.4f", n/f}')"
  cat > "$anim_dir/anim.json" <<EOF
{
  "name": "$name",
  "format": "$FORMAT",
  "frameCount": $count,
  "fps": $FPS,
  "width": $w,
  "duration": $duration,
  "firstFrame": "frame_00001",
  "framePattern": "frame_%05d.$FORMAT"
}
EOF

  # WebP 编码(无损 alpha, libwebp)
  if [ "$FORMAT" = "webp" ]; then
    "$FFMPEG" -nostdin -y -hide_banner -loglevel error \
      -framerate "$FPS" -i "$frames_dir/frame_%05d.png" \
      -c:v libwebp -quality "$WEBP_Q" -pix_fmt rgba -loop 0 \
      "$frames_dir/frame_%05d.webp"
    if [ "$KEEP_FRAMES" = "0" ]; then
      find "$frames_dir" -maxdepth 1 -name 'frame_*.png' -delete
    fi
  fi
}

# 选文件: 参数指定动画名(不含扩展名)或全部
declare -a files
if [ "$#" -eq 0 ]; then
  while IFS= read -r -d '' f; do files+=("$f"); done < <(find "$SRC_DIR" -maxdepth 1 -type f -iname '*.webm' -print0)
else
  for name in "$@"; do
    f="$SRC_DIR/$name.webm"
    [ -f "$f" ] || { echo "错误: 找不到 $f" >&2; exit 1; }
    files+=("$f")
  done
fi

[ "${#files[@]}" -gt 0 ] || { echo "没有找到任何 .webm 文件" >&2; exit 1; }

for f in "${files[@]}"; do
  transcode_one "$f"
done

echo "全部完成: $OUT_ROOT"
