import SwiftUI

public struct SimpleSuanModuleView: View {
    @StateObject private var store = AppDataStore()
    public init() {}
    public var body: some View {
        VStack(spacing: 0) {
            if let error = store.loadError {
                Text("历史记录读取失败，请保留数据：\(error)")
                    .font(.footnote).foregroundStyle(.red).padding()
            }
            ContentView().environmentObject(store)
        }
    }
}
