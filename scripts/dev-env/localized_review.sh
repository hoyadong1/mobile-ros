#!/usr/bin/env bash
# Localized screen review in every app language (en es ko ja zh): 13 screens x phone 2x / phone / tablet.
# QA_CAPTURE=1 also saves pictures to build/localized-ui/<language>. Uses Windows fonts for Korean, Japanese and Chinese glyphs.
set -u
cd "$(dirname "$0")/../.."
FLUTTER=${FLUTTER:-$HOME/ros-ai-lab/tools/flutter/bin/flutter}
export FLUTTER_ROOT=${FLUTTER_ROOT:-$(cd "$(dirname "$FLUTTER")/.." && pwd -W 2>/dev/null || pwd)}
status=0
for pair in en: es: ko:C:/Windows/Fonts/malgun.ttf ja:C:/Windows/Fonts/YuGothR.ttc zh:C:/Windows/Fonts/msyh.ttc; do
  lang=${pair%%:*}; font=${pair#*:}
  if [ -n "$font" ]; then export QA_LOCALE_FONT=$font; else unset QA_LOCALE_FONT; fi
  printf '%s: ' "$lang"
  out=$("$FLUTTER" test tool/localized_ui_review_test.dart --dart-define=QA_LOCALE="$lang" 2>&1)
  echo "$out" | grep -E '\[E\]|All tests passed|Some tests failed' | sed 's/^[0-9:]* +[0-9]* [-~0-9]*: //'
  echo "$out" | grep -q 'All tests passed' || status=1
done
exit $status
