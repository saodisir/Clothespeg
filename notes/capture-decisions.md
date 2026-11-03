# 截图（`Sources/Clothespeg/Capture/`）—— 已拍板的设计决定

> 从 `.workbuddy/memory/MEMORY.md` 外置而来（该文件注入上限 10000 字符，2026-11-03 重建时拆出）。
> 相关：`notes/dev-backlog.md` 的「截图 P1 / P2 / P2.1 / P2.2」各节（叙事与当轮日志摘要）、
> `notes/roadmap-capture-and-editor.md`（路线）。

## TL;DR（动手前扫这一段就够）

1. 遮罩是 borderless `NSWindow`，**全手绘 AppKit，里面没有 SwiftUI**；选区用 `.copy` 重画。
2. **窗口层级有分界**：`.screenSaver` 是窗口服务器开始把窗口当「非普通窗口」的地方。遮罩 `.popUpMenu+1`、
   长图的按钮面板 `+2`，要盖的东西全在下面。
3. **一个模式 = 一个按钮 + 一个裸键，永远同义**：比例 `R`、长图 `L`、选文字 `W`。
   出口（回车 / esc）可以借全局热键，**入口不行**。
4. 长图态的「完成」按钮住在**自己的 `NSPanel`** 里，`canBecomeKey` 必须 true，窗口不能全透明；
   旁边的 ✕ 同一个面板，先判 ✕ 再判胶囊。
5. **「完成」不看帧数**：进了长图态就有按钮，没滚过按下去就是一张普通截图（`longDecision`）。
6. 自检：`CLOTHESPEG_CAPTURE_SELFTEST`，会失败的检查才叫检查。
7. **重截**：`LastCapture` 记「上一次截了什么」（类型 + 矩形，存 defaults），浮条最后一个按钮把它**放回原位**
   （不当场拍，人再双击/回车/拖边决定）；**只记落地的、不记取消的**；类型进日志但不替人选门。
8. **先选、后截**（2026-11-03 定）：**一切输入只产生选区**——拖拽、单击窗口、空格都是「选」，
   **只有回车 / 小键盘 enter / 双击选区**才拍。所以浮条上才有 `编辑`（= 正常落地 + 打开编辑器），
   也才有「窗口」和「整屏」两句各自的提示语（窗口的框不能拖，不能骗人说能）。
   一个动作一个意思：`Return`/`enter`/双击是同一件事（`confirm()`），别再加第四个入口。
9. **浮条按钮 = 图标 + 角标**（30×26、间距 4、`ToolChip` 的数字），只有「比例」带值所以只有它不是方块；
   图例只剩 `esc`；符号名在 `CaptureSymbol` 里一次列全、自检逐个查（`capture chips:`）。

## 遮罩与窗口

- 遮罩是 borderless `NSWindow`（`CaptureLevels.overlay` = `.popUpMenu + 1`、`canBecomeKey`、
  冻结帧底图 + 0.56 压暗），**全手绘 AppKit，遮罩里没有 SwiftUI**；选区用 `.copy` 重画。
  背景 `capture permission: granted` 由自检报。
- 层级为什么不是 `.screenSaver`：那一档起窗口服务器开始把窗口当「非普通窗口」，而长图的按钮面板
  **要的恰恰是一个普通可点窗口**。参考实现（`MustangYM/LongScreenShot`）也刻意避开这一档。现在要盖住
  的东西——line 在 `.floating`、搜索栏在 `.statusBar`、打开的菜单在 `.popUpMenu`——全在 `+1` 以下。

## 浮条（底部胶囊）

- 一个胶囊 `Bar`：`状态句 │ [⊟ 形状 ▾ R] [卷轴 L] [⛶ W] [文A T] [✎] [↶] │ esc`。
  符号：`aspectratio` / `scroll` / `text.viewfinder` / `translate` / `pencil` / `arrow.uturn.backward`。
  **锁着的和上了膛的都实心**（`isPicked(_:)` 一处回答，画和自检都问它）：比例锁了形状亮、`L`/`W`/`T`
  按下之后对应的那颗也亮——`编辑` 和 `重截` 永远不亮，因为它们不改变「下一次拖拽是什么」。
  实心时图标、字、**角标**一律转深色（白字压陶土 = 看不见）。
