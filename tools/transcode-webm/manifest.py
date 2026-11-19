# -*- coding: utf-8 -*-
"""manifest.py — 为 tweak 生成动画清单 JSON。

扫描 OUT_ROOT/<动画名>/ 下的 anim.json 与 frames/ 目录，生成 manifest.json：
  {"version": 1, "animations": {"待机呼吸休闲": {"format": "webp",
  "frameCount": 240, "fps": 24, "framePattern": "frame_%05d.webp", ...}, ...}}

用法: python manifest.py <OUT_ROOT> [-o manifest.json]
"""
import sys, json, os, argparse

def build(root):
    animations = {}
    for name in sorted(os.listdir(root)):
        anim_dir = os.path.join(root, name)
        if not os.path.isdir(anim_dir):
            continue
        meta_path = os.path.join(anim_dir, "anim.json")
        frames_dir = os.path.join(anim_dir, "frames")
        if not os.path.isfile(meta_path) or not os.path.isdir(frames_dir):
            continue
        with open(meta_path, "r", encoding="utf-8") as f:
            meta = json.load(f)
        fmt = meta.get("format", "webp")
        frames = sorted(x for x in os.listdir(frames_dir)
                        if x.startswith("frame_") and x.endswith("." + fmt))
        animations[name] = {
            "format": fmt,
            "fps": meta.get("fps", 24),
            "frameCount": len(frames) if frames else meta.get("frameCount", 0),
            "duration": meta.get("duration"),
            "width": meta.get("width"),
            "height": meta.get("height"),
            "framePattern": meta.get("framePattern", "frame_%05d." + fmt),
            "frameDir": "frames",
        }
    return {"version": 1, "animations": animations}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root", help="transcode 输出根目录")
    ap.add_argument("-o", "--output", default=None, help="输出 JSON 路径(默认 <root>/manifest.json)")
    args = ap.parse_args()
    manifest = build(args.root)
    out = args.output or os.path.join(args.root, "manifest.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    print("wrote %s (%d animations)" % (out, len(manifest["animations"])))

if __name__ == "__main__":
    main()
