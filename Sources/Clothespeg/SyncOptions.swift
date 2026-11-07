import Foundation

/// 导入导出的四个内容类别，以及它们之间不能含糊的几条规则。
///
/// 产品口径（2026-11-06 晚）：自动 iCloud 同步**不做**（开发者账号与 Apple
/// 服务都会给买断功能带上隐含有效期），改为手动导入导出。这四个开关从
/// 「同步什么」变成「这次导出 / 导入包含什么」，一次勾选同时管两个按钮。
/// 默认**全开**：导出是用户主动点、主动选文件夹的动作，不像后台同步会
/// 偷偷占用配额，第一次打开不该是「一个都没勾、按钮点不动」的状态。
///
/// ⚠️ 类型名和自检环境变量仍叫 Sync*，是历史名字，为了不动一堆引用保留。
/// 语义已经不是同步，读代码时别按同步理解。
///
/// 访达里复制的文件永远不参与迁移：那是本机路径引用，到另一台 Mac 上
/// 是一张死卡。

enum SyncOption: String, CaseIterable, Identifiable {
    /// 历史里的 `Payload.text`
    case clipboardText
    /// 历史里的 `Payload.image` 及其 Pictures/ 文件（只跟挂成卡的图片走）
    case images
    /// `Notes.json` 里的便签本体，含 `Note.Recording` 的元数据
    case notes
    /// 便签里 `Note.Recording` 指向的 Recordings/ 音频**文件本体**。
    /// 元数据（文件名 / 秒数 / 波形）不算在这里，它跟便签一起走。
    case noteRecordings

    var id: String { rawValue }

    var defaultsKey: String { "Transfer.\(rawValue)" }

    /// 录音是便签的附属：便签没开，带过去就是一段没有宿主的音频。
    /// 反过来的组合（便签开、录音关）是合法的，由 `SyncNoteLanding` 处理。
    var requires: SyncOption? {
        self == .noteRecordings ? .notes : nil
    }

    /// 每个标题都写成字符串字面量，别改成动态 key：字符串自检脚本扫的是
    /// 源码里写死的本地化调用，动态拼出来的词它扫不到，会当成没用过。
    /// （注释里也不要写出那个调用的字面形式，脚本连注释一起扫。）
    var title: String {
        switch self {
        case .clipboardText: L("Clipboard text")
        case .images: L("Pictures in history")
        case .notes: L("Notes")
        case .noteRecordings: L("Recordings in notes")
        }
    }
}

/// 一条历史卡属于哪个内容类别。按 `Payload` 的 case 分流，类别之间不混：
/// 混了就会出现「没勾图片，却把图片卡的路径或 OCR 文字带过去」这种漏。
/// `.note` 带的是整张 `Note`，其中 `recording` 字段只是元数据，不含音频字节。
enum SyncChannel: String, CaseIterable {
    case text, image, note, file

    init(_ payload: Payload) {
        switch payload {
        case .text: self = .text
        case .image: self = .image
        case .note: self = .note
        case .file: self = .file
        }
    }
}

/// 纯规则，不碰 UserDefaults。自检可以拿任意组合来问，不会动到用户
/// 已经存下的真实设置。
enum SyncRules {
    static func isOn(_ option: SyncOption, in enabled: Set<SyncOption>) -> Bool {
        enabled.contains(option)
    }

    /// 一个开关现在能不能拨。依赖没开就是灰显。
    static func isAvailable(_ option: SyncOption, in enabled: Set<SyncOption>) -> Bool {
        guard let required = option.requires else { return true }
        return enabled.contains(required)
    }

    /// 依赖被关掉时，附属开关要跟着关，不能留一盏「开着却不生效」的灯。
    /// 按 allCases 顺序遍历、拿 result 自己判，依赖链加长也不会漏。
    static func resolving(_ enabled: Set<SyncOption>) -> Set<SyncOption> {
        var result = enabled
        for option in SyncOption.allCases where !isAvailable(option, in: result) {
            result.remove(option)
        }
        return result
    }

    /// `.file` 永远返回 false：文件迁移明确不做，跟其他三个开关无关。
    static func allows(_ channel: SyncChannel, in enabled: Set<SyncOption>) -> Bool {
        switch channel {
        case .text: return enabled.contains(.clipboardText)
        case .image: return enabled.contains(.images)
        case .note: return enabled.contains(.notes)
        case .file: return false
        }
    }

    static func allows(_ payload: Payload, in enabled: Set<SyncOption>) -> Bool {
        allows(SyncChannel(payload), in: enabled)
    }
}

/// 便签落地时的契约（2026-11-06 拍板的方案 1）。
///
/// `Note.Recording` 的三个字段是**元数据**：文件名、秒数、二十根波形。
/// 它们只有几十字节，跟便签的文字一起走，不受录音开关控制；开关只管
/// `Recordings/` 里那个 `.m4a` 文件本体。
///
/// ⚠️ 落地时**绝不能把 `recording` 字段剥掉**求「干净」：
/// ① `Note.isBlank` 靠 `recording != nil` 让「只录了音、一个字没写」的
/// 便签成立，剥掉它整张卡会被当成空白挂不上线；
/// ② 引用没了，以后打开录音开关也无从补上；
/// ③ 双向合并时缺字段的那版回写，会把源机上的引用一起抹掉。
/// 文件暂时不在本机只意味着「不可播放」，不是「便签变了」。
enum SyncNoteLanding {
    /// 元数据是否随这张便签走。只看便签开关。
    static func carriesMetadata(in enabled: Set<SyncOption>) -> Bool {
        SyncRules.allows(.note, in: enabled)
    }