- **座宽钉在最宽那句上，句子在座里居中**（不居中就是「右边老是这么空」）。
  ⚠️ 加长句子 = 给所有其他状态加空白：中文这座曾经被「滚太快了，跟不上 —— 慢一点，让两屏有重叠」(233)
  撑着，而它一年出现两次；现在最宽的是等待句「拖拽选区 · 单击窗口 · 空格选整屏」(173)。
  英文那座还被 "Drag out an area · click a window · Space for the whole screen" 撑着（约 330），
  没有动——英文用户会觉得比中文宽，这是已知的。
  状态句只有几句，胶囊宽钉在**更宽那句**、比例块宽钉在**最宽标题**上，所以都不跳。
  面板 3×3。`Esc` 先关面板再关窗。按钮**一直在**（没有选区时也在，因为「比例/长图/识别/译」
  说的是「接下来那个动作是什么」，不是「对这块做什么」）——`编辑` 则两者都算：
  没有选区时它等同回车，也就是整屏。
- **按钮是「图标 + 角标快捷键」，照编辑器浮条那一套**（2026-11-03 用户提的）：30×26、圆角 7、
  间距 4、图标 14pt、角标 6.5pt 半粗画在右下角——数字全抄 `ToolChip`，两根浮条差一个点就成两个 App。
  沿用的判据：**角标不标命令键**；**角标受同一个开关管**（`ShortcutHints`，设置页现在写「在按钮上显示快捷键」），
  所以 `R · L · W · T · esc` 那行图例撤了，只留 `esc`（唯一没有按钮的键）。
- **唯一带值的是比例那颗**，所以它是唯一不是方块的：`图标 + 值 + ▾ + 角标`。图标说「这是形状」，
  值说「哪个」，▾ 说「还有别的」——纯图标会把「自由 / 16:9」这个值吞掉，那正是这颗按钮在回答的问题。
  锁着形状时整块 clay 实心、图标与字转深色，**角标也要转深色**（白字压陶土 = 看不见）。
- **符号名收在 `CaptureSymbol` 里，一次列全**：符号名是操作系统的既成事实，改名或撤掉就画成空白方块，
  编译期一声不响；自检每次拿 `NSImage(systemSymbolName:)` 走一遍（`capture chips: symbols 6/6 ok`）。
  同理 `translate` 在中文系统画的是「文A」——这里不是坑，那正是 macOS 自己的翻译标记。
  **三个符号被换过**（2026-11-03 用户点名）：长图 `arrow.down.to.line` → `scroll`（卷轴才是「比屏幕长」，
  箭头只说「向下」，14pt 下还像下载）；编辑 `square.and.pencil` → `pencil`（方框+铅笔在 30 点里糊成
  「带斜线的方块」）；重截 `arrow.counterclockwise` → `arrow.uturn.backward`（它做的是把框**放回**，
  不是转一圈再来）。
- **给出去的字搬进了悬停提示**（`chipName(at:)` + `addToolTip` 一个区域 + `view(_:stringForToolTip:point:userData:)`）：
  符号说不出「长图」两个字，提示里那句 `长图 · 往下滚动，回车完成` 就是它原来的名字。
  ⚠️ 那个方法是 **`@objc` 而不是 `override`**（AppKit 走 informal 协议，`NSView` 在 Swift 里没声明它）；
  写错选择器不会报错，只会五个哑按钮，所以自检里按名字 `responds(to:)` 查一遍。
- **设计判据（用户拍的）：已经在工作的手势给提示，只有手势表达不出来的事才给按钮。**
  拖拽 / 单击窗口 / 空格 = 提示；**比例、长图、识别、译、编辑** = 按钮。
  `编辑` 之所以是按钮而不是「双击之后再按 E」：一次截图的目的是进编辑器时，
  多按一次是白多按的一次——而且它必须在「单击只选」成立之后才可能出现（否则图早被拍走了）。

## 事件与手势（三处坑，都栽过）

- ⚠️ **`mouseDown` 第一件事是 `takeBarClick(at:) -> Bool`**：不返回 Bool，按按钮会先在底下起两点选区。
  面板开着时外面任何按压都被「用掉」。**而且 `mouseUp` 也得知道**（`barPress` 标记）：只拦按下不拦松手，
  松手会走「没拖动=单击」分支 → 按钮底下没窗口 → 取消整次截图（「点比例遮罩就没了」就是这么来的）。
  **事件成对，拦一半不叫拦。**
