#!/usr/bin/env bash
# Type-checks every plugin package: Tern's definitions from `tern plugin types`, then luau-lsp.
set -euo pipefail
cd "$(dirname "$0")/.."

lsp=${LUAU_LSP:-$(command -v luau-lsp || true)}
[ -n "$lsp" ] || { echo "luau-lsp not found: install it or set LUAU_LSP" >&2; exit 1; }

status=0
for manifest in */plugin.toml; do
  dir=$(dirname "$manifest")
  tern plugin types "$dir" >/dev/null
  files=()
  while IFS= read -r f; do files+=("$f"); done < <(find "$dir" -name '*.luau' ! -name 'tern.d.luau')
  problems=$("$lsp" analyze --definitions="$dir/tern.d.luau" "${files[@]}" 2>&1 | grep -v '^\[INFO\]' || true)
  if [ -n "$problems" ]; then
    echo "$problems"
    status=1
  else
    echo "ok $dir"
  fi
done
exit $status
