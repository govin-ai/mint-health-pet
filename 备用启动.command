#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h}"
echo "正在启动薄荷。终端会显示启动日志；运行时可将此窗口最小化。"
exec "$TASK_ROOT/MintHealthPet"