- **松手不截屏，松手只是把框画完**：框留下 + 八个手柄（6pt 淡橙圆点 + 黑 hairline，只在非拖画时画）。
  **拖角/边=改大小、拖里面=挪、拖外面=重画、双击框内或回车=截取**。
  ⚠️ **单击窗口也只选中**（2026-11-03 改；此前是立刻截）：`chosenWindow` 记住身份，框是窗口的框，
  **不画手柄、不能拖不能挪**（`frameIsResizable` 一个名字，画和摸共用），单击另一个窗口=换一个。
  撞屏幕边整框停住不破比例，下限 8pt。`moved` 从按下时的框位移并夹在屏幕内。
  全是 `nonisolated static`，`capture frame: … ok` 六条可验。
- ⚠️ **松手后光标会僵在 `closedHand`**：指针监视器只在指针动时 tick → `mouseUp` 末尾主动 `refreshHover()`。
  同「光标靠读不靠等」。

## 先选、后截（2026-11-03，用户改的交互）

用户的原话：「无论是按快捷键还是鼠标选中，都只是先确定高亮的选区，然后需要再去双击或回车，来决定到底怎么处理。」
以前单击窗口=当场截，这是全窗口**唯一**一处「一按两意」的地方，代价很实：图已经在剪贴板里了，
浮条上那几个按钮才出现，于是按钮全部只能对「下一张」有用。

- **一切输入只产生选区**：拖拽 → `selection`；单击窗口 → `chosenWindow` + `selection = window.frame`；
  空格 → `selection = screen.frame`（真的是个框，之后还能往里拖）。
- **只有一个出口**：`confirm()`。`Return`、小键盘 `enter`、双击选区三处调它，别处不许直接调 `onPick`/`onFinish`。
  出口一个，是因为「同意」这件事只有一种意思；入口可以有多个，因为三种输入是在表达同一个「它」。
- `target` 依次看 窗口 → 选区 → 整屏（最后这个兜底让冷启动时按回车也有意义）。
- **三句提示语各管一件事**：`整屏 · 回车截取`（整块屏，外面没东西可压暗，话就是全部）、
  `窗口 · 回车截取`（窗口的框是窗口的，**不能说「拖边缘调整」**）、`拖边缘调整 · 回车截取`（画的框）。
  窗口那句必须排在整屏判断**前面**：窗口可能正好铺满整屏，说话的是「选了什么」而不是「矩形多大」。
- **`编辑` = 正常落地 + 打开编辑器**（`commit(_:from:editAfter:)`）：先写 PNG、进剪贴板、挂卡，
  再 `ImageEditor.shared.open(url)`，而且 `DispatchQueue.main.async` 里开——从正在派发的事件里
  把另一个窗口提到前台，点击会落到刚出现的那个窗口上。先落地后开窗，是因为关掉编辑器不保存时
  人不该一无所有；一个产物而不是两个（改完保存时卡跟着换图）。

## 比例几何

`CaptureSurface.rectangle(from:to:aspect:within:)`（`nonisolated static`，可测）：
**指针决定长边、锁决定短边**、锚在按下的角、撞屏幕边**整对等比缩小**（夹单边会在贴边那一刻破坏比例）。
**紧比例时角也复用它**——指针只决定一维，角会跑到指针侧前方，别为角另立规则；边=锁驱动另一维且绕
中心线长。复用编辑器 `CropAspect` 九档，不新造枚举。

## 颜色

**淡橙 `claySoft` 只给截图遮罩**的选区边框与尺寸牌；锁绳 / 图钉 / 一切其他「亮起」态用 `clay`。
图钉**位图本身保持红色**（用户明确否掉改橙）。

## 竖向长图（P2）

- 浮条第二个胶囊「长图」（有选区直接进，没有则 armed 等下一次拖）。进入时窗口 `ignoresMouseEvents=true`
  （滚轮穿透到下面 app）+ `isOpaque=false` 并在区域内挖洞（否则用户在不透明板上盲滚）；
  **首帧从冻结底图裁，不现抓**（顶部补不回来）。0.3s 采样 → `LongStitcher`。
- ⚠️ **配准只做整帧，别做分带**：位移大于带宽时同号带不含同一段内容，配准给「自信的噪声」
  （实测 300/400 滚动 → 五带回 45/13/-21/45/-25）。符号实测 `advance = -ty`（handler=旧 targeted=新）。
  **真正的防线是拿答案对像素**：重叠区 16×16 均值差 ≤0.03，且**正反两向都验**
  （380/400 时 Vision 回 -295，是「错配+合理符号」，不验会被当成往上滚）。拼接后与原文 **diff 0.0000**。
  没滚就回车 → 走普通截图。
