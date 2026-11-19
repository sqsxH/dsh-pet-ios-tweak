# dsh-pet 核心行为移植规格（iOS 越狱 tweak 首版）

> 目标：把 dsh-pet（大肥鱼桌宠）的首版核心行为照搬到 Objective-C tweak，在 SpringBoard 桌面悬浮播放动画。首版只做 **桌面悬浮 + 动画播放 + 拖拽 + 点击**。
> 本文所有数值、规则、分支顺序均来自本机 npm 包源码（`C:/Users/ASUS/.dsh/profiles/desktop/node_modules/dsh-pet/`），路径与行号附在条目后，可直接核对。ObjC 命名/代码为落地建议，行为以源码为准。

---

## 0. 范围、证据与两个必须先接受的现实

1. **证据来源**（关键文件，均已逐行读过）：`src/client/pet/animation/animation.ts`（296 行，A/B 双缓冲换源）；`src/client/pet/animation/{assets,asset-loader,cues,next-animation,media}.ts`；`src/client/pet/card/{animation,animation-flow,state,sleep-machine}.ts`；`src/client/pet/motion/{drag,drag-follow,drag-release,geometry,walk,move-action}.ts`；`src/shared/{constants,pickers,types}.ts`、`src/shared/physics/{constants,release,throw,contact,squash}.ts`；`src/host/routes/assets.ts`、`assets/config.jsonc`、`src/runtime/electron-helper/sprite.js`、`src/client/pet/{css,click-sound,timings}.ts`。
2. **素材现实（已由集成者复核更正）**：本机 npm 包内 `assets/webm` **实际存在 114 个 webm 文件**（如 `三球抛接.webm` 549KB、`东张西望.webm` 427KB），直接用 `Get-ChildItem` 可见。此前「glob 计数 0」是 glob 工具 path 参数误用导致的误判，不是真的空目录。可直接用这批 webm 做转码。另一个事实仍成立：host 路由 `src/host/routes/assets.ts:22-26,146-155` 中 mov（HEVC-with-alpha）不随包发布、缺失时退回 webm——但那针对 H5/WKWebView 运行时；本项目是**原生 tweak**，不经过 Safari/WKWebView，而是把 webm 的 VP9-alpha **离线转成 PNG/WebP 序列帧**由原生解码，故 webm 素材充分可用（见 `docs/asset-pipeline.md`）。
3. **格式现实**：`src/shared/constants.ts:74-78` 中 `ANIMATION_EXT='.webm'`（VP9-alpha）；`src/client/pet/animation/media.ts` 的 `prefersMov()` 对 iPhone/iPad/iPod 返回 true，`thumbExt()` 因此选 `.mov`。Safari/WKWebView 会把 webm 的 alpha 丢掉渲染成黑底。tweak 侧固定用 .mov + alpha，别走 webm 兼容分支，也别用 `PET_ALPHA_FIX_ENABLED=false` 相关的 1/255 滤镜。
4. **平台映射边界**：`runtime/electron-helper/sprite.js` 是 Electron 窗口管理实现（fit/offset/多屏）。SpringBoard tweak 不需要窗口 fit/offset，只借它的**几何与命中区换算**；位置直接是浮层 view 的 frame.origin。

---

## 1. Web 模块 → ObjC 职责映射表

| dsh-pet 源码模块 | 移植到 ObjC 的类/职责 |
|---|---|
| `animation/animation.ts` createOwnAnimation | `PetAnimationController`：A/B 双缓冲换源、异步加载、代号防旧帧、播放/冻结/ended 回调 |
| `animation/assets.ts` + `host/routes/assets.ts` | `PetAssetResolver`：动画名 → 本地 .mov URL（专属目录优先/回退规则） |
| `animation/cues.ts` + `next-animation.ts` + `shared/pickers.ts` | `PetAnimationFlow`：随机链掷骰、ended 决策、权重与 noMirror 过滤 |
| `card/state.ts` | `PetState`：`anim / once / seq / cuePlayback / facing` |
| `motion/drag.ts` | `PetDragHandler`：按压阈值、弹簧目标、松手结算、点击判定 |
| `motion/drag-follow.ts` | 弹簧追随（CADisplayLink；SPRING_K=200/SPRING_C=30） |
| `motion/drag-release.ts` + `shared/physics/release.ts` | 轨迹采样、甩抛初速、弹弓速度/拉距换算 |
| `motion/geometry.ts` + `sprite.js` | `PetGeometry`：尺寸度量、命中矩形、可达边界裁剪、归一化坐标 |
| `shared/physics/{throw,contact,squash}.ts` | 抛掷积分/反弹/落地挤压（首版可选） |
| `card/{animation,animation-flow,sleep-machine}.ts` | 首版裁剪为 idle / drag / clicks / turn 四类 + ended 决策 |
| `card/view.ts` + `css.ts` | 透明浮层 UIView + 两个 AVPlayerLayer（A/B）+ 命中子 view + 可选 tip |

