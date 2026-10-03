#!/bin/zsh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

for PYTHON_BIN in \
  "/opt/homebrew/bin/python3" \
  "/usr/local/bin/python3" \
  "/Library/Frameworks/Python.framework/Versions/Current/bin/python3" \
  "/usr/bin/python3"; do
  if [[ -x "$PYTHON_BIN" ]]; then
    exec "$PYTHON_BIN" "$SCRIPT_DIR/mac_app.py"
  fi
done

osascript -e 'display alert "无法启动 Apple Store 抢购助手" message "请先安装带 Tkinter 的 Python 3，然后重新双击启动文件。"'
