#!/usr/bin/env python3
"""Test the real SimpleBei text, storage and cache rules without a device or microphone."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="SimpleBeiValidation-", dir="/private/tmp"))
for source_dir, destination in [(root / "Modules/SimpleBei/Sources/Core", work / "Sources/SimpleBei"),
                                (root / "Modules/SimpleBei/Tests", work / "Tests/SimpleBeiTests")]:
    destination.mkdir(parents=True)
    for source in source_dir.glob("*.swift"):
        shutil.copy2(source, destination / source.name)
shutil.copy2(root / "Modules/SimpleBei/Sources/Services/BeiLibraryStore.swift", work / "Sources/SimpleBei/BeiLibraryStore.swift")
shell = work / "Sources/StudyShell"
shell.mkdir(parents=True)
shutil.copy2(root / "Shared/ModuleSession.swift", shell / "ModuleSession.swift")
(work / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SimpleBeiValidation", platforms: [.macOS(.v15)], targets: [
    .target(name: "StudyShell"),
    .target(name: "SimpleBei", dependencies: ["StudyShell"]),
    .testTarget(name: "SimpleBeiTests", dependencies: ["SimpleBei"])
], swiftLanguageModes: [.v5])
''')
print(f"Validation package: {work}", flush=True)
subprocess.run(["swift", "test", "--disable-sandbox", "--package-path", str(work),
                "--scratch-path", "/private/tmp/SimpleBeiValidationBuild",
                "--cache-path", "/private/tmp/SimpleBeiPackageCache"], check=True)