**状态放在哪**：`PetState` 用 ObjC 属性，`anim/once/seq/facing` 主线程读写；异步代号用 `NSUInteger generation`，每次 `switchTo` 自增，异步完成回主线程比对代号，不等就丢弃（源码 `pending.gen !== swapGen`）。

---

## 2. 关键常量速查（全部来自源码，数值勿随意改）

| 常量 | 值 | 来源 |
|---|---|---|
| CANVAS_H / FEET_Y | 360 / 330 | `shared/constants.ts:8,10` |
| HIT_BOX（640×360 画布） | `{x0:200,y0:50,x1:440,y1:335}` | `shared/constants.ts:12` |
| DRAG_THRESHOLD | 5 pt | `shared/constants.ts:14` |
| MIN_REACHABLE_PX | 24 pt | `shared/constants.ts:17` |
| SLINGSHOT_DOUBLE_MS | 200 ms | `shared/constants.ts:20` |
| PET_REF_WIDTH | 462 pt（minDist/maxDist 缩放基准） | `shared/constants.ts:23` |
| JUST_DRAGGED_MS | 100 ms（松手后视为同一次拖拽尾巴） | `motion/drag.ts:146` |
| LONG_PRESS_MS / SLOP_PX | 500 ms / 8 pt | `motion/touch-press.ts` |
| animationWeights | idle=10, turn=5, move=5（余 80 给 categories） | `assets/config.jsonc:440-444` |
| 分类权重 | 小动作20 玩耍20 吃什么16 时节14 文字10(noMirror) | `assets/config.jsonc:334-360` |
| ASSET_FETCH_TIMEOUT_MS | 10000 ms | `animation/animation.ts` |
| SPRING_K / SPRING_C | 200 / 30（ζ≈1.06 过阻尼） | `shared/physics/constants.ts` |
| TRAIL_KEEP_MS | 200 ms | 同上 |
| RELEASE_WINDOW_MS / RELEASE_STALE_MS | 150 / 150 ms | 同上 |
| DEAD_ZONE_SPEED / MAX_THROW_SPEED | 500 / 3600 pt/s | 同上 |
| softClamp(s) | 3600*(1-exp(-s/3600)) | `shared/physics/release.ts` |
| THROW_SPEED_ANCHOR / SLINGSHOT_REF_RATIO | 1200 / 0.6 | `shared/physics/constants.ts` |
| GRAVITY / RESTITUTION / GROUND_FRICTION | 1400 / 0.78 / 2.5 | `DEFAULT_PHYSICS` |
| REST_NORMAL / REST_TANGENT / REST_NORMAL_EPS | 40 / 15 / 1 pt/s | `contact.ts` |
| SQ_DURATION_MS / SQ_SQUASH / SQ_SOFT / SQ_HARD / SQ_MAX | 220 / 0.55 / 300 / 1500 / 0.55 | `shared/physics/{constants,squash}.ts` |
| BUBBLE_DURATION_MS / STATE_WAIT_MS | 10000 / 1000 | `client/pet/timings.ts` |
| click sound | `sound/click-duck.wav`, volume 0.5, throttle 100ms | `client/pet/click-sound.ts` |

