#!/usr/bin/env python3
"""Run the production reading-package, progress, storage and backup core on macOS."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix='SimpleDuValidation-', dir='/private/tmp'))
for source_dir, destination in [
    (root/'Modules/SimpleDu/Sources/Core', work/'Sources/SimpleDu'),
    (root/'Modules/SimpleDu/Tests', work/'Tests/SimpleDuTests'),
]:
    destination.mkdir(parents=True)
    for source in source_dir.glob('*.swift'):
        shutil.copy2(source, destination/source.name)
shutil.copy2(root/'Modules/SimpleDu/Sources/Views/DuPagination.swift', work/'Sources/SimpleDu/DuPagination.swift')
shell = work/'Sources/StudyShell'
shell.mkdir(parents=True)
for name in ['ModuleSession.swift', 'WholeBackup.swift', 'AudioOwnership.swift']:
    shutil.copy2(root/'Shared'/name, shell/name)
shell_tests = work/'Tests/StudyShellTests'
shell_tests.mkdir(parents=True)
shutil.copy2(root/'Tests/Core/WholeBackupTests.swift', shell_tests/'WholeBackupTests.swift')
(work/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SimpleDuValidation", platforms: [.macOS(.v15)], targets: [
    .target(name: "StudyShell"),
    .target(name: "SimpleDu", dependencies: ["StudyShell"], linkerSettings: [.linkedLibrary("z")]),
    .testTarget(name: "SimpleDuTests", dependencies: ["SimpleDu"]),
    .testTarget(name: "StudyShellTests", dependencies: ["StudyShell"])
], swiftLanguageModes: [.v5])
''')
print(f'Validation package: {work}', flush=True)
subprocess.run(['swift', 'test', '--disable-sandbox', '--package-path', str(work),
                '--scratch-path', '/private/tmp/SimpleDuValidationBuild',
                '--cache-path', '/private/tmp/SimpleDuPackageCache'], check=True)
