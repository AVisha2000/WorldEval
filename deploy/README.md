# WorldEval host deployment

The public site and Controller Lab intentionally use separate origins:

- `https://openai-buildweek.lissan.dev/` serves the static public site.
- `https://lab.openai-buildweek.lissan.dev/` serves the Controller Lab and proxies its HTTP,
  video, and WebSocket traffic to the loopback API on port `18083`.
- Requests to the old `/lab` path redirect to the canonical lab origin.

The lab's browser WebSockets are rooted at `/api/embodiment/.../preview-live`; `/ws/` is reserved
for the backend-to-Godot attachment channels. Both prefixes therefore need explicit Nginx upgrade
handling. MP4s are returned by FastAPI `FileResponse` routes below `/api/`; Nginx forwards range
headers and streams those responses without temporary-file buffering.

The repository carries four core hosted videos under `godot/showcases/`: Solo Multi-Action
Construction, Labyrinth Run, Mini RTS Skirmish, and Crossroads Conquest. The API validates their
checked-in hashes/evidence at startup and serves them without depending on `runs/`, `exports/`, or
files from the machine that performed the deployment.

## Install or update

From the repository root on the host:

```bash
./scripts/build_hosting_assets.sh
sudo install -m 0644 deploy/systemd/worldeval-lab-api.service /etc/systemd/system/
sudo install -m 0644 deploy/nginx/worldeval-lab.conf /etc/nginx/sites-available/
sudo install -m 0644 deploy/nginx/worldeval-godot-demo.conf /etc/nginx/sites-available/
sudo ln -sfn /etc/nginx/sites-available/worldeval-lab.conf /etc/nginx/sites-enabled/worldeval-lab.conf
sudo ln -sfn /etc/nginx/sites-available/worldeval-godot-demo.conf /etc/nginx/sites-enabled/worldeval-godot-demo.conf
sudo systemctl daemon-reload
sudo systemctl enable --now worldeval-lab-api.service
sudo nginx -t
sudo systemctl reload nginx
```

The service deliberately checks the configured Godot and FFmpeg executables before starting.
Install FFmpeg at `/usr/bin/ffmpeg` or update `GENESIS_FFMPEG_EXECUTABLE` in the unit. The API runs
as `lissan`, so that user must be able to write `runs/` and read the checked-in showcase packages.

## Smoke checks

```bash
curl -fsS https://lab.openai-buildweek.lissan.dev/health
curl -fsSI https://lab.openai-buildweek.lissan.dev/
curl -fsS -D - -o /dev/null -H 'Range: bytes=0-1023' \
  https://lab.openai-buildweek.lissan.dev/api/embodiment/showcases/trio-maze-race-v0/video
curl -fsS -D - -o /dev/null -H 'Range: bytes=0-1023' \
  https://lab.openai-buildweek.lissan.dev/api/embodiment/showcases/solo-multi-action-v0/video
```

The ranged video request should return `206 Partial Content`. A live run in the browser additionally
verifies the `/api/.../preview-live` WebSocket path.
