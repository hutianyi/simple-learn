import SwiftUI
import StudyShell

public struct SimpleMoModuleView: View {
    public init() {}
    public var body: some View {
        ContentView().defaultAppStorage(MoBackup.defaults)
    }
}
