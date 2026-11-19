# dsh-pet 素材转码管线（WebM → iOS 透明序列帧）

面向 iOS 越狱 tweak（SpringBoard 桌面悬浮播放），把 dsh-pet 的 VP9-alpha WebM 动画转成透明 PNG/WebP 序列帧。工具在 `tools/transcode-webm/`，详见该目录 README.md。

## 核心结论（关键，勿踩坑）

- dsh-pet 的 webm 透明通道在 VP9 alpha 扩展里：背景 alpha=1/255、角色 alpha=255（源码 runtime/electron-helper/index.html 的 SVG feFuncA intercept=-0.0039 即为此修正）。
- ffmpeg 默认 vp9 解码器**丢失** alpha 平面（解出全不透明）。**必须 `-c:v libvpx-vp9`**（本机 ffmpeg 8.1.1 Gyan 构建带 libvpx-vp9 + libwebp，已验证）。
- 脚本默认 `lutyuv=a='clip(val-1,0,255)'` 把 alpha=1 的背景精确归零，等价原项目滤镜。

## 转码约定

- 源：dsh-pet `assets/webm/*.webm`（实测 114 个，中文文件名，如 待机呼吸休闲.webm、点击回应-开心跃动.webm、被鼠标拖拽悬空反馈.webm）。
- 命令：`SRC_DIR=<webm目录> OUT_ROOT=<输出目录> bash tools/transcode-webm/transcode.sh [动画名...]`；可调 FPS/SCALE/FORMAT/WEBP_Q/KEEP_FRAMES/STRICT_ALPHA。
- 产出目录：`<OUT_ROOT>/<动画名>/frames/frame_%05d.webp`（或 .png）+ 同级 `anim.json`（frameCount/fps/width/duration/framePattern）。动画名 = webm 文件名去扩展，中文原样。
- 总清单：`python tools/transcode-webm/manifest.py <OUT_ROOT>` 生成 `manifest.json`，结构 `{version:1, animations:{动画名:{format,fps,frameCount,frameDir,framePattern,...}}}`。tweak 据此按名取帧。
- 命名映射对齐 dsh-pet config.jsonc：idle=待机呼吸休闲、turn=东张西望、drag=被鼠标拖拽悬空反馈、clicks=点击回应-*。

## iOS 端加载

原生 tweak 不走 WKWebView，直接用序列帧：YYImage（推荐，支持 WebP alpha、内存好，需链 libwebp）；或 CAKeyframeAnimation + LRU 帧缓存（首版拖拽/点击同步方便）；UIImage animatedImage 最简但全帧驻内存、仅适合小动画。首版建议 FPS=12~24、SCALE=160~320 控制体积，资源随 deb 打到 /Library/Application Support/。

## 实测验证

待机呼吸休闲.webm（VP9/640x360/24fps/10.04s）经脚本 FPS=6 SCALE=160 转出 60 帧 WebP + anim.json；默认解码 alpha 全 255，libvpx-vp9 解码背景 alpha=1/中心 255；输出 WebP 解码 pix_fmt=yuva420p、约 11660/14400 像素 alpha=0；manifest.py 中文名 JSON 输出正常。全部在本机 Windows（Git Bash + winget ffmpeg）跑通。
