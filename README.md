# Music Collecter

Cross-platform music library and authorized-media downloader foundation for Android, Windows, Linux and macOS.

## Current status

- Flutter application foundation
- Material 3 responsive interface
- URL/playlist queue UI
- Output-directory selection
- Python FastAPI service foundation
- Safe source-adapter boundary

## Important usage rule

This project is designed for media that you own or are explicitly authorized to download, including public-domain and appropriately licensed material. It does not bypass DRM, authentication, geo restrictions, or platform download controls, and it does not implement extraction of protected YouTube/YouTube Music streams.

## Architecture

```text
Flutter client (Android/Desktop)
        |
        v
   FastAPI service
        |
        +-- source adapters (authorized sources)
        +-- metadata
        +-- artwork
        +-- queue
        +-- tagging
```

## Run Flutter

```bash
flutter pub get
flutter run
```

## Run backend

```bash
cd backend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

## Roadmap

1. Persistent SQLite download queue.
2. Authorized-source adapters.
3. Metadata and artwork pipeline.
4. FFmpeg tagging/conversion for permitted files.
5. Background jobs and retry handling.
6. Android background download integration.
7. Desktop installers and CI releases.