- ⚠️ **长图态主动让出前台（`NSApp.deactivate()`），键盘因此不在我们这儿**（实测 `deactivate`
  **异步且不一定立刻生效**：0.5 s 后日志仍 `app active true`，有时连着几次截图都还是 true ——
  别拿「调过了」当「已经让出」；功能上无碍，滚轮穿透靠 `ignoresMouseEvents`，与前台无关）：
  esc 全程注册、回车 + 小键盘回车只在长图期注册，都是 Carbon **裸键**热键（复用 `HotKey`，
  不要辅助功能；实测 53/36/76 带 0 修饰全 `noErr`）。**esc 注册失败就不让出前台**，
  否则把人锁在关不掉的遮罩里。两条路（keyDown / 热键）共用一个 `escape()`：面板开着先关面板。
  让出前台 = 自认后台 → App Nap 压采样定时器（3/s→1/s，拼接会破）→ `beginActivity(.userInitiated)`
  顶住，close 里结束。**别用 `didResignKey` 抢回前台**：跟用户抢方向盘，且激活是异步的会互相触发。

## 长图态的「完成」按钮（P2.2，2026-11-03 真机验过）

整窗 `ignoresMouseEvents` 所以画出来的按钮只是「按钮的画」。面板盖在胶囊上、**自己不画**（画仍由遮罩完成，
一份图一份真相；面板自己渲染就是第二份条形，第二份会过期）：

- `.nonactivatingPanel` + `hidesOnDeactivate=false` + `becomesKeyOnlyIfNeeded=true` + `orderFrontRegardless()`
  （`orderFront` 允许什么都不做）；卸载 `orderOut` 两次（可能正从它自己的 `mouseDown` 里卸载）。
- ⚠️ **收点击的两个硬前提**：`canBecomeKey` 必须 **true**（borderless 默认 false，此时
  **hover 进得来、click 进不去**）；窗口**不能全透明**（`.clear` + 无内容 = 窗口服务器看得穿的窗口，
  它不把按压交过来 → 给 2% 黑底，肉眼不可见）。两条是同一次构建里落的，**哪条决定性没分离出来**，
  要分只需把 `backgroundColor` 改回 `.clear` 再点一次。
- **兜底**：指针在胶囊上时遮罩自己关掉 `ignoresMouseEvents` 接这一下（`sample()` 每 0.3 s 用
  `NSEvent.mouseLocation` 同步，所以面板一个字不报也会就位）。实测三次都是面板自己收到的，兜底没触发。
- `finishLong()` 首行 `guard mode == .long`：回车、面板、遮罩三条路进来，**同一次按压只能结束一次**。
- **「完成」与帧数无关**：按钮在不在只看是不是长图态（`growing`），不看 `stitcher.count`。
  按下去交给 `longDecision(frames:hasRegion:)` 判三种——`.picture`（拼过）/ `.ordinary`（没滚过、
  或滚反了、或首帧没切出来 → **按普通截图交付**）/ `.nothing`（连框都没有）。**没滚动过不等于按钮失效，
  也绝不报错**：一个模式用「你没用我」来回答，罚的是已经confused的那个人。三种结果都进日志
  （`Capture long: Done with N frame(s) → …`），因为「按了没反应」和「按了给了张普通图」是同一按压、两种投诉。
- **胶囊宽度对所有提示都钉死**：滚反了 / 滚太快 / 顶到上限 / 区域变了大小 四条提示，**不显示时也参与测宽**
  （`measuredLines`）。提示是长图进行中才出现的，那一刻手已经在去「完成」的路上，胶囊一宽按钮就滑走。
  这几条字符串因此从 `LongStitcher.notes` / `CaptureSurface.surfaceNote` 出，不再在调用点就地写字面量。
- 代价：胶囊 440×34 是滚轮死区（指针停在那儿页面不滚）。
- 后台 app 画不出光标 → 可点性靠 hover 描一圈白。
- `L` 是裸键、走 keyDown、**不注册全局**（出口才值得借键，入口注册全局等于永久占别人的字母）。
  图例 `R · L · esc`，胶囊宽度按更长图例算（进长图时按钮凭空出现，胶囊不能同时变窄）。

## 长图浮条的 ✕ 与「选文字」（P4，2026-11-03）

