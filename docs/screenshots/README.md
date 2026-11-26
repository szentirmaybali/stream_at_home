# Screenshots

The main [`README.md`](../README.md) has a commented-out screenshot section.
Capture the images below, save them in this folder with the exact file names,
then uncomment that block.

| File | What to capture | Notes |
|---|---|---|
| `jellyfin-library.png` | Jellyfin home with the Movies/TV libraries and a few posters | Use a demo library, not personal media |
| `sonarr-series.png` | Sonarr series list showing a few monitored shows and download progress | Blur or avoid indexer names |
| `prowlarr-indexers.png` | Prowlarr `Indexers` page with health status | Mask indexer URLs/API keys |
| `immich-timeline.png` | Immich main timeline | Use sample photos, no faces or locations |
| `compose-ps.png` | Terminal output of `docker compose ps` with all containers healthy | Optional; nice as a "it actually runs" proof |

## Guidelines

- **No personal data.** Use sample media, demo accounts and a test photo set.
  Hide API keys, tokens, e-mail addresses, indexer names, IP addresses and
  hostnames before publishing.
- **Width:** 1600–1920 px is enough; keep each file under ~500 KB
  (`pngquant` or `oxipng` help).
- **Theme:** pick one (dark or light) and use it for every screenshot.
- **Format:** PNG for UI, JPEG/WebP if a screenshot contains photos.

## Adding them to the README

1. Drop the files here.
2. Open `README.md`, find the `<!-- Screenshots ... -->` block near the end.
3. Remove the `<!--` and `-->` lines so the Markdown table renders.
4. Update captions if the UI labels differ in your language/version.
