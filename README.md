# RAPT_Brewing_Dashboard

Flutter-Web-App: Echtzeit-Fermentations-Dashboard für RAPT-Controller + Pill-Hydrometer.
Liest die vom [`brew-proxy`](https://github.com/alexstuder-web/brew-proxy-new) periodisch synchronisierten
Telemetrie-Daten aus Supabase (Schema `rapt`).

## Status: Source-Repo

Dieses Repo ist **nur Source**. Auf `push main` baut GitHub Actions ein
Container-Image und pusht es zu Docker Hub:

```
${DOCKERHUB_USERNAME}/web_rapt:latest
```

**Production-Deployment läuft via** [`webPage_infra`](https://github.com/alexstuder-web/webPage_infra) — dort wird das
Image gezogen und hinter Cloudflare Tunnel ausgeliefert. Watchtower
aktualisiert den Container alle 5 Min automatisch.

Image-Definition: siehe [`Dockerfile`](Dockerfile) (Nginx + Flutter-Web-Build).

## Lokales Dev

```bash
cp .env.example .env       # SUPABASE_URL/_ANON_KEY anpassen
flutter pub get
flutter run -d chrome
```

Für lokales Testen gegen den **vollen Stack** (Supabase + Proxy + Web) →
`docker-compose.dev.yml` im `webPage_infra` Repo nutzen.

## Architektur

| Bereich | Pfad |
|---|---|
| App-Entry | `lib/main.dart` |
| Repository (DB-Zugriff) | `lib/services/rapt_repository.dart` |
| Telemetrie-Verarbeitung | `lib/utils/telemetry_processor.dart` |
| Device-Details (Controller + Hydrometer) | `lib/pages/device_details_page.dart` |
| Brew-Session-Details | `lib/pages/brew_session_details_page.dart` |
| DB-Schema (Tabellen + Views) | `db_scripts/full/*.sql` |

## Daten-Fluss

```
RAPT Cloud API
      │
      │ (alle 5 Min Poll)
      ▼
brew-proxy / db-sync.js
      │
      │ (UPSERT)
      ▼
Supabase Postgres
  schema: rapt
   ├─ controllers
   ├─ hydrometers
   ├─ telemetry_controllers
   ├─ telemetry_hydrometers
   ├─ brew_sessions
   └─ device_activity_controllers (view)
      ▲
      │ (SELECT via PostgREST)
      │
web_rapt (diese App)
```

## Verwandte Repos

- [`webPage_infra`](https://github.com/alexstuder-web/webPage_infra) — Production-Compose + Bootstrap
- [`brew-proxy-new`](https://github.com/alexstuder-web/brew-proxy-new) — RAPT-Cloud-Sync + OpenAI-Proxy
- [`brew_assistent-new`](https://github.com/alexstuder-web/brew_assistent-new) — AI-Bierrezepte (Schwester-App)
