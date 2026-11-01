#!/usr/bin/env bash
# Builds tasmee.apk. Requires Flutter (stable) + Android SDK, or use the GitHub Actions workflow.
set -euo pipefail
cd "$(dirname "$0")"

rm -rf _build
flutter create --org com.tasmee --project-name tasmee --platforms android _build

cp pubspec.yaml _build/pubspec.yaml
rm -rf _build/lib _build/assets
cp -r lib _build/lib
cp -r assets _build/assets
python3 patch_manifest.py _build/android/app/src/main/AndroidManifest.xml

cd _build
flutter pub get
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk ../tasmee.apk
echo "Done: $(cd .. && pwd)/tasmee.apk"
