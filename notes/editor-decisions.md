# 图片编辑器 —— 已拍板的设计决定（详细版）

> 从 `.workbuddy/memory/MEMORY.md` 外置而来（该文件有 10000 字符注入上限，2026-11-02 超限被截）。
> MEMORY.md 只留最常用的几条 + 指向本文件。
> 相关：`notes/editor-plan-v2.md`（完整方案）、`notes/roadmap-capture-and-editor.md`（路线）、`notes/dev-backlog.md`（计划）。

## 界面语言

- 标题栏放文件名 · 像素数（**名称只出现在这里**）；画布铺满 contentView；**三条浮条压在图上**（左 `leading+16` 撤销重做、中 `centerX` 工具、右 `trailing−16` 复制+覆盖）。
- 浮条用 `EditorGroup(surface: .floating)`：近不透明面 + 14% 发丝边 + 阴影，**不用 `NSVisualEffectView`**（拖拽时每帧重模糊）。
- **中间那条**：`[手] 缩放− 百分比 缩放+ | 选择 裁剪 | 八个标记`，两处竖线（线高 60%，等高等同第 12 个按钮）。**手不在工具列表**——它是缩放之后救场的，不是「画什么」。
- **最小宽度 780**（量出来：980→缝隙 134pt，780→34，740→14）；850 是「按钮放宽」那版、已被用户按回去了。
- **按钮 30 宽、间距 4，一个点都不动**；角标的家只从**浮条两端内留白**出（7→12）。**间距是给手排的，角标是给眼看的——不能拿后者去挪前者**；加角标先问「能不能只给边上的让位」。

## 快捷键角标

- 11 个工具右下角 6.5 点大写字母（`ToolChip.hint`，从 `bounds` 画，靠 `alignmentRectInsets` 归零才同排）。
- 开关在设置→通用（`ShortcutHints` / `editorShortcutHints`，默认开，通知即时刷已开窗口）。
- **命令键不标**（⌘Z/⌘C/⌘S 是肌肉记忆、⇧⌘Z 塞不下），设置文案就是这个口径，改口径要连文案一起改。
- 墨是 `labelColor` 一半，**不用 clay**（clay 只说「这个在我手上」）。

## 抽屉（属性栏）

- 挂在中间那条下 8pt，同材质同圆角；跟着工具出现，「选择」时隐藏；**再点一次当前工具收起**（只有 chip 有这含义）。`drawerFolded` 在 `select()` 里清零。
- **填充开关只在矩形/椭圆出现**，位置**紧跟两个滑块**，图标 `square.inset.filled`。
- 裁剪比例下拉只在裁剪工具下、在属性行最左边。

## 两个出口

- 复制／覆盖（唯一 clay，`keyEquivalent="\r"`），**都不关窗**，关窗交给交通灯；按完变 √ 一秒。
- 取消按钮删掉——关窗就是取消。
- **灰掉的 clay 不是 clay**：`isEnabled` 才上 clay，禁用色 `labelColor@32%`。裁剪框在时回车归裁剪。

## 开窗位置

- 按 `LinePanel.current`（弱引用静态）真实下边缘摆，屏幕取**指针所在那块**，退路 `visible.maxY - Layout.clipboardDepth`；只算一次，挪过不再拽回。

## 缩放

- `zoom: CGFloat?`（nil=适合窗口）+ `pan`。
- **步进 ±10 个百分点且第一步对齐整十**（73%→80%）；菜单 50/100/200/400 是「回固定档位」，两回事。
- **`imageRect` 是唯一变换点**：箭头头部/文字框/插入符/裁剪框/命中松弛全从它推。
- 百分比按钮落菜单（⌘1 适合 / ⌘+ / ⌘− / 100 ⌘0）；滚轮、双指、捏合、**`hand`(G) 拖动平移**；**空格留给文字工具**；`fit` 只缩不放。

## 窗口与记忆