- **✕ 和「完成」同住一个面板**，不是第二个窗口：两个窗口叠在同一个胶囊上，迟早有一个先被点走。
  布局从**「完成」的左边缘往上量**（`close.minX = done.minX - gap - 22`），不从画出来的东西量：
  「识别中…」时「完成」暂时不在，✕ 若按「有没有画面」定位，就会在唯一需要它的那秒挪位置。
- `mouseDown` **先判 ✕ 再判胶囊**：两点只差几个像素，误压不能变成「把截了半天的图完成掉」。
  两个回调都 `DispatchQueue.main.async` 延后一拍，因为卸载面板可能正从它自己的 `mouseDown` 里发生。
- **选文字 = 按钮「文字」+ 裸键 `W`**（`13`），与长图同构：先按（armed）再拖，是**入口**所以不注册全局。
  `W` 不是 `T`：字母要指向 App 已经教会的手势（选），`T` 挨着 `R`/`L` 会被读成「文字工具」。
- 识别结果**先给看，再给要**：选区里铺一张暗底、最多 `框高/17` 行 12 pt 文字，超出截尾；此时
  「完成」变「确认」（`doneLabel`），回车同义。中止用 ✕（`onCancel`），不产生任何东西。
- 确认后：**写字进剪贴板 → 挂一张文本卡**，不落盘、不命名、不生成图片。来源 app 记空（`Origin()`）——
  这不是那个 app 的文字，是「有人看了一张它的照片」之后写下的字。
- ⚠️ **语言探测失败不抛异常**，只返回空结果，跟「图里真的没字」无法区分：坏的识别器会让整个功能看起来
  只是「看不见字」，而没有任何一处是红的。所以自检必须真读一张写着 `Clothespeg 123` 的图（`reads ok`）。
- ⚠️ 识别**不吃长图分块**：选区就是画的那一个矩形，长图态按不了 `W`。
- 识别在 `DispatchQueue.global` 上跑：遮罩还立着、还要接点击，冻住的问题比慢一点的问题更难查。

## 翻译（P5，2026-11-03）

- **引擎 = 系统的 `Translation` 框架**（macOS 15+，本机跑、无账号、无 key、装好语言包后离线）。
  唯一的门是 SwiftUI 的 `.translationTask`：`TranslationSession` 在 15–25 上没有公开构造器
  （26 才有 `init(installedSource:target:)`，且只对**已装**语言对有效）。所以 `Translator` 里养着
  一个 **1×1 的 `NSHostingView`**（`Bridge`），窗口停在主屏左下角、`ignoresMouseEvents`、borderless
  （不可能成为 key，所以不抢前台）。
- ⚠️ **没装语言包时 `translate` 不报错，它等**——一直等。`prepareTranslation()` 才是「要语言包」的
  那个调用，而系统那个「下载语言以翻译」的框需要一个**看得见的窗口**才画得出来。所以
  `translate()` 自己先查 `LanguageAvailability.status(for:to:)`，不是 `.installed` 就把窗口
  `showHostWindow()`（屏幕中间 360×160、floating）→ `prepareTranslation()` → `parkHostWindow()`
  缩回 1×1。**窗口升降之后 session 依然可用**（探针实测：升降两次后再翻 30 ms）。
- 实测数字（本机 macOS 27.2，中英已装）：session **6–27 ms**；一段 150 字英文首译 **102–154 ms**
  （冷启 551 ms）；同会话第二次 **17–30 ms**。→ 交互上可以「按了就地出」。
- **两个门，不是一个开关**（2026-11-03 用户拍板：「截取文字」和「翻译」是两个模块）。浮条上
  `识别` 和 `译` 并排，各自裸键 `W` / `T`；**出口只有一条规律**：`识别` 结局是挂原文卡（`确认`），
  `译` 结局是译文先留在屏幕上、再按 `复制` 拿走（2026-11-03 改：拿走的那一下顺手落一张剪贴板卡，
  理由见下面「复制」那条）。合用一个开关的话，每次翻译都得先当成一次截图。
- 流程：选门 → 划区 → Vision 认字 → **认出来就自动问引擎**（`showReading` 里直接 `askTranslation`）。
  中间不要第二次按：门 + 区域已经把话说完了。`ReadingPurpose` 在 `startReading` 时**设一次**
  就不动，这是把探索阶段「复制和翻译交错、日志里隔 20 秒」那个问题从结构上掐掉的。
