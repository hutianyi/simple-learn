#!/usr/bin/env python3
"""Run production data/backup rules on macOS, without requiring an iPadOS runtime."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="SimpleXueCoreValidation-", dir="/private/tmp"))


def copy(source, target, name=None):
    destination = work / target / (name or source.name)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


copy(root / "Shared/ModuleSession.swift", "Sources/StudyShell")
copy(root / "Shared/AudioOwnership.swift", "Sources/StudyShell")
ji = root / "Modules/SimpleJi"
for part in ["Import", "SRS", "Models", "Dictation", "Backup", "Settings", "Persistence"]:
    for source in (ji / "Sources/Core" / part).glob("*.swift"):
        copy(source, "Sources/WordMemoryCards")
copy(ji / "Sources/Features/Review/ReviewSessionViewModel.swift", "Sources/WordMemoryCards")
view_model = work / "Sources/WordMemoryCards/ReviewSessionViewModel.swift"
view_model.write_text(view_model.read_text().replace("import Foundation", "import Foundation\nimport Combine"))
resources = work / "Sources/WordMemoryCards/Resources"
resources.mkdir()
subprocess.run(["xcrun", "momc", str(ji / "Sources/Core/Persistence/WordMemoryCards.xcdatamodeld"),
                str(resources / "WordMemoryCards.momd")], check=True)
for source in (ji / "Tests").glob("*.swift"):
    if source.name not in ["SpeechServiceTests.swift", "BackupViewModelAlertTests.swift", "DictationRepositoryTests.swift"]:
        copy(source, "Tests/WordMemoryCardsTests")

lian = root / "Modules/SimpleLian"
for folder in [lian / "Core", lian / "Sources/Models", lian / "Sources/Services"]:
    for source in folder.glob("*.swift"):
        if source.name != "BackupService.swift":
            copy(source, "Sources/SimpleLian")
# SwiftUI presentation types are unnecessary for exercising the original backup service.
backup = (lian / "Sources/Services/BackupService.swift").read_text()
backup = backup.split("struct BackupDocument:", 1)[0].replace("import SwiftUI\n", "").replace("import UniformTypeIdentifiers\n", "")
(work / "Sources/SimpleLian/BackupService.swift").write_text(backup)
(work / "Sources/SimpleLian/AppSchema.swift").write_text("""import SwiftData
enum AppSchema {
    static let schema = Schema([ImportBatch.self, ProblemGroup.self, Question.self,
        ReviewState.self, PracticeSession.self, Attempt.self, SessionGroupProgress.self])
}
""")
for folder in [lian / "Tests", lian / "CoreTests"]:
    for source in folder.glob("*.swift"):
        copy(source, "Tests/SimpleLianTests")
        destination = work / "Tests/SimpleLianTests" / source.name
        destination.write_text(destination.read_text().replace("@testable import SimpleLianCore", "@testable import SimpleLian"))

for name in ["DictationCore.swift", "DictationTiming.swift", "MoBackup.swift"]:
    copy(root / "Modules/SimpleMo/Sources" / name, "Sources/DictationApp")
for source in (root / "Modules/SimpleMo/Tests").glob("*.swift"):
    copy(source, "Tests/DictationAppTests")

for name in ["Models.swift", "QuestionGenerator.swift", "StatisticsCalculator.swift", "SuanBackup.swift",
             "PersistenceService.swift", "AppDataStore.swift", "PracticeViewModel.swift"]:
    copy(root / "Modules/SimpleSuan/Sources" / name, "Sources/SimpleSuan")
for source in (root / "Modules/SimpleSuan/Tests").glob("*.swift"):
    copy(source, "Tests/SimpleSuanTests")
for source in (root / "Tests/Core").glob("*.swift"):
    copy(source, "Tests/StudyShellTests")

(work / "Package.swift").write_text("""// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SimpleXueCoreValidation", platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/open-spaced-repetition/swift-fsrs.git",
        revision: "4fbaf20184d62f82a9f44f343337c61a2c5483e9")],
    targets: [
        .target(name: "StudyShell"),
        .target(name: "WordMemoryCards", dependencies: ["StudyShell", .product(name: "FSRS", package: "swift-fsrs")],
            resources: [.copy("Resources/WordMemoryCards.momd")]),
        .target(name: "SimpleLian", dependencies: ["StudyShell"]),
        .target(name: "DictationApp", dependencies: ["StudyShell"]),
        .target(name: "SimpleSuan"),
        .testTarget(name: "WordMemoryCardsTests", dependencies: ["WordMemoryCards", .product(name: "FSRS", package: "swift-fsrs")]),
        .testTarget(name: "SimpleLianTests", dependencies: ["SimpleLian"]),
        .testTarget(name: "DictationAppTests", dependencies: ["DictationApp"]),
        .testTarget(name: "SimpleSuanTests", dependencies: ["SimpleSuan"]),
        .testTarget(name: "StudyShellTests", dependencies: ["StudyShell"])
    ], swiftLanguageModes: [.v5])
""")
print(f"Validation workspace: {work}", flush=True)
subprocess.run(["swift", "test", "--package-path", str(work), "--scratch-path",
                "/private/tmp/SimpleXueCoreValidationBuild"], check=True)
