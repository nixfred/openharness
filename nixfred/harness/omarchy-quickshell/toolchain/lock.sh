#!/usr/bin/env bash
# Write version-lock.json for the plugin in the current workspace: sha256 of every runtime file.
set -eu
id="$(python3 -c 'import json;print(json.load(open("manifest.json"))["id"])')"
name="$(python3 -c 'import json;print(json.load(open("manifest.json"))["name"])')"
ver="$(python3 -c 'import json;print(json.load(open("manifest.json"))["version"])')"
{
  echo "{"
  echo "  \"plugin\": \"$id\","
  echo "  \"name\": \"$name\","
  echo "  \"version\": \"$ver\","
  echo "  \"updatePolicy\": \"Plain-file installation excluded from automatic Git updates. Change only on explicit request.\","
  echo "  \"sha256\": {"
  first=1
  for f in $(ls *.qml *.js *.json 2>/dev/null | grep -v version-lock.json) $(find . -maxdepth 1 -type f -perm -u+x -not -name '*.sh' | sed 's|^\./||'); do
    [ "$first" -eq 1 ] || echo ","
    first=0
    printf '    "%s": "%s"' "$f" "$(sha256sum "$f" | cut -d' ' -f1)"
  done
  echo
  echo "  }"
  echo "}"
} > version-lock.json
echo version-lock.json
