#!/bin/sh
# Manual restore — pops the picker, then quits/restores/relaunches Zen.
DIR="$(cd "$(dirname "$0")" && pwd)"
node "$DIR/zennly.js" restore
echo ""; echo "Press return to close…"; read -r _
