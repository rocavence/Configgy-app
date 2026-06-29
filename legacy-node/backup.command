#!/bin/sh
# Manual one-shot backup (close Zen first). Double-click to run.
DIR="$(cd "$(dirname "$0")" && pwd)"
node "$DIR/zennly.js" backup --force
echo ""; echo "Press return to close…"; read -r _
