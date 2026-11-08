# Homelab architecture

[Back to the README](../README.md)

A single Dell PowerEdge R720 running Proxmox VE, with a Debian 13 VM hosting the Docker Compose stack. It is a personal homelab on one physical host with no redundancy. Diagrams are generated from `docker-compose.yml`; dashed boxes are planned and not built.

## 1. Access and network flow

```mermaid
flowchart LR
    inet(["Internet"])
    tsdev(["Tailnet devices<br/>phone, laptop"])

    subgraph lan["Home network"]
        router["OpenWrt router<br/>port forwards only for public services"]
        pi["Raspberry Pi<br/>camera stream and Pi-hole DNS"]
    end

    subgraph vm["Debian 13 VM on Proxmox VE (Dell R720) - Docker network docker-network"]
        ts["Tailscale<br/>on the VM, outside compose"]
        dns["tsdns (dnsmasq)<br/>answers domain lookups<br/>with the tailnet address"]
        npm["Nginx Proxy Manager<br/>TLS via Let's Encrypt<br/>per-host access lists"]
        pub["Public hosts<br/>Synapse (Matrix federation)<br/>Portfolio site"]
        priv["Private apps<br/>Nextcloud, Immich, Forgejo, Vaultwarden,<br/>Grafana, Portainer, Jellyfin and others"]
        sso["Authentik SSO<br/>OIDC and TOTP"]
        cam["MediaMTX, then Frigate<br/>camera ingest on 8554 and 1935"]
        direct["Directly published ports<br/>Forgejo SSH 222, Minecraft 25565,<br/>Jellyfin discovery 7359/udp,<br/>Frigate WebRTC 8555"]
    end

    inet -->|"80, 443"| router
    router -->|"forward"| npm
    npm -->|"public access list"| pub
    tsdev -->|"WireGuard"| ts
    ts --> npm
    tsdev -.->|"DNS via Tailscale nameserver"| dns
    npm -->|"tailnet or LAN only"| priv
    priv -.->|"OIDC login"| sso
    pi -->|"RTSP push"| cam
    router -.->|"only if forwarded"| direct
```

- **Public path:** the internet reaches Nginx Proxy Manager only through router port forwards. Only the public hosts (Matrix federation and the portfolio site) are open to everyone.
- **Private path:** everything else is restricted by NPM access lists to the tailnet or the LAN. Tailscale provides remote access, and a containerized dnsmasq (`tsdns`) resolves the domain to the tailnet address so private hostnames work away from home.
- **Identity:** apps sign in through Authentik (OIDC) with TOTP.
- **Direct ports:** a few services publish their own ports (see the table). They are reachable from the LAN, and from the internet only if the router forwards them.

## 2. Service map

```mermaid
flowchart TB
    subgraph hw["Dell R720: one physical host, no redundancy"]
        subgraph pve["Proxmox VE"]
            subgraph vm["Debian 13 VM: Docker Compose, 38 services defined, one network"]
                edge["Edge (3)<br/>nginx-proxy-manager, tsdns, portfolio"]
                ident["Identity (2)<br/>authentik-server, authentik-worker"]
                data["Shared data (2)<br/>postgres, redis"]
                cloud["Personal cloud (9)<br/>nextcloud, nextcloud-cron, immich-server, immich-database, vaultwarden, forgejo, actual, excalidraw, filebrowser"]
                media["Media (2)<br/>jellyfin, navidrome"]
                comms["Messaging (3)<br/>synapse, synapse-db, ntfy"]
                search["Search (2)<br/>searxng, searxng-valkey"]
                cam["Camera (2)<br/>mediamtx, frigate"]
                mon["Monitoring (10)<br/>prometheus, grafana, cadvisor, node-exporter, postgres-exporter, idrac-exporter, uptime-kuma, netdata, diun, kuma-monitors"]
                ops["Operations (2)<br/>homepage, portainer"]
                game["Game server (1)<br/>minecraft"]
            end
            torrent["Torrent VM<br/>PLANNED, not built yet<br/>own disk, NFS shares to the Docker VM"]:::planned
        end
        nvme["NVMe tier<br/>configs, databases, app state<br/>used by every group except Game server"]
        sas["SAS 2TB<br/>bulk user data: photos, Nextcloud files,<br/>git repos, recordings"]
        sata["SATA drives, 4TB x2 and 8TB<br/>media, music, backups"]
    end
    cloud --> sas
    cloud --> sata
    media --> sas
    media --> sata
    cam --> sas
    game --> sas
    ident -.-> data
    cloud -.-> data
    mon -.-> comms
    mon -.-> data
    torrent -.->|"NFS (planned)"| vm
    classDef planned stroke-dasharray: 5 5
```

