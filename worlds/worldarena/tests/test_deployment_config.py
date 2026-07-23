from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


def _location(config: str, declaration: str) -> str:
    start = config.index(declaration)
    opening_brace = config.index("{", start)
    depth = 0
    for index in range(opening_brace, len(config)):
        if config[index] == "{":
            depth += 1
        elif config[index] == "}":
            depth -= 1
            if depth == 0:
                return config[opening_brace + 1 : index]
    raise AssertionError(f"unclosed Nginx block: {declaration}")


def test_lab_proxy_supports_api_websockets_and_ranged_video() -> None:
    config = (REPOSITORY_ROOT / "deploy/nginx/worldeval-lab.conf").read_text()

    assert "map $http_upgrade $worldeval_connection_upgrade" in config
    api = _location(config, "location /api/")
    assert "proxy_set_header Upgrade $http_upgrade;" in api
    assert "proxy_set_header Connection $worldeval_connection_upgrade;" in api
    assert "proxy_set_header Range $http_range;" in api
    assert "proxy_set_header If-Range $http_if_range;" in api
    assert "proxy_buffering off;" in api

    sockets = _location(config, "location /ws/")
    assert "proxy_set_header Upgrade $http_upgrade;" in sockets
    assert "access_log off;" in sockets


def test_legacy_lab_path_redirects_to_the_canonical_api_origin() -> None:
    config = (REPOSITORY_ROOT / "deploy/nginx/worldeval-godot-demo.conf").read_text()
    build_script = (REPOSITORY_ROOT / "scripts/build_hosting_assets.sh").read_text()

    assert config.count("return 308 https://lab.openai-buildweek.lissan.dev/;") == 2
    assert "dashboard/dist-lab/" not in config
    assert "--outDir dist-lab\n" not in build_script


def test_lab_service_checks_native_video_dependencies() -> None:
    unit = (REPOSITORY_ROOT / "deploy/systemd/worldeval-lab-api.service").read_text()

    assert "Environment=GENESIS_FFMPEG_EXECUTABLE=/usr/bin/ffmpeg" in unit
    assert "ExecStartPre=/usr/bin/test -x /usr/bin/ffmpeg" in unit
    assert "ExecStartPre=/usr/bin/test -x /tmp/worldeval-godot-4.5/" in unit