**几何派生**（`motion/geometry.ts` derivePetMetrics）：
```text
size      = pet.size                          // 画框宽度
height    = size * 9 / 16
halfW     = size / 2
halfH     = height / 2
bottomPad = size * (9/16) * (360-330)/360      // 脚垫，stage 上移量
sideAllow = (200/640) * size                   // 身体两侧透明边
```

**命中区换算**（把 640×360 画布的 HIT_BOX 映射到实际画框；`PET_HIT_STYLE` 与 `sprite.js`）：
```text
hitRect.x      = (200/640) * size              = size * 0.3125
hitRect.y      = bottomPad + (50/360) * height = bottomPad + height * 0.1389
hitRect.width  = (240/640) * size              = size * 0.375
hitRect.height = (285/360) * height            = height * 0.7917
```
UIKit 落地：透明视频 layer 的 alpha 像素不参与 hitTest，必须单独放一个与 hitRect 等大的透明 `UIView` 收手势；不要把整个画框当点击区。

---

## 3. 动画播放与调度规格

### 3.1 换源引擎（A/B 双缓冲）——`animation/animation.ts`

源码要点：两个容器（`videoA`/`videoB`，`front` 标记前台）；新动画先加载进**后台槽**，加载完成后一次性切前台并播放，避免直接改 src 的黑帧/闪断。

伪代码（ObjC 语义等价）：
```text
switchTo(nextName, once, cueId):
  if cueId != nil:  pendingCue = nil; cueUrl = takeAssetURL(cueId)  // clearCuePlayback，一次性
  if nextName == '': return
  if pending != nil && pending.anim == nextName && pending.once == once:
     emitPlayingReceipt(); return                 // 防重：只补回执，不再换源
  target = (front == 0) ? 1 : 0
  gen += 1                                         // 只增：旧异步完成一律作废
  pending = { anim: nextName, once: once, gen: gen }
  layer[target].loop = !once                       // once=false 循环；once=true 挂 ended
  layer[target].muted = true
  url = cueUrl ?? assetResolver.url(for: nextName)
  loadAsync(url, timeout: 10s):                    // 一次取完整文件，避免流式 stall
     onError(reason):  if stale(gen) return; emitFailed(reason); pending = nil
     onReady:
        if !mounted || stale(gen): releaseLoadedAsset(); return
        releaseLoadedAssetOfFront()
        front = target; pending = nil
        if facing == right: applyTransform(scaleX:-1)
        play() → emitPlaying(); 失败 emitFailed('play-rejected')
```

关键不变量：
- **代号防旧帧**：`pending.gen !== swapGen` 的回调全部丢弃（`onObjectUrl` 与 `loadeddata` 两处校验）。
- **once 决定 ended**：只有 once=true 挂 ended 回调；once=false（循环）不触发 ended，靠外部事件打断。
- **冻结**：`setFrozen(true)` → pause 前台 + 上报 cancelled(frozen)；解冻 resumed。首版若不做占用锁可省，但别把 pause 写成 stop。
- **ended 上报顺序**：先 `playing='ended'`，再判 `isDragging() || frozen` → ignore。顺序反了会在拖拽松手期间误触发随机链。

### 3.2 随机链掷骰（`shared/pickers.ts` / `animation/next-animation.ts`）
```text
rollKind(roll, w={idle:10,turn:5,move:5}, fixed):
   turn = fixed ? 0 : 5;  move = fixed ? 0 : 5
   roll < 10/100                  → idle
   roll < (10+turn)/100           → turn
   roll < (10+turn+move)/100      → move
   else                           → action

pickWeightedCategory(categories, facing):
   pool = categories.filter(c => c.actions.count>0)
   if facing == right: pool = pool.filter(c => !c.noMirror)  // 文字类镜像会反字
   total = sum(weight); t = random(0,total); 依次减 weight 命中即返回
   池空时退回未过滤的 pool（宁可镜像也不无声）

pick(pool, exclude):
   src = pool.filter{ $0 != exclude }; if src.empty: src = pool  // 单元素池退原池
   return src.randomElement()
```
action 挑法：按权重选分类 → 类内 `pick(actions, current)` 避当前；无分类回退 `pick(idle, current)`。**fixedEnabled 只把 turn/move 权重置 0（份额落 action），不改变是否可拖拽**；若产品要位置锁定需另加标志。

