# Android build notes

The Android project is generated during CI from the Flutter source so the repository stays lightweight.

The release workflow validates the app with `flutter analyze` and `flutter test`, then produces `app-release.apk` as a workflow artifact.

For Android, the API endpoint is configurable in the app Settings screen. `127.0.0.1` refers to the Android device itself, so a backend running on a development computer must use the computer's reachable LAN address when testing on a physical device.
