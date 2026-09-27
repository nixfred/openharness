#!/usr/bin/env bash
# Regenerate shots/index.html from every PNG in shots/, newest first. Run from the workspace root.
set -eu
dir="${1:-shots}"
mkdir -p "$dir"
out="$dir/index.html"
{
  echo '<!doctype html><meta charset="utf-8"><title>Plugin shots</title>'
  echo '<style>body{margin:0;background:#111;color:#ddd;font:14px system-ui}h1{margin:12px 16px;font-size:16px}'
  echo 'figure{margin:0 16px 24px}img{max-width:100%;border:1px solid #333}figcaption{opacity:.7;margin-top:4px}</style>'
  echo "<h1>Plugin shots ($(date '+%F %T'))</h1>"
  found=0
  for f in $(ls -t "$dir"/*.png 2>/dev/null); do
    found=1
    b="$(basename "$f")"
    echo "<figure><img src=\"$b\" alt=\"$b\"><figcaption>$b</figcaption></figure>"
  done
  [ "$found" -eq 1 ] || echo '<p style="margin:16px">No screenshots yet. Run <code>test-drive shot &lt;vm&gt;</code> and copy the PNG here.</p>'
} > "$out"
echo "$out"
