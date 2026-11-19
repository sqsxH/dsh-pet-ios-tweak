# WebM → iOS 透明序列帧转码工具

把 dsh-pet 的 `assets/webm/*.webm`（VP9-alpha 透明动画）批量转成 iOS tweak 可直接加载的透明序列帧（WebP 或 PNG），并生成动画清单 `manifest.json`。

## 为什么需要这个工具

dsh-pet 的 WebM 用 VP9 的 alpha 扩展存透明通道：背景帧 alpha=1/255（≈透明），角色 alpha=255（不透明）。两点必须注意：

1. **ffmpeg 默认 vp9 解码器会丢弃 alpha 平面**，解出来全不透明（alpha=255）。必须显式指定 `-c:v libvpx-vp9` 才能正确解出 alpha（实测：背景 alpha=1，角色 alpha=255）。
2. 解出的 alpha=1/255 背景与 dsh-pet 原 Electron 端 SVG 滤镜（feFuncA intercept=-0.0039215686，即 alpha 减 1）语义一致。脚本默认用 lutyuv 的 a=clip(val-1,0,255) 把它精确归零。

## 安装 ffmpeg

- Windows (winget，已在本机验证)：`winget install Gyan.FFmpeg`；装完确认 `ffmpeg -version`（本机 8.1.1-full_build-www.gyan.dev，含 libwebp/libvpx-vp9）。脚本会自动在 LOCALAPPDATA 下的 Microsoft/WinGet/Links 目录找 ffmpeg.exe，也可自己加 PATH 或用 FFMPEG 环境变量指定。
- WSL2：`sudo apt update && sudo apt install -y ffmpeg`（Ubuntu 22.04+ 自带 libwebp/libvpx-vp9），注意 WSL 需先 `wsl --install` 并重启。
- Bash 环境：脚本需在 bash 下运行（Git Bash / WSL / MSYS2）。本机可用 D 盘 Git 安装目录下的 bin/bash.exe。

## 用法

```bash
# 全部 114 个动画（示例路径，按你的实际路径改）
export SRC_DIR='C:/Users/ASUS/.dsh/profiles/desktop/node_modules/dsh-pet/assets/webm'
export OUT_ROOT='C:/path/to/pet-assets'
bash tools/transcode-webm/transcode.sh

# 只转指定动画（中文名原样传入，无需转义）
bash tools/transcode-webm/transcode.sh 待机呼吸休闲 点击回应-开心跃动

# 生成 tweak 读取的清单
python tools/transcode-webm/manifest.py "$OUT_ROOT"
```

可调环境变量：FPS（默认 24）、SCALE（默认 320px 宽，-1 保原尺寸）、FORMAT（webp/png）、WEBP_Q（0-100）、KEEP_FRAMES（0=删中间 PNG 只留 webp）、STRICT_ALPHA（1=背景 alpha 减 1 归零）、FFMPEG/FFPROBE（自定义路径）。

## 目录约定

```
OUT_ROOT/
|- manifest.json                 # 总清单: 动画名 -> 元信息
|- 待机呼吸休闲/
|   |- anim.json                 # 单动画元数据
|   `- frames/
|       |- frame_00001.webp
|       `- ...
`- 点击回应-开心跃动/
    `- ...
```

动画目录名就是 webm 文件名（中文原样），与 dsh-pet config.jsonc 的 animations 配置名一致（idle=待机呼吸休闲、turn=东张西望、drag=被鼠标拖拽悬空反馈、clicks=点击回应-*）。tweak 读 manifest.json 的 animations[名称] 得到 frameDir/framePattern/fps/frameCount 即可定位帧。

## iOS 端加载建议（原生 tweak，非 WKWebView）

- YYImage（推荐）：YYImage / YYAnimatedImageView 原生支持 WebP 序列与逐帧 alpha，内存表现好，支持设置播放速率与循环次数。集成时需把 libwebp 链入 tweak。
- UIImage 序列：UIImage animatedImageWithImages:duration: 最简单，但会把全部帧解码进内存；114 个动画、每动画 200+ 帧时内存压力大，建议只在低频小动画用，或降 SCALE/FPS。
- CAKeyframeAnimation：把每帧 CGImage 作为 keyframe 喂给 CALayer.contents，可控性强、可与拖拽手势同步，但要自己管帧缓存与内存。首版悬浮+动画+拖拽+点击建议用此方案配合 LRU 帧缓存，避免 OOM。
- 首版为控制体积：建议 FPS=12~24、SCALE=160~320。成品把整个 OUT_ROOT 作为资源打进 deb 的 /Library/Application Support/ 路径。

## 验证记录（本机实测）

- 源文件 待机呼吸休闲.webm：VP9 Profile 0, 640x360, 24fps, 10.042s。
- 默认解码 alpha 全 255（丢失透明）；-c:v libvpx-vp9 解出背景 alpha=1、中心 alpha=255，与 dsh-pet index.html 描述吻合。
- 脚本跑 FPS=6 SCALE=160 FORMAT=webp 产出 60 帧 + anim.json；WebP 解码后 pix_fmt=yuva420p，约 11660/14400 像素 alpha=0（背景透明）。
- manifest.py 正确输出中文动画名的 JSON（ensure_ascii=False）。