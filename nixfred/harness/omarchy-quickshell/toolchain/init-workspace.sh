#!/usr/bin/env bash
# Runs once inside a fresh workspace after the template copy. cwd is the workspace.
set -eu
mkdir -p shots .harness
[ -f shots/index.html ] || "$(dirname "$0")/shots-index.sh"
if [ ! -f .harness/verdict.json ]; then
  printf '{"spec":1,"ready":false,"summary":"new plugin workspace, nothing tested yet","findings":[],"artifact":"shots/index.html","phases":[],"updatedAt":"%s"}\n' "$(date -u +%FT%TZ)" > .harness/verdict.json
fi
echo "workspace ready: edit manifest.json and Panel.qml, test in Test Drive, shots go in shots/"
