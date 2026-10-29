#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/dist/WalletSkin Studio.app"
if [ ! -d "$APP" ]; then
  if ! xcode-select -p >/dev/null 2>&1; then
    echo 'לבנייה מקוד מקור נדרשים כלי הפיתוח של Apple.'
    echo 'להתקנה ללא פקודות: הורידו את קובץ ה-DMG מדף Releases במאגר.'
    open 'https://github.com/razmazlih/walletskin-studio/releases/tag/v0.3.2'
    read -r -p 'לחצו Enter לסגירה. ' answer
    exit 1
  fi
  if [ ! -f upstream/AirCard/Sources/device_helper.m ]; then
    echo 'מוריד את קוד AirCard בגרסה המקובעת…'
    git submodule update --init --recursive
  fi
  echo 'בונה את האפליקציה בפעם הראשונה. הפעולה עשויה לקחת כמה דקות…'
  if ! SKIP_DMG=1 ./scripts/build.sh; then
    echo 'הבנייה לא הושלמה. אפשר להוריד מתקין מוכן מדף Releases.'
    read -r -p 'לחצו Enter לסגירה. ' answer
    exit 1
  fi
fi
open "$APP"
