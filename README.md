# Music Collecter

A minimalist Flutter client + FastAPI service for collecting and saving audio media that the user owns or is explicitly authorized to download.

## v1.0-zen1

The current Android experience is intentionally minimal: no local-server setup, no API URL screen, and no unnecessary onboarding.

### User flow

1. Paste a permitted direct audio URL.
2. Tap the arrow.
3. Tap download on the queued item.
4. The file streams directly to device app storage (or the optional folder you choose).

The app automatically uses the built-in HTTPS API endpoint:

`https://music-collecter-api.onrender.com`

There is no need for the user to run Python, FastAPI, a LAN server, or port forwarding.

## Current features

- Responsive Material 3 minimalist UI for Android and desktop-sized windows
- Built-in hosted API endpoint
- Automatic service health check with retry
- URL validation before requests
- Queue with duplicate protection
- Per-item download/retry/remove controls
- Download-all action
- Streaming downloads with progress
- Temporary `.part` files cleaned up after interrupted transfers
- Collision-safe filenames
- App-private storage fallback, so a storage-folder permission is not required to start
- Optional folder selection
- Clear network, timeout, and unsupported-source errors
- Android release CI with analysis, tests, APK build, and artifact verification

## Architecture

```text
Flutter app
    |
    | HTTPS
    v
Hosted FastAPI API
    |
    | validated direct media request
    v
Authorized media source
```

The API validates redirects and destination addresses, limits downloads, checks supported audio content types, and streams the result back to the app.

## Supported usage

This project is for media you own or are explicitly authorized to download, including public-domain and appropriately licensed material.

It does not bypass DRM, authentication, geo restrictions, or platform download controls, and it does not extract protected YouTube/YouTube Music streams. A normal platform page URL is not a direct audio resource.

## Backend deployment

The repository contains `render.yaml` for Render.

To make the hosted endpoint live:

1. Create/sign in to a Render account.
2. Create a new Web Service from this GitHub repository.
3. Use the repository's `render.yaml` configuration, or set:
   - Root directory: `backend`
   - Build: `pip install -r requirements.txt`
   - Start: `uvicorn app.main:app --host 0.0.0.0 --port $PORT`
   - Health check: `/health`
4. Deploy.
5. Verify `/health` returns HTTP 200.

After the Render service is connected to the repository, backend commits can be deployed automatically.

## Local development

### Flutter

```bash
flutter pub get
flutter run
```

### Backend

```bash
cd backend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

The Android release build does not require a local backend.

## Android release

GitHub Actions generates the Android platform files, installs the required Android SDK components, runs:

- `flutter analyze`
- `flutter test`
- `flutter build apk --release`
- APK archive integrity verification

and uploads the release APK as a workflow artifact.

## Roadmap

The minimalist v1.0-zen1 client is the usable foundation. Later releases can add:

- persistent download history
- background downloads and cancellation
- metadata/artwork for permitted media
- richer library and player UI
- desktop installers
- signed production releases
