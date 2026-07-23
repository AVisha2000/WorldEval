# WorldEval Hosting Runbook

The production demo is hosted directly by Nginx. Nginx serves built static
assets and proxies only Controller Lab API and WebSocket traffic to FastAPI.
There is no application router on port `8092`.

## Public Routes

- `https://godot.lissan.dev/` serves `exports/godot-web`.
- `https://openai-buildweek.lissan.dev/` serves `apps/worldeval-web/dist`.
- `https://openai-buildweek.lissan.dev/lab/` serves `apps/worldeval-web/dist-lab` for
  the legacy path.
- `https://lab.openai-buildweek.lissan.dev/` serves
  `apps/worldeval-web/dist-lab-domain`.
- `https://lab.openai-buildweek.lissan.dev/api/` and `/ws/` proxy to the
  FastAPI service on `127.0.0.1:18083`.

All names require DNS `A` records for `176.58.126.191` and valid TLS
certificates.

## Rebuild Static Assets

Run the repository-owned script as `lissan`:

```bash
cd /home/lissan/codex-build-week/WorldEval
worlds/worldarena/scripts/build_hosting_assets.sh
```

Set `GODOT_BIN` when the Godot 4.5 executable is not at the default path:

```bash
GODOT_BIN=/path/to/Godot_v4.5-stable_linux.x86_64 worlds/worldarena/scripts/build_hosting_assets.sh
```

The script builds all three dashboard outputs, exports the Godot Web build, and
applies the least-privilege ACLs required for Nginx (`www-data`) to read the
published assets. Install dashboard dependencies first when needed:

```bash
cd apps/worldeval-web && npm install
```

## FastAPI Service

The backend uses the systemd unit in
`ops/systemd/worldeval-lab-api.service`. It runs as `lissan`, restarts on
failure, and is enabled at boot.

```bash
sudo install -m 0644 ops/systemd/worldeval-lab-api.service \
  /etc/systemd/system/worldeval-lab-api.service
sudo systemctl daemon-reload
sudo systemctl enable --now worldeval-lab-api.service
sudo systemctl restart worldeval-lab-api.service
sudo journalctl -u worldeval-lab-api.service -f
```

The unit's `GENESIS_GODOT_EXECUTABLE` points at the server's Godot binary.
Update that one setting before restarting the service when the binary moves.

## Nginx Deployment

The source-controlled Nginx templates are in `ops/nginx/`. Install them and
reload only after a successful configuration test:

```bash
sudo install -m 0644 ops/nginx/worldeval-godot-demo.conf \
  /etc/nginx/sites-available/worldeval-godot-demo
sudo install -m 0644 ops/nginx/worldeval-lab.conf \
  /etc/nginx/sites-available/worldeval-lab
sudo ln -sf /etc/nginx/sites-available/worldeval-godot-demo \
  /etc/nginx/sites-enabled/worldeval-godot-demo
sudo ln -sf /etc/nginx/sites-available/worldeval-lab \
  /etc/nginx/sites-enabled/worldeval-lab
sudo nginx -t && sudo systemctl reload nginx
```

The templates reference existing Certbot certificate paths. For a new hostname,
install its HTTP server block, run `sudo certbot --nginx -d HOSTNAME`, then copy
the resulting TLS settings into the template before committing it.

## Verification

```bash
curl -fsSI https://godot.lissan.dev/
curl -fsSI https://godot.lissan.dev/index.wasm
curl -fsSI https://openai-buildweek.lissan.dev/
curl -fsSI https://openai-buildweek.lissan.dev/lab/
curl -fsSI https://lab.openai-buildweek.lissan.dev/
curl -fsS https://lab.openai-buildweek.lissan.dev/api/embodiment/certification/readiness
systemctl is-active nginx worldeval-lab-api.service
```

Expected results are HTTP `200`, `application/wasm` for `index.wasm`, and both
services reporting `active`.
