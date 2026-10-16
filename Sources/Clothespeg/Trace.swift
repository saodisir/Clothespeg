import Foundation

/// 轻量运行日志：所有诊断输出统一收口到这里。
///
/// 照 Flyring 的 FlyringLog 同款：诊断不该只进系统统一日志（那个用户找不到、
/// 排查时也拿不出来），要有一个能直接打开、能导出发人的文件。
///
/// - 位置：`~/Library/Application Support/Clothespeg/logs/Clothespeg.log`
/// - 轮转：超过 1 MB 转为 `Clothespeg.old.log`，只保留一代，不会无限增长。
/// - 线程：专用串行队列异步写，调用方零阻塞；崩溃前最后几条可能丢失
///   （可接受的取舍——崩溃报告本身由系统收集）。
enum ClothespegLog {
    private static let queue = DispatchQueue(label: "app.clothespeg.log", qos: .utility)
    private static let maxBytes: UInt64 = 1_000_000

    /// 日志目录（"打开日志文件夹"在 Finder 打开的就是它）。
    static var directoryURL: URL {
        let dir = baseDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 当前日志 + 上一轮转日志的合并文本（导出用，按时间先后拼接）。
    static var allText: String {
        let current = (try? String(contentsOf: directoryURL.appendingPathComponent("Clothespeg.log"), encoding: .utf8)) ?? ""
        let old = (try? String(contentsOf: directoryURL.appendingPathComponent("Clothespeg.old.log"), encoding: .utf8)) ?? ""
        return old + current
    }

    private static var baseDirectory: URL {
        // 必须落到 .../Application Support/Clothespeg/（与 History.json 同级）。
        // Flyring 踩过的坑：漏拼一级就写进 Application Support/logs/，
        // 用户在日志文件夹按钮里看不到。
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { $0.appendingPathComponent("Clothespeg", isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
    }

    static func write(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async {
            rotateIfNeeded()
            let url = directoryURL.appendingPathComponent("Clothespeg.log")
            if let fh = try? FileHandle(forWritingTo: url) {
                defer { try? fh.close() }
                fh.seekToEndOfFile()
                fh.write(Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    private static func rotateIfNeeded() {
        let url = directoryURL.appendingPathComponent("Clothespeg.log")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, size > maxBytes else { return }
        let old = directoryURL.appendingPathComponent("Clothespeg.old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    /// 最近的 Clothespeg 崩溃报告（系统收集的 .ips，位于
    /// ~/Library/Logs/DiagnosticReports）。按修改时间取最新一份，超长截断
    /// （崩溃报告头部已含关键信息）；没有则返回 nil。
    static var latestCrashReportText: String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newest = files
            .filter { $0.lastPathComponent.hasPrefix("Clothespeg-") && $0.pathExtension == "ips" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .first
        guard let newest else { return nil }
        let text = (try? String(contentsOf: newest, encoding: .utf8)) ?? ""
        return String(text.prefix(300_000))
    }

    /// 导出诊断包：运行日志 + 最近一份崩溃报告合并为一个文本文件。
    static func exportPackage(to url: URL) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var text = "Clothespeg 诊断包\n"
        text += "导出时间: \(formatter.string(from: Date()))\n"
        text += "系统版本: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        text += "\n===== 运行日志 =====\n"
        let logs = allText
        text += logs.isEmpty ? "（无运行日志）\n" : logs
        text += "\n===== 崩溃报告（最近一份）=====\n"
        text += latestCrashReportText ?? "（未找到崩溃报告）\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// 全局诊断入口。诊断行从这里进日志文件；系统统一日志只留给 os.Logger
/// 那几条运行时错误。
func diagLog(_ message: String) {
    ClothespegLog.write(message)
}
