#!/usr/bin/env python3
"""Read a downloaded Xcode app container and export only the requested learning data."""
import argparse
import json
from pathlib import Path
import plistlib

parser = argparse.ArgumentParser(description="导出旧简单算或简单默数据；不修改旧 App 容器。")
parser.add_argument("--module", required=True, choices=["suan", "mo"])
parser.add_argument("--container", required=True, type=Path, help="Xcode 下载的 .xcappdata 文件夹")
parser.add_argument("--output", required=True, type=Path, help="新的 JSON 输出文件，已有同名文件时拒绝覆盖")
args = parser.parse_args()
app_data = args.container / "AppData"
if not app_data.is_dir():
    parser.error("容器中没有 AppData 文件夹，请使用 Xcode Download Container 导出的 .xcappdata。")

if args.module == "suan":
    source = app_data / "Library/Application Support/SimpleSuan/data_v1.json"
    if not source.is_file():
        parser.error("未找到简单算 data_v1.json；不生成空历史文件。")
    data = source.read_bytes()
    value = json.loads(data)
    if value.get("schemaVersion") != 1 or not isinstance(value.get("sessions"), list):
        parser.error("简单算历史文件格式不符，请保留原容器。")
    summary = f"已完成练习：{len(value['sessions'])} 次"
else:
    preferences = app_data / "Library/Preferences"
    candidates = list(preferences.glob("*.plist"))
    matching = []
    for candidate in candidates:
        try:
            values = plistlib.loads(candidate.read_bytes())
        except plistlib.InvalidFileException:
            continue
        if isinstance(values, dict) and any(k.startswith("dictation.") for k in values):
            matching.append(values)
    if len(matching) != 1:
        parser.error("没有找到唯一的简单默词语／设置文件；拒绝用默认值代替已有数据。")
    values = matching[0]
    settings = {
        "inputText": values.get("dictation.input", "苹果\n认真\n美丽\numbrella\nwonderful"),
        "shuffleWords": values.get("dictation.shuffle", False),
        "speechRate": values.get("dictation.rate", 0.42),
        "repeatAfterSeconds": values.get("dictation.repeatAfter", 15),
        "advanceAfterSeconds": values.get("dictation.advanceAfter", 30),
    }
    if not isinstance(settings["inputText"], str) or not isinstance(settings["shuffleWords"], bool):
        parser.error("简单默词语或设置字段格式不符，请保留原容器。")
    data = (json.dumps({"app": "SimpleMo", "formatVersion": 1, "settings": settings},
                       ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    summary = "已导出词语与五项设置"

args.output.parent.mkdir(parents=True, exist_ok=True)
with args.output.open("xb") as destination:
    destination.write(data)
print(summary)
print(f"输出：{args.output}")