    /// 音频文件是否随行。两个开关都开着才传。
    static func carriesAudio(in enabled: Set<SyncOption>) -> Bool {
        carriesMetadata(in: enabled) && SyncRules.isOn(.noteRecordings, in: enabled)
    }
}

/// 真实状态。拆出 `resolves` 是为了让自检能验「没存过 = 开」，而不必
/// 读写用户自己的设置。
enum SyncOptions {
    static func resolves(_ stored: Bool?) -> Bool { stored ?? true }

    static func isOn(_ option: SyncOption) -> Bool {
        resolves(UserDefaults.standard.object(forKey: option.defaultsKey) as? Bool)
    }

    static func set(_ option: SyncOption, on: Bool) {
        UserDefaults.standard.set(on, forKey: option.defaultsKey)
        if option == .notes, !on {
            UserDefaults.standard.set(false, forKey: SyncOption.noteRecordings.defaultsKey)
        }
        SettingsAnswers.announce(option.defaultsKey)
    }

    static var enabled: Set<SyncOption> {
        SyncRules.resolving(Set(SyncOption.allCases.filter(isOn)))
    }
}

/// `CLOTHESPEG_SYNC_PROBE=<path>` 时跑。全程只用纯规则，不读写用户的
/// UserDefaults、不碰网络，所以没有账号配置也能验。
enum SyncProbe {
    static func run() -> String {
        var lines = ["sync probe:"]

        lines.append(SyncOptions.resolves(nil) && !SyncOptions.resolves(false)
                     ? "PASS  unset scope defaults on, explicit off stays off"
                     : "FAIL  default scope broken")

        let nothing: Set<SyncOption> = []
        for option in SyncOption.allCases {
            let off = !SyncRules.isOn(option, in: nothing)
            lines.append("\(off ? "PASS" : "FAIL")  \(option.rawValue): out of empty scope")
        }

        let recordingsOnly: Set<SyncOption> = [.noteRecordings]
        let unavailable = !SyncRules.isAvailable(.noteRecordings, in: recordingsOnly)
        lines.append("\(unavailable ? "PASS" : "FAIL")  recordings without notes: unavailable")
        let cleared = SyncRules.resolving(recordingsOnly).isEmpty
        lines.append("\(cleared ? "PASS" : "FAIL")  recordings without notes: cleared on resolve")

        let withNotes: Set<SyncOption> = [.notes, .noteRecordings]
        let available = SyncRules.isAvailable(.noteRecordings, in: withNotes)
        lines.append("\(available ? "PASS" : "FAIL")  recordings with notes: available")

        let all: Set<SyncOption> = Set(SyncOption.allCases)
        let expected: [SyncChannel: Bool] = [.text: true, .image: true, .note: true, .file: false]
        for channel in SyncChannel.allCases {
            let got = SyncRules.allows(channel, in: all)
            lines.append("\(got == expected[channel] ? "PASS" : "FAIL")  channel \(channel.rawValue): \(got)")
        }
        lines.append("\(SyncRules.allows(.text, in: [.clipboardText]) ? "PASS" : "FAIL")  text alone: on")
        lines.append("\(!SyncRules.allows(.image, in: [.clipboardText]) ? "PASS" : "FAIL")  image off while text on: stays local")

        // 便签开、录音关：元数据必须还在，只有音频文件留在本地。
        let notesOnly: Set<SyncOption> = [.notes]
        lines.append(SyncNoteLanding.carriesMetadata(in: notesOnly)
                     && !SyncNoteLanding.carriesAudio(in: notesOnly)
                     ? "PASS  notes only: metadata stays, audio stays local"
                     : "FAIL  notes only: landing contract broken")
        lines.append(SyncNoteLanding.carriesAudio(in: withNotes)
                     ? "PASS  notes + recordings: audio travels"
                     : "FAIL  notes + recordings: audio was dropped")
        lines.append(!SyncNoteLanding.carriesMetadata(in: nothing)
                     && !SyncNoteLanding.carriesAudio(in: recordingsOnly)
                     ? "PASS  no notes: orphan audio cannot escape"
                     : "FAIL  no notes: orphan audio escaped")

        // 钉住「为什么不能剥字段」：一张只有声音的便签，即使音频文件
        // 不在这台 Mac 上，也仍然是一张便签。
        let voice = Note.Recording(name: "not-synced.m4a", seconds: 9,
                                   bars: [10, 40, 80, 25])
        lines.append(!Note(text: "", recording: voice).isBlank
                     ? "PASS  voice-only note survives without its audio file"
                     : "FAIL  voice-only note would be dropped as blank")

        return lines.joined(separator: "\n")
    }
}