- **呈现：就地替换，不做对照。** 卡只有 170×210、正文 5 行，卡上做对照等于只看得见译文；
  屏幕上的选区也只有原文那么大。所以选区里就画译文，按 `复制` 拿走完事。
- **源语言自己判，绝不留给引擎猜**（2026-11-03 第二次报障后改的，参考 EasyDict 的
  `AppleLanguageDetector`）。不给 `source` 时引擎会自己判语种，判不出来就弹它自己的
  「无法自动检测语言。请选择要翻译的语言。」**然后一直等**——外面看就是「翻译中…」永不结束。
  `SourceLanguage.guess` 的次序：假名 ≥2% → `ja`；汉字 ≥20% → `zh-Hans`/`zh-Hant`（按 ICU
  `Traditional-Simplified` 的改写比例，<15% 算简体）；谚文 ≥20% → `ko`；其余交 `NLLanguageRecognizer`，
  **置信度 <0.4 就承认认不出**（给引擎一个猜的语种会换来一段通顺但错语言的译文，比说认不出更坏）。
  短英文（如 "apple"）NL 常判成土耳其语，所以这条线故意允许它给出「认不出」。
- **`Translator.translate` 先量 `LanguageAvailability.status(from:to:)` 再要 session**：
  `.unsupported` → 抛 `TranslationRefusal.unsupportedPair`；`.supported` 才 `prepareTranslation()`。
  这一条是「永不卡在翻译中」的结构保证：凡是会让引擎无限等下去的问法，都在这之前被拦掉。
- **`SourceLanguage.same` 比 `languageCode` + `script`，不比字符串**：`Locale.Language` 会规范化
  （`zh-Hans` → `zh`、`zh-Hant` → `zh-TW`、`en-US` → `en`），比 minimalIdentifier 会把
  「中文原文 + 中文系统（`zh-Hans-CN`）」判成不同语言，于是又去问引擎、又吃到一次 `nothingToTranslate`。
- **四种答复都在浮条那一行**：`翻译中…` / `读不出这段是什么语言` / `这台 Mac 还不能在这两种语言之间翻译` /
  `这段文字没能译出来`；`这段已经是这种语言了` 单独一条且 **pill 仍可点**（复制原文）。
  前三种是 `CaptureSurface.Refusal`（`unsure` / `unsupported` / `failed`）——三个答案三条下一步，
  一句话盖三种问题是上一版「无法翻译」挨骂的原因。
- 「已经是这种语言了」两条来源：自己比出来（`same`，省一次 round trip），以及引擎的
  `TranslationError.nothingToTranslate`（它不返回原样文字，它**抛错**）→ `Translator` 翻成
  `TranslationRefusal.alreadyInThisLanguage` → `showTranslationNoop()`。
- **短文本优先看脚本，再看模型**（2026-11-03 第三次报障「有时候无效」修的就是这条）。
  日志里那次是 8 个字 → `refused — unsure`：`v1.2.3版` 这类「一个汉字夹在数字里」的选区，
  汉字占比 12.5% < 20% 被漏掉，模型又没把握。现在的次序：假名>0 → ja；谚文>0（短文）或 ≥20% → ko；
  **汉字>0 且（短文 ≤12 字 或 ≥20%）→ zh**；其余交给模型。短文本模型没把握时，**纯拉丁字母 → en**，
  实在不是字母（纯数字）才认不出。
- **给英语加 0.15 的权重**（`recognise` 里改 `languageHypotheses` 再取最大）。EasyDict 的
  `applyUserPreferredLanguageWeights` 就是这个思路，抄它的理由很实在：产品名/单词是这类工具最常被
  划的选区，而模型的答案离谱——`DeepSeek` → 荷兰语、`apple` → 土耳其语。0.15 不会挪动真答案：
  法语 0.9 还是法语。
- **pill 只在「有字」且「不在翻译中」时消失，其余时候永远可点**。原来 `.failed` / `.unsure` 时
  `copyable` 为假 → pill 不画 → 用户点那块空白什么也不发生，报上来是「复制按钮不生效」。
  现在复制的是「屏幕上那段」（有译文就译文，没有就原文）。
- **点「复制」= 点整个胶囊**（2026-11-03 第三次报障「复制按钮还是无效」）。读字态那一条胶囊上只有两个
  答案——拿走、离开——所以除 ✕ 以外按在胶囊上的任何位置都算「拿走」；pill 只是**画出来的**形状，
  命中区故意比墨迹大。日志补了一行 `Capture text: bar press at x,y — pill …, live …, translating …`：
  「按了没反应」和「按钮拒绝」在外观上一样，但只有一种要修。
