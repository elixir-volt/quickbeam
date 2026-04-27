#!/usr/bin/env bash
set -euo pipefail

mix compile --warnings-as-errors >/tmp/quickbeam-autoresearch-compile.log 2>&1 || {
  tail -80 /tmp/quickbeam-autoresearch-compile.log
  exit 1
}

mix test test/web_apis >/tmp/quickbeam-autoresearch-web-apis.log 2>&1 || {
  tail -80 /tmp/quickbeam-autoresearch-web-apis.log
  exit 1
}
