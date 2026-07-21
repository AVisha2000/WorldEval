#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dashboard_dir="$repo_root/dashboard"
godot_bin=${GODOT_BIN:-/tmp/worldeval-godot-4.5/Godot_v4.5-stable_linux.x86_64}

if [[ ! -x "$godot_bin" ]]; then
    printf 'Godot executable not found: %s\nSet GODOT_BIN to override it.\n' "$godot_bin" >&2
    exit 1
fi

pushd "$dashboard_dir" >/dev/null
VITE_BASE_PATH=/ VITE_CONTROLLER_LAB_URL='https://lab.openai-buildweek.lissan.dev/' npm run build:pages
./node_modules/.bin/vite build --base=/ --outDir dist-lab-domain
popd >/dev/null

mkdir -p "$repo_root/exports/godot-web"
"$godot_bin" --headless --path "$repo_root/godot" --export-release \
    "WorldArena Browser Demo" "$repo_root/exports/godot-web/index.html"

# Nginx runs as www-data. Preserve the least privilege needed to traverse and
# read only the published artifacts after each rebuild.
setfacl -m u:www-data:--x "$repo_root/exports"
for artifact_dir in \
    "$repo_root/exports/godot-web" \
    "$dashboard_dir/dist" \
    "$dashboard_dir/dist-lab-domain"; do
    setfacl -R -m u:www-data:rX "$artifact_dir"
    setfacl -R -d -m u:www-data:rX "$artifact_dir"
done
