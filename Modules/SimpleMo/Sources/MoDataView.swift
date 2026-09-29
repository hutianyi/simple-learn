import SwiftUI
import StudyShell

struct MoDataView: View {
    var body: some View {
        TransferView(title: "简单默", exportData: { try MoBackup.encode(.snapshot()) }, preview: { data in
            let backup = try MoBackup.decode(data)
            return "词语：\(DictationCore.parseWords(from: backup.settings.inputText).count) 个\n包含词语原文、随机顺序、语速、重读和切词时间。"
        }, restore: { data in
            let backup = try MoBackup.decode(data)
            try ModuleStorage.saveSafetyBackup(MoBackup.encode(.snapshot()), module: "SimpleMo")
            backup.apply()
        })
    }
}
