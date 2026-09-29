import SwiftUI
import StudyShell

struct SuanDataView: View {
    @EnvironmentObject private var store: AppDataStore
    var body: some View {
        TransferView(title: "简单算", exportData: { try store.exportData() }, preview: { data in
            let backup = try SuanBackup.decode(data)
            return "已完成练习：\(backup.sessions.count) 次\n作答：\(backup.sessions.reduce(0) { $0 + $1.questions.count }) 题"
        }, restore: { data in
            let backup = try SuanBackup.decode(data)
            if store.loadError == nil {
                try ModuleStorage.saveSafetyBackup(store.exportData(), module: "SimpleSuan")
            }
            try store.restore(backup)
        })
    }
}
