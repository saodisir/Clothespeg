# 空格预览与图钉（`ZoomPreview.swift`）—— 已拍板的设计决定

> 从 `.workbuddy/memory/MEMORY.md` 外置而来（2026-11-03 重建时拆出）。
> 相关：`notes/dev-backlog.md` #24（已完成的条目）。

## 窗口与注册

悬停卡片注册 Space Carbon，离开 / 收绳 / 前台即注销。窗口 borderless + `.nonactivatingPanel` + 不能成 key
+ `.popUpMenu`，**必须接鼠标**（否则滚轮给下层），`clickSlop=3` 分点击与拖拽。

## 图钉（`PinButton` + `OpacitySlider` + `ZoomPane`）

- **移动 / 缩放 / 光标全自己算**：边缘 8 点带=缩放、纸面 / 图片=挪窗（看 `mouseDownCanMoveWindow`）、
  文字=选词。最小 **280×180**。
- **钉住后 `dismiss()` 一律返回**（Esc 不关）。
- **图钉没有圆底**：空心 `pin`=未钉、实心 `pin.fill` + clay=钉住（与卡片图钉同一套语义，别再叠一层圆底），
  只留一层阴影保住图片上的可辨性。
- 滑块在图钉左边、**鼠标进窗才淡入**（`hitTest` 里 alpha<0.5 返回 nil）。尺寸 / 透明度都不记忆，
  每次回 640×440 / 100%。
- 正文首行让位 = 图钉直径 + 内缩 + 2；⚠️ 布局挂 `setFrameSize`，**不是 `resizeSubviews`**
  （`autoresizesSubviews=false` 时不走）。

## 光标靠「读」不靠「等」

`mouseMoved` 到不到非 key 面板没文档保证，本机也验不了（合成事件要 AX 权限）；`mouseEntered` 更靠不住——
**窗口是在静止指针底下弹出来的，边界一次都没被跨过就没有 enter**。正解：窗口出现就起 1/30 s `Timer`，
`zoom.frame.contains(pointerLocation())` 自己判内外，`convertPoint(fromScreen:)` → `applyCursor`；
`isHoldingWindow` 时 tick 让路。

## ⚠️ 只有前台 App 的光标才会被画出来

截图实证：同一面板、同一句 `NSCursor.set()`，前台画手形、非前台画箭头，而进程内 `NSCursor.current`
两边都回读成手形——**回读骗人**。所以钉住时 `NSApp.activate()` + `keyable=true` + `makeKeyAndOrderFront`，
松手 / 关窗把前台还给 `previousApp`（日志 `Zoom pin: took the front from …`）；未钉的快捷预览绝不抢前台。

## 验收

`CLOTHESPEG_ZOOM_SHOT=<png> [.._WIDTH/_HEIGHT/_PIN/_DARK/_HOVER/_OPACITY/_IMAGE]`；
自检行 `zoom targets: …`（分支输入）与 `zoom cursors: edge/paper/text/pin ok`
（**先毒成别的光标再回读 `NSCursor.current`**，proof 过它会 WRONG）。
**合成事件用 `convertPoint(toScreen:)`，不能用 `NSEvent.mouseLocation`**（后者读真实光标）。
