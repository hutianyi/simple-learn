#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo '用法：scripts/send-reading-pack.sh <ADB 设备序号> <阅读包.simpledu>' >&2
    exit 2
fi

serial=$1
pack=$2
if [[ ! -f "$pack" || "$pack" != *.simpledu ]]; then
    echo '请选择一个现有的 .simpledu 文件。' >&2
    exit 2
fi

size=$(wc -c < "$pack" | tr -d '[:space:]')
if (( size < 1 || size > 64 * 1024 * 1024 )); then
    echo '阅读包大小必须在 1 字节至 64 MiB 之间。' >&2
    exit 2
fi
digest=$(shasum -a 256 < "$pack" | cut -d ' ' -f 1)

adb_bin=${ADB:-adb}
if ! "$adb_bin" -s "$serial" shell -T run-as com.hutianyi.simpledutv true </dev/null; then
    echo '无法访问电视上的简单读收件箱。请检查 ADB 授权与调试版 APK 是否已安装。' >&2
    exit 1
fi

# The size and digest are locally generated digits and hex, safe to pass to the remote shell.
"$adb_bin" -s "$serial" shell -T "run-as com.hutianyi.simpledutv sh -c '
    set -e
    mkdir -p files/inbox
    temp=\$(mktemp files/inbox/.transfer.XXXXXX)
    trap \"rm -f \\\"\$temp\\\"\" EXIT
    cat > \"\$temp\"
    test \"\$(wc -c < \"\$temp\")\" -eq $size
    mv -f \"\$temp\" files/inbox/$digest.simpledu
'" < "$pack"
echo '已传到电视。打开简单读，或在文章列表按「检查新阅读包」。'
