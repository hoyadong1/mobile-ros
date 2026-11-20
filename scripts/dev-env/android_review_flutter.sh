#!/usr/bin/env bash
# Adapter for sim_live_test.sh: keep fresh-simulator setup mandatory for native Android review.
set -euo pipefail
node tool/run_android_review.mjs "$@"