- **复制那一下同时落一张剪贴板卡**（`acceptCapturedText`）。剪贴板确实一直在写（日志里的读回能证明），
  但**屏幕上一个字都没变**：遮罩消失、绳上没卡、`ourWrite` 标记让 watcher 跳过 → 本 App 的剪贴板面板里
  看不见。面板就是这个人看剪贴板的窗口，于是「复制没生效」。现在卡是证据，也是真的有用。
- **复制写在 `close()` 之前**，并**读回剪贴板核对**再打日志（`pasteboard holds N character(s)`，
  不一致还会写 `NOT what was handed over`）。「按钮没反应」和「复制没落到剪贴板」在外部是同一种报告，
  日志得分得开。
- `CaptureSurface` 加了 `acceptsFirstMouse → true`：截图是一次性工具，按一下就该响，
  不该第一下只用来激活窗口。
- **学 EasyDict 但没抄的**：多引擎注册表（`QueryService` + 语言对 + 密钥配置）——用户明确只要系统内置，
  没有第二个引擎就没有选择的必要；它的「翻译视图必须挂进一个窗口」我们早就满足（1×1 停在角落）。
  它的 `AppleTranslation` 里有一条对我们有用的备注：**系统引擎不区分简繁**（`zh-Hans` 与
  `zh-Hant` 对它都是 `zh`），所以简↔繁不是翻译，是转换，别指望引擎。

- 目标语言 = 设置页「译成」`TranslationTarget`（`system` / English / 简体中文 / 繁體中文，
  默认「同系统」）。**必须可配**：中文系统 + 中文原文 + 想译成英文，任何默认值都猜不出来。
- 卡上不再留原文（`Pegged.original` / `Attic.Entry.original` / 右键「复制原文」2026-11-03 全部撤掉）：
  译文就地替换了原文，留原文就没有去处。`hang(...)` 也回到四参数。
- 译文卡落的是**剪贴板面板**那张（`acceptCapturedText`），不是便签：它证明「复制」发生了，
  而且下一次 ⌘V 想要的正是它。


## 重截（Again，2026-11-03）

- **按钮在浮条最后一个**（`比例 · 长图 · 文字 · 译 · 重截`），没有裸键：其余四个回答「这块区域是什么」，
  它回答「还是那块」——而那块还不存在时它无从说起。所以它**是动作不是模式**，无键、不填充。
  胶囊宽跟着它变（有记忆才画），但不跟着状态变，不会在手指下方跳。
- ⚠️ **它把框放回来，不当场截**（2026-11-03 第二轮用户改的口径：「点一下重载，不一定是要直接去截图……
  让原来的框直接出现在原来的位置，然后由用户去双击或选择」）。第一版是按下就拍，理由站不住：
  这个按钮服务的场景恰恰是**页面已经动了**，而一个不给人看就按记忆矩形拍下去的按钮，
  是「很有把握地拍错地方」。所以：框回到原位、带八个手柄、浮条回到「拖动边调整 · 回车截取」，
  双击 / 回车 = 截，拖边 = 调，点窗口 / 点门 = 改主意，esc = 走。
- **放回来的框就是普通的框**（`CaptureSurface.restore(_:)` 只设 `selection`，别的什么都不做）。
  测试里用**合成双击**（`NSEvent.mouseEvent` + `mouseDown`）证明它走的是同一条 `onFinish`——
  给重载的框另立规则，就是给「框是什么」写第二份定义。
- **同一个显示器就不重建窗口**：直接往已经立着的遮罩里 `restore`，没有第二次抓屏、没有闪一下；
  它要裁的底图和手画的框要裁的是同一张，所以不损失准确。跨显示器（遮罩只有一块屏宽）才
  `close()` + `begin(restoring:on:)`，用 `pendingRestore` 把框带过去。
- **记的是「类型 + 矩形」**，`LastCapture`（`Capture/LastCapture.swift`），JSON 存 `UserDefaults`
  （`lastCapture`），不是内存：这个按钮服务的场景是「过一会儿那块面板再来一次」，中途重启是常态。
- **类型照记，但不替人选门**：`area` / `window`(+id) / `screen` / `long` / `words` / `translate`
  六种都写进记录、也都进日志，可**重载只还原框**——要不要再译一次是人的一次按键（框还在，
  按 `T` 立刻读这块），不是按钮替他按的。原先那套 `Replay` 退化表（window 没了 → 拍那块地方、
  long → 第一帧）随「按下就拍」一起删掉了；**没有调用方的退化规则不如没有**。