- **一图一窗**：`ImageEditor.controllers: [URL: Controller]`，第二次打开是把已有窗口提到前面。
- **默认值 + 记忆**：线宽 6、字号 40（`EditorTool.defaultStyle`），经 `EditorStyleStore`（UserDefaults+JSON）落盘；只在「没选中标记」时落盘。
- **滑块连续上报**：`ValueSlider`（拖拽中只改内存，`persist=false`，松手 `onCommit` 落盘），标号跟手；撤销靠 tag 合并。自检 `.._SLIDER`（机制 + 行为分开验）。

## 颜色

- 7 系统色点 + 加号点开 `NSColorPanel`，非常规色落在加号点上；点 18pt。
- `NSColorPanel.shared` 全进程一个 target 且**只能 set 不能 get** → `weak static var panelOwner`，关窗还。
- `NSColor` 相等是目录条目同一性 → `ColourDot.matches`（sRGB 分量差<0.004），**且必须 aqua 与 darkAqua 各比一次**（否则深色下选中环消失、第八点假装自定义）。

## 点阵底

- 12pt 间距 / 1.8pt 圆点 / `labelColor@14%`；只在图片外，**不随缩放变**（它是桌面不是纸）。
- `NSColor(patternImage:)` 的 tile 烧了颜色 → `viewDidChangeEffectiveAppearance` 必须丢弃重建。

## 裁剪

- **没有裁剪按钮，双击框即应用**（回车也行）。
- 9 档：自由/1:1/4:3/3:2/16:9/3:4/4:5/9:16/2.35:1；裁剪后 `updateTitle()` 重写像素数。

## 参数

- 字号 8…100（默认 32）、序号圆直径 16…160（默认 48）、箭头头部按**线宽**算。
- 同一个 `width` 对不同工具量级不同 → `StyleField.range(for:)` 按工具算。
- 图标：铅笔 `pencil.tip`、马赛克 `circle.grid.3x3.fill`、文字自绘「Aa」。

## 斜体

- **三段已验通**（字体层 `.SFNS-RegularItalic`／按钮→`style.isItalic`／样式→插入符）。用户说不斜时先问「输入时不斜」还是「提交后不斜」。

## 验收（离屏渲染）

```bash
CLOTHESPEG_EDITOR_PREVIEW=<图> CLOTHESPEG_EDITOR_SHOT=<png> \
  [.._TOOL] [.._WIDTH] [.._DARK] [.._DRILL] [.._ITALIC] [.._ZOOM] [.._ZOOMDRILL] \
  [.._FADE] [.._PLACE] [.._HINTS] [.._NOHINTS] [.._CHECK=<第二张图>] \
  build/Clothespeg.app/Contents/MacOS/Clothespeg
```

- 裸 `.build/debug` 没有 .lproj，必须跑 `.app` 里的二进制。
- 自检行：`preview: everything fits`、`bars: three, tightest gap N pt`（相撞打 OVERLAP）、`zoom: the transform agrees…`、`hints: all eleven on one line`、`place: …under the strip`。
- **演练瞄准图片坐标**（`previewViewPoint`），截图拍 window frame view（含标题栏）。
- 设置页 `CLOTHESPEG_SETTINGS_SHOT=<png> [.._PAGE=…]`——唯一 SwiftUI，**只出图不出数**。
- 两处没有自动化：浮条上的光标、真面板下面那条路。

## 陷阱清单

1. SF Symbol 会本地化，文字工具自绘「Aa」。
2. CGColor 烧进 layer 不跟外观 → `updateLayer` + `viewDidChangeEffectiveAppearance`。
3. 内容视图没底色，渲染前先铺 `window.backgroundColor`。
4. 外观必须在窗口建好之前定。
5. **`window.sendEvent` 发鼠标事件没用**，直接调 `canvas.mouseDown/Dragged/Up`。
6. 浮条不声明 cursor rect 光标会穿到画布拿十字。

## `NSStackView` 隐藏三件事

- `isHidden` + `detachesHiddenViews=false` **不把宽度还回来**，要 `setVisibilityPriority(.notVisible, for:)`。
- 被藏视图留在负坐标，出界检查先 `isHiddenOrHasHiddenAncestor` 跳过。
- 托盘行里必须有 spacer。
