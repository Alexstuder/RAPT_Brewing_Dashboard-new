# RAPT_Brewing_Dashboard

Echtzeit-Gärungs-Dashboard für RAPT Pill Sensoren – statische Web App (HTML/JS/CSS), ausgeliefert via Nginx-Container.

## Features
- Live-Anzeige von Temperatur, Gravity, Alkoholgehalt
- Historische Gärkurven via Chart.js
- Daten kommen vom zentralen `api_proxy` (kein direkter RAPT-API-Zugriff im Browser)

## Architektur
- Container: `web_rapt`
- Deployment: GitOps via Watchtower
- Tunnel: Cloudflare → `rapt.alexstuder.ch`

## Lokale Entwicklung
```bash
# Einfach index.html im Browser öffnen oder Live Server nutzen
```

## Deployment
Push auf `main` → GitHub Actions → Docker Hub → Watchtower deployed automatisch.
