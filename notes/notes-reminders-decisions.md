# 便签、提醒与两张卡的手势 —— 已拍板的设计决定

> 从 `.workbuddy/memory/MEMORY.md` 外置而来（2026-11-03 重建时拆出）。
> 相关：`notes/dev-backlog.md` 的 #3 / #4 / #12 条目、`notes/roadmap-capture-and-editor.md`。

## 两张卡的手势（用户拍板，别再改）

| 动作 | 剪贴板卡 | 便签卡 |
|---|---|---|
| 双击 | 粘贴到前台 | 粘贴到前台 |
| 空格 | 预览 | 预览 |
| 拖出 | 即用 | 即用 |
| 长按 | 编辑 | 编辑 |
| 角标 | 预览 | 编辑器 |
| **单击** | **复制** | **只响应勾选框** |

**单击有意保留差异**：剪贴板卡单击=复制，便签卡单击=只响应勾选框。新增手势先问
「两种卡各自最有用的动作是什么」，不要为了对称而对称。

## 智能提醒（#12，🟡待测）

- **单一落盘门 = `saveNotes` → reconcile + retime**（精确 `Timer`）；分钟对齐；过期单次补响。
- **草稿平时不落盘**，改动经 `NoteDraft.commitLive` rewrite。
- **显示口径（拍板）**：卡片脚注只写「下次 + 日期时间」，**不写规则名**；单次响过 = 「提醒已到」；
  规则只在编辑器左栏。
- TCC denied 会**静默吞横幅**（没有报错，别指望界面会说）。

## 提醒灯可推导

`ringingNoteIDs` + `Note.isRinging` 由 `lastOccurrence` 与 `remindAcked` 算出
（**不是**另一个要维护的状态）；刷新点必须含 `NSWorkspace.didWakeNotification`；**没有有效期**。
老数据靠一次性迁移 `reminderAnswersSettled`。

## ⚠️ `Note` 是手写 Codable

加字段必须同步三处：`CodingKeys`、`init(from:)`、`encode(to:)`；另需 `Note.tidied` /
`Note.toggling` / `NoteDraft`——漏一处就「勾个勾选框把应答抹掉、灯又亮了」。
（与 Flyring `Options` 的四处同款坑，但这里**没有**反射测试兜底。）

## 面板裸字母热键

**已全部停用**（会被别的 App 打字吃掉）：`Door.panelDoors = []`，重开 = 加回数组 + 解注释。
判断「热键摸不到」先看日志里的门名。
