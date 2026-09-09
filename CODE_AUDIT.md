# Horizon Cooler Code Audit

## Main fixes
- BLE service discovery now requires the exact configured RX/TX UUIDs instead of accepting arbitrary writable/notifiable characteristics.
- BLE command writes are serialized and choose write-with-response vs write-without-response from the characteristic capability.
- Connection lifecycle no longer reports a false initial "Connection Lost" and cleans up notification subscriptions.
- Firebase `.info/connected` is stored as a cancelable subscription and cleaned up with the screen lifecycle.
- Battery telemetry no longer creates overlapping timer writes and can be sent to the ESP32 for battery-aware AI protection.
- AI profile selection (`AIM:0/1`) and phone battery temperature (`BTP:x.x`) are now part of the App↔ESP32 protocol.
- Firmware Adaptive Mode now uses the phone battery thresholds for the second profile and stays conservative when battery temperature is unavailable.
- Firmware temperature limits are validated/sanitized before use.
- Firmware update comparison now treats `Vmajor.minor` numerically, so an older firmware cannot be offered as an update just because its string differs.
- Firmware update dialog waits for BLE version synchronization before checking Firebase for a new firmware.
- Android Bluetooth permissions are scoped to Android generations and global cleartext traffic is disabled.
- Removed the conflicting legacy AGP buildscript block and redundant manual Firebase native dependencies.
- CI no longer deletes/recreates the Android project or patches the pub cache on every build. It installs dependencies, analyzes/tests, then builds; if the uploaded project lacks a Gradle wrapper, it restores one with Flutter.

## Validation performed
- Raw brace/parenthesis/bracket balance: OK for Dart and firmware.
- App↔firmware command coverage checked for all existing commands plus `AIM` and `BTP`.
- AndroidManifest XML parse: OK.
- GitHub Actions YAML parse: OK.
- Flutter and Arduino toolchains were not installed in this environment, so a real APK/ESP32 compiler build could not be executed here.
