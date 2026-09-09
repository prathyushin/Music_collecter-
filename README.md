# Music Collecter

Cross-platform Flutter client + FastAPI service for collecting and saving audio media that the user owns or is explicitly authorized to download.

## Current status

The repository has been repaired into a usable foundation rather than being marked as finished prematurely.

- Flutter client with a reusable download queue
- FastAPI media-analysis and download service
- Device/local output-folder saving is wired to the download result
- Streaming file transfer from the API to the selected local folder
- Download progress indicator
- API connection test and configurable server URL
- Safe filenames and collision handling
- Temporary `.part` files are cleaned up after failed transfers
- Flutter smoke test and backend tests
- Android release workflow

## Runtime flow

```text
Paste authorized direct audio URL
        |
        v
Flutter queue
        |
        v
POST /analyze
        |
        v
POST /download  ---> FastAPI downloads to server storage
        |
        v
GET /files/{filename}
        |
        v
Flutter streams file to selected device/local folder
```

## Important usage rule

This project is designed for media that you own or are explicitly authorized to download, including public-domain and appropriately licensed material. It does not bypass DRM, authentication, geo restrictions, or platform download controls, and it does not implement extraction of protected YouTube/YouTube Music streams.

A normal YouTube page URL is therefore not treated as a direct audio resource. Supporting a service requires an official/authorized download mechanism or a direct media URL that the user is permitted to retrieve.

## Architecture

```text
Flutter client
  |-- queue
  |-- progress
  |-- local storage
  |-- API settings
  |
  v
FastAPI service
  |-- source validation
  |-- media analysis
  |-- streaming download
  |-- safe filenames
  |-- file serving
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

On a physical Android device, do not use `127.0.0.1` for a backend running on your computer. Set the API address in **Settings** to the computer's reachable LAN address, for example `http://192.168.x.x:8000`.

## Android release

GitHub Actions generates the Android platform project, runs Flutter analysis and tests, builds a release APK, and uploads it as the `music-collecter-android-release` artifact.

## Next engineering stages

1. Persistent queue/history.
2. Pluggable authorized-source adapters.
3. Metadata/artwork pipeline for permitted media.
4. Optional tagging/conversion for files the user is permitted to process.
5. Background jobs, retries, and cancellation.
6. Android background-download integration.
7. Desktop packaging and signed releases.