### 3.3 状态机（文字图）
```text
                      ┌──────── ended 决策 ────────┐
                      v                            |
 [启动] ─switchTo(idle,once=true)→ IDLE             |
                      |                            |
   ┌──────────────────┼───────────────┐            |
   | roll=idle        | roll=turn     | roll=action|
   v                  v               v            |
 IDLE(重播)        TURN(once)     ACTION(once)     |
   └──────────────────┴───────────────┴────────────┘
                      | ended → pickNext() → switchTo(next, once=true)
 命中区点击 → CLICK_RESPONSE(once) ─ended→ interaction-done → 恢复工作态或 idle
 位移≥5pt  → DRAG_FEEDBACK       ─松手─→ 恢复工作态或 idle(once=true)
 冻结/睡眠（首版不做）→ pause / 三段机 → 解冻/醒来回随机链
```

ended 决策顺序（`animation/cues.ts` decideEndedCue，**顺序即优先级**）：
```text
1) 睡眠态优先：sleep.consumeEnded()（首版跳过）
2) 事件动画 且 工作态非 idle/success/error → work-rotate（同档多候选轮换，避 current）
3) 事件动画 且 工作态终态/null → work-replay（loop=false 重播）
4) 事件动画（无工作信息）→ event-done
5) current 属于 turn 池 → turn：翻转 facing，再 pickNext()
6) current 属于 drag 池或 clicks 池 → interaction-done
7) 其他 → random：pickNext()
```
interaction-done/event-done：尝试恢复工作状态动画；没有则回 idle（`pick(idle, current)`），统一 once=true 保证 ended 还能回来。

### 3.4 首版动画集与素材池（`assets/config.jsonc:304-360,440-444`）

- **idle**：`待机呼吸休闲`（单元素）
- **turn**：`东张西望`（播完翻转 facing）
- **drag**：`被鼠标拖拽悬空反馈`
- **clicks**（5 选 1）：`点击回应-开心跃动`、`点击回应-害羞惊讶`、`点击回应-傲娇生气`、`点击回应-挠痒咯咯笑`、`点击回应-元气挥手`
- **action 分类（可选裁剪）**：小动作20 / 玩耍20 / 吃什么16 / 时节14 / 文字10（noMirror，`是啊，吃什么`、`深度思考碎碎念`）
- **moves.default**（首版不做走位）：minDist=60,maxDist=240,margin=20,leadSec=2,tailSec=2；动作 `螃蟹走路`、`原地漂浮踏步`(40~120)、`原地左转奔跑`(120~320, lead1.75/tail4.8)
- **不进随机链、首版不做**：events.balance（6 档：钱袋满溢/金袋叮当/钱袋如常/数金皱眉/袋空如洗/分文不剩）、events.whisper（3 档）、events.workStatus（6 档：思考冒泡/忙碌点按/清点归档/原地踱步张望/雀跃庆祝/垂头叹气冒汗）、sleep（start/loop/end）、baifan（5 个）。

---

## 4. 悬浮位置与拖拽规格

### 4.1 位置表示
- 内部存**归一化中心** (rx, ry) ∈ [0,1]²；customPos=null 时用 corner+margin 算初始角落（`sprite.js position()`）。
- 中心 → 画框左上：`box.x = rx*W - halfW; box.y = ry*H - halfH`（`centerToBox`）；反向 `boxToRatio` 用于松手提交与 resize 重算。
- 旋转/尺寸变化：监听 resize → centerToBox → clampReachableBox → boxToRatio 重算 customPos（`card/animation.ts`）。

### 4.2 可达边界（`geometry.ts clampReachableBox`）
```text
inset = 身体相对画框的像素盒（由 HIT_BOX 换算：left=0.3125*size,
        right=0.3125*size, top=0.1389*height+bottomPad, bottom=0.0694*height）
minX = 24 - inset.right;   maxX = W - inset.left - 24
minY = 24 - inset.bottom;  maxY = H - inset.top - 24
若 lo > hi（宠物比可用区域大）：取居中 (W-size)/2 或 (H-height)/2
```
语义：命中区至少 24pt 留在屏幕内，保证还能点/拖回来。**拖拽跟随阶段不夹**，只在松手 commitPlace 与 resize 时夹；飞行另有更宽的 `throwBounds`（minX=-sideAllow, maxX=W-size+sideAllow, minY=0, maxY=H-height）。

