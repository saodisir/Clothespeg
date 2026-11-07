import AppKit

/// The two buttons on the paid-features page. Kept out of the SwiftUI view
/// so the view stays a description of the page and nothing else. Both read
/// the same four ticked categories, so export and import cannot disagree.
enum TransferActions {
    static func exportData(scope: Set<SyncOption>) {
        guard !scope.isEmpty, let parent = chooseFolder() else { return }
        do {
            let (_, report) = try Transfer.export(from: .live, into: parent, scope: scope)
            announce(L("Export complete"), counts(report))
        } catch {
            announce(L("Export failed"), error.localizedDescription)
        }
    }

    static func importData(scope: Set<SyncOption>) {
        guard !scope.isEmpty, let chosen = chooseFolder() else { return }
        guard let bundle = Transfer.resolve(chosen) else {
            announce(L("Import failed"), TransferError.badBundle.localizedDescription)
            return
        }
        do {
            let report = try Transfer.importBundle(bundle, into: .live, scope: scope)
            announce(L("Import complete"),
                     counts(report) + "\n"
                        + L("Restart Clothespeg to see the imported cards."))
        } catch {
            announce(L("Import failed"), error.localizedDescription)
        }
    }

    private static func counts(_ report: TransferReport) -> String {
        String(format: L("Notes %@ · Cards %@ · Pictures %@ · Recordings %@"),
               "\(report.notes)", "\(report.history)",
               "\(report.pictures)", "\(report.recordings)")
    }

    private static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func announce(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }
}