- **Dotted arrows** show `depends_on` links between groups. **Solid arrows** show volume mounts on the SAS and SATA tiers.
- Every group uses the NVMe tier for configs and databases except the game server, so those arrows are omitted.

## 3. Components

| Service | Role | Published ports | Storage | Depends on |
|---|---|---|---|---|
| `nginx-proxy-manager` | Reverse proxy, TLS, access lists | 80:80, 443:443, 81:81 | NVMe | - |
| `tsdns` | Split-horizon DNS (dnsmasq, host network) | host network | - | - |
| `portfolio` | Static portfolio site (nginx) | - | NVMe | - |
| `authentik-server` | SSO identity provider, web and API | - | NVMe | postgres |
| `authentik-worker` | SSO background worker | - | NVMe | postgres |
| `postgres` | Shared Postgres (authentik, nextcloud, forgejo) | - | NVMe | - |
| `redis` | Shared cache (Nextcloud, Immich) | - | NVMe | - |
| `nextcloud` | File sync | - | NVMe, SAS | postgres, redis |
| `nextcloud-cron` | Nextcloud background jobs | - | NVMe, SAS | nextcloud |
| `immich-server` | Photo backup | - | SAS | redis, immich-database |
| `immich-database` | Immich Postgres | - | NVMe | - |
| `vaultwarden` | Password manager | - | NVMe | - |
| `forgejo` | Git hosting | 222:22 | SAS | postgres |
| `actual` | Budgeting (OIDC login) | - | NVMe | - |
| `excalidraw` | Whiteboard | - | - | - |
| `filebrowser` | File manager | - | NVMe, SAS, SATA | - |
| `jellyfin` | Video streaming | 7359:7359/udp | NVMe, SAS, SATA | - |
| `navidrome` | Music streaming | - | NVMe, SAS | - |
| `synapse` | Matrix homeserver (federated) | - | NVMe | synapse-db |
| `synapse-db` | Synapse Postgres | - | NVMe | - |
| `ntfy` | Push notifications | - | NVMe | - |
| `searxng` | Metasearch | - | NVMe | searxng-valkey |
| `searxng-valkey` | SearXNG cache | - | NVMe | - |
| `mediamtx` | Camera stream relay (RTSP/HLS) | 8554:8554, 1935:1935 | - | - |
| `frigate` | Object detection and recording | 8555:8555/tcp, 8555:8555/udp | NVMe, SAS | mediamtx |
| `prometheus` | Metrics store (15d / 5GB retention) | - | NVMe | - |
| `grafana` | Dashboards (OIDC login) | - | NVMe | prometheus |
| `cadvisor` | Per-container metrics (privileged) | - | - | - |
| `node-exporter` | VM metrics | - | - | - |
| `postgres-exporter` | Postgres metrics | - | - | postgres |
| `idrac-exporter` | Server hardware metrics (iDRAC) | - | NVMe | - |
| `uptime-kuma` | Service monitoring and cert-expiry alerts | - | NVMe | - |
| `netdata` | Live host view (host network) | host network | NVMe, docker.sock | - |
| `diun` | Image update notices to ntfy | - | NVMe, docker.sock | ntfy |
| `kuma-monitors` | One-shot monitor provisioning (profile: tools) | - | - | - |
| `homepage` | Dashboard | - | NVMe, docker.sock | - |
| `portainer` | Container management | - | NVMe, docker.sock | - |
| `minecraft` | Minecraft server (Fabric) | 25565:25565 | SAS | - |

## 4. Outside the compose file

These pieces are part of the setup but are not defined in this repository: the Proxmox VE host, Tailscale (installed on the VM), the OpenWrt router and its port forwards, Pi-hole and the camera on the Raspberry Pi, the iDRAC, and the Nginx Proxy Manager host entries and access lists.

## 5. Planned, not built

A second VM for torrenting, with its own disk and NFS shares to the Docker VM. Intrusion prevention (CrowdSec/fail2ban) was evaluated for a later phase.