### 4.3 拖拽手势（`motion/drag.ts`）

**按下**
```text
onPointerDown:
  if button != 0: return                       // 只认主指/左键
  if frozen: releaseLock()                     // 用户接管，乐观解冻
  noteGrab(飞行速度): |v| >= SCORE_MIN_SPEED 则记分，pressScoreFired=true
  stopFlight(); follow.stop(); stopAutonomy(); trail = []
  beginPress:
     capturePointer(); setTipOn(false)
     offX = 指针X - (frame.left + halfW); offY = 指针Y - (frame.top + halfH)
     setBox({x: frame.left, y: frame.top})
     sling = (now - lastPressAt) < 200ms; 命中后 lastPressAt=0（防连点弹两次）
     anchor = 当前 box + half                 // 弹弓原点 = 按下时中心
```

**移动**
```text
onPointerMove:
  if !press.active: return
  d = hypot(指针 - 按下点)
  if !press.dragging:
     if d < 5: return
     press.dragging = true; setOnce(true)
     if dragAnims 非空: playAnim(pick(dragAnims))   // 被鼠标拖拽悬空反馈
  trail = trimTrail(trail + {t:now,x,y}, now)       // 保留 200ms
  goal = { x: 指针X - offX - halfW, y: 指针Y - offY - halfH }
  follow.aim(goal); follow.start()                  // 弹簧追 box 左上角
```

**弹簧跟随**（`drag-follow.ts`）
```text
dt = min((now-last)/1000, 1/30)
vx = springStep(vx, x, goal.x, dt, power=physics.throwPower)
vy = springStep(vy, y, goal.y, dt, power=physics.throwPower)
x += vx*dt; y += vy*dt; writeFrame(x,y); setBox({x,y})
// springStep(v,x,target,dt,p=1) = v + ((target-x)*200 - v*30)*p*dt
// 用 generation token 丢弃迟到帧
```
ObjC：用 CADisplayLink 跑这段显式积分（与源码一致），或映射到 CASpringAnimation 的 mass=1, stiffness=200, damping=30（临界阻尼≈2√200≈28.3，30 即过阻尼）。

**松手**
```text
settleRelease:
  box = 当前 box ?? 指针兜底
  decision = decideRelease(anchor, box, half, now, physics, size, sling, trail)
  if sling:  startFlight(box, slingshotVelocity(...))   // 200ms 内二次按下再拉
  else if throw: startFlight(box, estimateReleaseVelocity(trail,...))
  else:      commitPlace(clampReachableBox(box))        // 原地放下
endPress:
  follow.stop(); 复位 press; justDraggedUntil = now + 100ms
  if wasDragging:
     若无可恢复工作态: playAnim(pick(idleAnims,current)); setOnce(true)
     settleRelease(...)
```

**甩抛初速估算**（`shared/physics/release.ts`，仅抛掷时）
```text
trimTrail: 只留最近 200ms 样本
estimateReleaseVelocity(trail, now, physics):
  空 / now-last.t>150 / 窗口<2点 / 跨度<20ms / baseSpeed≈0 → null（原地放下）
  baseV = (末点.x-首点.x)/(末t-首t)*1000
  分段(dt>=8ms)算 segSpeed, peak=max
  accel = (末段速度-首段速度)/Δt秒
  speedBefore = (0.5*base+0.5*peak)*(1+min(accel/8000,1)*0.6)
  speed = softClamp(speedBefore)*throwPower; speed<500 → null
slingshotVelocity: speed = 1200*max(0, dist/(0.6*size))*throwPower（无软上限）
角度制：0=正右、逆时针为正；屏幕 y 向下故 vy = -sin(rad)*speed
```
飞行积分：`dt=clamp(dt,0,0.05); v+=g*dt; pos+=v*dt`；碰边 `|vn|<40→0 否则 |vn|*0.78`，切向 `vt*(1-2.5*dt)`；静止判定法向<1 且切向<15。**首版建议只做原地放下**，抛掷/弹弓下一版开。

