import os

from uptime_kuma_api import MonitorType, UptimeKumaApi

URL = "http://uptime-kuma:3001"
HTTP, PING, PORT = MonitorType.HTTP, MonitorType.PING, MonitorType.PORT


def http(name, url, **kw):
    return dict(type=HTTP, name=name, url=url, **kw)


monitors = [
    # Internal checks: container name + internal port, same order as your list
    http("Authentik", "http://authentik-server:9000/-/health/live/"),
    http("Actual Budget", "http://actual:5006"),
    dict(type=PORT, name="MediaMTX HLS", hostname="mediamtx", port=8888),
    http(
        "Nextcloud",
        "http://nextcloud:80/status.php",
        headers='{"Host": "example.com"}',
    ),
    http("Excalidraw", "http://excalidraw:80"),
    http("Frigate", "https://frigate:8971", ignoreTls=True),
    http("Portainer", "https://portainer:9443/api/system/status", ignoreTls=True),
    http("Forgejo", "http://forgejo:3000/api/healthz"),
    http("Grafana", "http://grafana:3000/api/health"),
    http("Homepage", "http://homepage:3000", headers='{"Host": "example.com"}'),
    http("Synapse", "http://synapse:8008/health"),
    http("Jellyfin", "http://jellyfin:8096/health"),
    http("Navidrome", "http://navidrome:4533/ping"),
    http("Portfolio", "http://portfolio:80"),
    http("Nginx Proxy Manager", "http://nginx-proxy-manager:81/api/"),
    http("ntfy", "http://ntfy:80/v1/health"),
    http("Vaultwarden", "http://vaultwarden:80/alive"),
    http("Immich", "http://immich-server:2283/api/server/ping"),
    http("SearXNG", "http://searxng:8080/healthz"),
    # Extras
    dict(type=PORT, name="MediaMTX RTSP", hostname="mediamtx", port=8554),
    http("Camera stream (Pi)", "http://mediamtx:8888/cam/index.m3u8", interval=120),
    dict(type=PORT, name="Postgres", hostname="postgres", port=5432),
    dict(type=PING, name="Router", hostname="192.168.1.1"),
    # dict(type=PING, name="Proxmox", hostname="PROXMOX_IP"),
    # dict(type=PING, name="Raspberry Pi", hostname="PI_IP"),
    # Public end-to-end checks (the sites you left public), with certificate expiry alerts
    http("Public: example.com", "https://example.com", expiryNotification=True),
    http(
        "Public: Matrix",
        "https://example.com/_matrix/client/versions",
        expiryNotification=True,
    ),
]

with UptimeKumaApi(URL, timeout=60) as api:
    api.login(os.environ["KUMA_USER"], os.environ["KUMA_PASS"])

    # Uptime Kuma 2.x requires a "conditions" field that this older library doesn't send
    _orig_call = api._call

    def _call(event, data=None):
        if event == "add" and isinstance(data, dict):
            data.setdefault("conditions", [])
        return _orig_call(event, data)

    api._call = _call

    existing = {m["name"] for m in api.get_monitors()}
    for m in monitors:
        if m["name"] not in existing:
            api.add_monitor(**{"interval": 60, "maxretries": 2, **m})
            print("added", m["name"])