- **只在落地时记，取消不记**：`finish` → `.area`/`.screen`、`pick` → `.window`（存 windowID）、
  `finishLong` → `.long`（存**长图起始框**，不是拼出来的高度）、`read` → `.words`、
  `translate` → `.translate`（引擎还没答就记：记的是问题在哪儿，不是答案）。
  画完框又 esc 的那块正是他想离开的那块，不能被「重截」记成默认。

## 自检与离屏

- 离屏：`CLOTHESPEG_CAPTURE_PREVIEW` + `_SELECT` / `_RATIO=<CropAspect.title>` / `_PANEL` / `_HOVER` /
  `_LONG=<pt>` / `_READ`（有字的一套）/ `_TRANSLATED=<译文>`（译文态浮条）/ `_NOTE`（=1 显示「往上滚了」）；
  会失败的检查 `capture ratios:` / `capture frame:` / `capture long:` / `capture keys:` /
  `capture done:`（反向：比例分支短接成 `if false` 出 `WRONG SHAPE`；`likeness` 放到 1.0 出
  `overlap WRONG`；按钮改成跟着数字右对齐出 `steady WRONG (moved with the readout)`；
  把某条提示从 `measuredLines` 里去掉出 `note steady WRONG`）/ `capture text:`（把 `PictureText`
  的语言探测弄坏 → `reads WRONG`；把 `showReading` 里那句自动 `askTranslation` 删掉 →
  `asks by itself WRONG`；让 `showTranslationNoop` 不清 `translating` → `already in it WRONG`）/
  `translate:`（session 拿不到就 `NO SESSION — the SwiftUI bridge is broken`；**这行故意不调
  `translate`**，因为没装语言包时那会一直等）；`capture language:`（纯函数，机器无关：
  简/繁/英/日、纯数字、`apple` 这种短英文、`same` 的简繁之分与「中文原文→中文系统」那一对）/
  `capture again:`（`hidden until used`：没记忆不画按钮；`remembers`：类型 + 矩形过一遍 defaults
  原样回来；`frame back`：`restore` 之后 `region` 就是那块、浮条仍是截图浮条；`double-click takes it`：
  **合成双击**打在同一条 `onFinish` 上；`button`：按在**画出来的**那块矩形的中心能不能到回调；
  `pill at the end`：pill 右缘和最后一个按钮齐平、且不压回 `译`）。
- `capture done:` 里两条与「没滚动」直接相关：`no scroll`（0 帧、1 帧都必须 `.ordinary`）、
  `pill without scrolling`（空 stitcher 也必须有按钮）。**这正是「长图没滚过，完成是不是就废了」
  这个疑问的判据**，别再靠嘴答。
- **挂具不许自己造数据**：`CaptureSelfTest.render` 造预览矩形必须走实现同一个 `rectangle(...)`，
  否则会画出 App 永远画不出的形状（9:16 那次被尺寸牌带出屏幕，看图会误判成实现有 bug）。
- ⚠️ **合成按压走 `panel.sendEvent` 绕过了窗口服务器**：`capture done: click ok` 只证明面板的分发能到
  回调，**不证明真点击会交过来**。同理 `NSWindow` 对不在屏上的窗口会静默丢弃鼠标事件 → 合成前必须
  `orderFrontRegardless()` + 泵一下 runloop。
- ⚠️ `capture compare` 比对的是两次实时抓屏，中间画面一动就抖（见过 0.0624 / 0.0569 / 0.0000，
  阈值 0.06）。它红一次不算回归。

## 没做

- P3 横向长图（用户 2026-11-03 明确暂缓）。翻译不挂便签卡，所以「卡上中英对照」这个方向已废；
  空格预览里的对照、按需翻译旧卡，都还没做。
- 重截没有裸键，也没有菜单栏入口：入口在浮条上，先按截图快捷键再按它。真嫌多一步再加全局热键。
- 重截只放回框，不恢复当时的比例锁 / 门 / 长图态；也不记住鼠标位置与窗口焦点。
- 面板的键盘导航、胶囊死区里的滚轮转发、识别结果就地可改。
- P0 尾巴：多显示器（现在只给指针那块屏压暗）、`⌘A` 全屏、方向键微调 / ⇧ 临时解锁比例。
