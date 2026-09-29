#!/usr/bin/env python3
"""Exercise the actual Foundation-only listening core on Mac. No iPad installation."""
from pathlib import Path
import argparse
import json
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--materials', type=Path, help='Optional local directory with the seven reviewed Day Markdown files; never added to the project.')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix='SimpleTingValidation-', dir='/private/tmp'))
core = work/'Sources/SimpleTing'
core.mkdir(parents=True)
for source in (root/'Modules/SimpleTing/Sources/Core').glob('*.swift'):
    shutil.copy2(source, core/source.name)
shell = work/'Sources/StudyShell'
shell.mkdir(parents=True)
shutil.copy2(root/'Shared/AudioOwnership.swift', shell/'AudioOwnership.swift')
tests = work/'Tests/SimpleTingTests'
tests.mkdir(parents=True)
for source in (root/'Modules/SimpleTing/Tests').glob('*.swift'):
    shutil.copy2(source, tests/source.name)
fixtures = tests/'Fixtures'
fixtures.mkdir()
(fixtures/'README.txt').write_text('Private material input is optional and used only in this temporary validation package.\n')
if args.materials:
    expected = {'Day 01.md':1,'Day 02.md':1,'Day 03.md':1,'Day 04.md':2,'Day 05.md':3,'Day 06.md':2,'Day 07.md':2}
    corpus = [{'name': name, 'text': (args.materials/name).read_text(encoding='utf-8-sig'), 'count': count} for name,count in expected.items()]
    (fixtures/'corpus.json').write_text(json.dumps(corpus,ensure_ascii=False),encoding='utf-8')
shell_tests = work/'Tests/StudyShellTests'
shell_tests.mkdir(parents=True)
shutil.copy2(root/'Tests/Core/AudioOwnershipTests.swift',shell_tests/'AudioOwnershipTests.swift')
(work/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SimpleTingValidation", platforms: [.macOS(.v15)], targets: [
    .target(name: "SimpleTing"), .target(name: "StudyShell"),
    .testTarget(name: "SimpleTingTests", dependencies: ["SimpleTing"], resources: [.copy("Fixtures")]),
    .testTarget(name: "StudyShellTests", dependencies: ["StudyShell"])
], swiftLanguageModes: [.v5])
''')
print(f'Validation package: {work}',flush=True)
subprocess.run(['swift','test','--disable-sandbox','--package-path',str(work),'--scratch-path','/private/tmp/SimpleTingValidationBuild','--cache-path','/private/tmp/SimpleTingPackageCache'],check=True)
