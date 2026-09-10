# Horizon Cooler Release Signing

`Tenzo23012005` is a passphrase, not the cryptographic private key. The Android release keystore and the firmware signing key generated for this project are different cryptographic keys, even though the same passphrase was used to protect them.

## Generated private signing material

- Android release keystore: `horizon-release.p12`
- Android alias: `horizon-release`
- Android keystore/key password: `Tenzo23012005`
- Firmware signing private key: `horizon-firmware-signing-private.pem`
- Firmware signing public key: `horizon-firmware-signing-public.pem`
- Firmware private-key passphrase: `Tenzo23012005`

**Never upload any private key, keystore, or passphrase to GitHub, Firebase, the APK, or the firmware binary.** Move the private files to a secure password manager/offline backup and use GitHub Actions Secrets for CI signing.

## Android CI

The Gradle release configuration consumes these environment variables:
`ANDROID_KEYSTORE_FILE`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD`.

The workflow creates the temporary keystore file from `ANDROID_KEYSTORE_BASE64` and only uses it during the build. Without the secrets, the existing debug-signing fallback remains so the baseline build path is not accidentally broken.

Flutter release builds are obfuscated and upload Dart symbol files as a separate artifact for controlled debugging.

## Firmware OTA

The firmware should contain only the public verification key when signed-OTA verification is enabled. The private key must remain outside the ESP32 sketch. The current firmware patch enforces HTTPS URLs and removes `setInsecure()`; complete cryptographic firmware-signature verification should be added together with the OTA manifest/signature format before treating OTA as fully authenticated.
