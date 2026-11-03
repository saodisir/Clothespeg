# 通用教训（跨子系统，都是栽过的）

> 从 `.workbuddy/memory/MEMORY.md` 外置而来（2026-11-03 重建时拆出）。MEMORY.md 里只留一行版。
> 这些不是「风格建议」，是**违反就会静默出错**或者**会白干一轮**的东西。

## 验证与自检

- **只在默认状态下成立的检查等于没有检查**；**不会失败的自检等于没有自检**。
  写完把修复摘掉，看它报不报警——不报警就不是检查。
- **能测就别估**；**量像素前先确认采样区里只有要量的东西**。
- **合成事件绕过的层，就是它证明不了的层**：`panel.sendEvent` 绕过了窗口服务器，
  所以「合成点击能到回调」不等于「真点击会交过来」（2026-11-03 完成按钮，自检绿、真机不亮）。
- **阈值问一句「别的设备走这条路吗」**；**溢出要有上限**；**「能吃掉」的前提是「看得到」**。
- 检查太容易抖动就等于没有检查（`capture compare` 比对两次实时抓屏，画面一动就从 0.0000 跳到 0.0624），
  这种检查红了先怀疑检查本身。

## 状态与生效

- **「实时生效」= 持久层 / 调度器收到了**，不是 UI 变了。
- **async 调用不等于已经生效**：`NSApp.deactivate()` 调过之后 0.5 s 日志仍 `app active true`，
  有时连着几次截图都还是 true。判据是**回读到的状态**，不是「我调过了」。
- **同一开关出现在两处（菜单栏 + 配置页）就必须靠通知同步**：设置窗口 `isReleasedWhenClosed=false`
  只造一次，`.onAppear` 整个会话只跑一次，而菜单每次打开重建 → 永远是「菜单新、页面旧」，
  且 `UserDefaults` 进程内不发通知。正解：**setter 是唯一写入点**，`guard 新值 != 现值`
  （同值不喊，回声不会乒乓）后调 `SettingsAnswers.announce(key)`，页面 `.onReceive(.settingsAnswerChanged)`
  把自己那几个布尔全重读；**只有一条通知名、不按答案分开**（表格本身才是会过期的东西）。
  全 app 只有三对：截图上绳 / 新东西时放绳 / 复制带格式。验收 `CLOTHESPEG_SETTINGS_FLIP=inbox|peek|formatted`
  （先让页读完再改答案），**摘掉订阅后必须与基线逐字节相同**，否则那条检查不会失败。
- **`NSViewRepresentable.configure` 里读的状态不在 SwiftUI 依赖图里**，改了不触发 `updateNSView`。

## 布局与尺寸

- **超类帮你算的尺寸不是你的尺寸**：`NSButton.alignmentRectInsets` 按字形内缩 + `NSStackView` 按
  alignment rect 排版 → 同一条 30×26 约束外框 26…33 不等。改 `intrinsicContentSize` 无效，
  正解 `override var alignmentRectInsets { NSEdgeInsets() }`。**别为一个现象写两层覆盖。**

## 窗口与事件

- **borderless + nonactivating 的 `NSPanel` 上，`isMovable` / `isMovableByWindowBackground` /
  `.resizable` / 容器 `resetCursorRects` 全是空头支票**——没有标题栏可挂靠，移动、缩放、光标都得自己算。
- **一个窗口收得到指针跟踪、收不到点击**，只有两个已知解释：`canBecomeKey == false`
  （borderless 的默认值），或者窗口**全透明且无内容**（窗口服务器看得穿它，不派按压）。
  两者都是「看起来完全正常、日志全是 true、就是不进 `mouseDown`」（2026-11-03 长图完成按钮）。
- **兜底不能由正在失效的那个组件驱动**：面板收不到点击时它也报不出指针位置，所以兜底要读
  `NSEvent.mouseLocation`（真实指针）自己判——否则「备用方案」和主方案一起沉默。
- **「按钮无效」有四种事后不可区分的原因**：按下没到、按到了旁边、窗口可见但不在最上、
  在最上但不被当成可点。各给一行日志，否则只能靠猜。

## 演练（离屏渲染）

- **演练动了用户真实偏好，进出都要按原样还**：离屏渲染同 bundle 写的就是真 `UserDefaults`；
  「从没选过」≠「选了开」，还的时候 nil 要 `removeObject`。