---

## 5. 点击命中与回应规格

### 5.1 命中区域
用第 2 节 hitRect 生成的透明子 view，不是整个画框。透明视频 alpha 像素同样不参与 UIKit hitTest，必须靠这个 view。

### 5.2 点击判定与连锁抑制（`drag.ts onClick`）
```text
onClick:
  if press.active || press.dragging || now < justDraggedUntil(100ms): return
  if pressScoreFired: 清标志; stopFlight(); stopAutonomy(); return
  stopFlight(); stopAutonomy(); playClickSound()  // 可选
  setOnce(true)
  if clickAnims 为空: return
  name = pick(clickAnims)   // 源码点击路径不避 current，单元素池会连播
  markSquash(); bumpSeq(); playAnim(name)
```
要点：拖拽后 100ms 内不触发点击；点击飞行中的宠物 = 收手停住；触屏长按 500ms 且位移未超 8pt 才算菜单（首版可不做）。

### 5.3 Q 弹（`shared/physics/squash.ts` + `motion/squash.ts`）
```text
u = elapsed / 220ms
scaleY = u < 0.45 ? 1-(1-0.55)*(u/0.45)^2
                  : min(1.12, 0.55 + 0.45*easeOutBack((u-0.45)/0.55))
// easeOutBack: c1=1.70158, c3=2.70158, f=1+c3*(p-1)^3+c1*(p-1)^2
transformOrigin = 底部；facing==right 时前置 scaleX(-1)
```
ObjC：对新切前台 layer 设 `anchorPoint=(0.5,1)` 后做 `CABasicAnimation(keyPath:'transform')` 220ms；anchorPoint 变化要同步补偿 position，否则跳位。

### 5.4 点击音效（可裁剪）：`click-duck.wav`、音量 0.5、节流 100ms。

---

## 6. 素材映射（动画名 → 文件）

### 6.1 命名规则
```text
文件 = <动画名> + <扩展名>     // 动画名含中文/空格/间隔号，必须逐字一致
iOS 固定 .mov（HEVC-with-alpha）；不要用 .webm（会黑底）
示例：待机呼吸休闲.mov、点击回应-开心跃动.mov、被鼠标拖拽悬空反馈.mov、吃饭·碗饭.mov
```
源码 URL 拼接（`animation/assets.ts`）：`ROUTE_PATH + '/thumb/' + encodeURIComponent(assetRoot) + '/' + encodeURIComponent(anim) + ext`，`assetRoot = pet.assetRoot || pet.id`。

### 6.2 查找优先级（`host/routes/assets.ts:129-157`）
```text
1) 若存在专属目录 pet/<素材根>-animation/：只查该目录，查不到即 404
   （仅 .mov 缺失时可退同名 .webm——iOS 不要启用这条回退）
2) 否则：用户层 $DSH_HOME/dsh-pet/main-animation/<ext>/ → 包内 assets/<ext>/
3) 扩展名只放行 .webm / .mov
```
tweak 落地：把 .mov 作为 Theos resource 打进 bundle，`PetAssetResolver` 用 `NSDictionary<NSString*,NSURL*>` 做**精确名字映射**（不要字符串拼接后依赖大小写/编码）；中文与特殊字符（如 `吃饭·碗饭`）在 plist 里保持 UTF-8 原名，必要时加 ASCII 别名键做二次索引。缺失资源时不换源（上报失败），别回退 webm。

### 6.3 首版最小素材清单（必须）
1. `待机呼吸休闲.mov`（idle）
2. `东张西望.mov`（turn，可选；不做 turn 就把权重置 0）
3. `被鼠标拖拽悬空反馈.mov`（drag）
4. 五个 `点击回应-*.mov`（clicks）
首版若做 action 随机链，再按 3.4 分类池补齐；不补就把 action 权重归 idle（只剩 idle/turn/drag/clicks 四类）。

---

## 7. Objective-C 落地建议

1. **宿主与浮层**：注入 SpringBoard 后，用单例持有透明 UIWindow（windowLevel 高于图标层、低于锁屏/控制中心；具体级别真机验证），或在 SpringBoard window 上挂透明 UIView。浮层 `userInteractionEnabled=YES`，但重写 `-hitTest:withEvent:` 只返回命中区内的 subview，其余返回 nil 透传到桌面。
2. **两个播放层**：`AVPlayerLayer *layers[2]` 上下叠放，`videoGravity=AVLayerVideoGravityResizeAspect`（对应 object-fit:contain），`player.muted=YES`、`automaticallyWaitsToMinimizeStalling=NO`（对应一次性 fetch 整文件策略）。监听 `AVPlayerItemDidPlayToEndTimeNotification` 模拟 ended；只在 once 时监听，循环项回调里 seekToTime:kCMTimeZero 重播。
3. **异步与代号**：加载/解码在主线程外，回调 `dispatch_async(main_queue)` 后先比对 generation 再换前台，杜绝快速连点时的旧帧覆盖。
4. **手势**：命中 view 上用自定义 `UIGestureRecognizerDelegate` 或 `touchesBegan/Moved/Ended` 把 4.3 节逐分支翻成 ObjC；阈值 5 / 100ms / 200ms 直接用常量。CADisplayLink 只在拖拽/飞行期间开启。
5. **状态与持久化**：`PetState` 的 anim/once/seq/facing/customPos 主线程读写；customPos 用 NSUserDefaults 存归一化 (rx,ry)；旋转后按 4.1 重算并 clamp。
6. **朝向镜像**：facing==right 时对当前前台 layer 施加 `CGAffineTransformMakeScale(-1,1)`；与 Q 弹 scaleY 组合时用同一个 transform 赋值，别分两次覆盖。
7. **不做**：不要用 UIAlertView/UIActionSheet 或任何弹窗；不要在 tweak 里启 web server 或复用 dsh HTTP 路由；不要读 config.jsonc（首版把动画名和权重硬编码成 NSDictionary 即可）。

---

## 8. 验收清单（首版完成判据）

- [ ] 启动显示透明宠物，待机呼吸休闲.mov 按 once 规则播放，**无黑底矩形**（alpha 正确）。
- [ ] 命中区内点击：100ms 内触发五个点击回应之一 + Q 弹；命中区外点击不误触桌面图标（hitTest 透传规则）。
- [ ] 位移 <5pt 松手 → 算点击；≥5pt → 播拖拽动画且松手后 100ms 内不播点击回应。
- [ ] 拖到屏幕边缘松手 → 命中区至少 24pt 可见；旋转屏幕后位置不跑丢。
- [ ] 快速连续点击/切换 → 不出现旧动画闪回（generation 生效）。
- [ ] 冻结/恢复（若实现）不留 paused 且卡死的前台层。

---

## 9. 首版明确不做

| 项 | 理由 / 开启条件 |
|---|---|
| 自主走位 walk / move-action | 需逐帧读 video.currentTime 插值 + 可达性规划；首版只需悬浮+拖拽+点击 |
| 睡眠三段机 sleep-machine | 需整套 start/loop/end 素材；首版没有 |
| 工作/余额/碎碎念事件动画 | 依赖 dsh 宿主事件；tweak 无数据源 |
| 抛掷/弹弓飞行 | 物理积分、多子步、落地挤压、触感；第二版开，先做原地放下 |
| 多宠互撞、倾斜重力、摇一摇 | 需多实例与传感器，首版单宠 |
| 提示气泡/右键菜单/长按 | 属设置与玩法层；首版命中区只做点击+拖拽 |
| A/B 之外的第三方缓冲 | 源码即双缓冲，足够 |

**一句话实现顺序**：PetAssetResolver（5+2 个 .mov 就够）→ PetAnimationController（A/B + gen + once/ended）→ PetGeometry + 命中 view → PetDragHandler（阈值 5、弹簧 200/30、100ms 抑制、clamp 24）→ PetAnimationFlow（idle/turn/drag/clicks 掷骰）→ 按第 8 节逐条核。
