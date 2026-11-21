#!/usr/bin/env bash
# Builds standalone offline tasmee.apk:
# 1. Syncs index.html -> assets/index.html & preview.html
# 2. Bundles the on-device Whisper GGML Arabic/Quranic model (ggml-base-q5_1.bin, ~59.7 MB)
#    and full 604-page Quran text JSON (~1.6 MB) directly into assets/ at build time
#    so recitation works 100% offline from first install (ZERO Sheikh MP3s are pre-bundled).
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p assets/models assets/data

if [ -f index.html ]; then
  cp -f index.html assets/index.html
  cp -f index.html preview.html
fi

# Accept Android SDK / NDK licenses automatically (required by whisper_ggml native C++ NDK build)
SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
SDKMGR="$(command -v sdkmanager || echo "$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager")"
if [ -x "$SDKMGR" ]; then
  echo "Accepting Android SDK/NDK licenses..."
  yes | "$SDKMGR" --licenses >/dev/null 2>&1 || true
fi

# Bundle quantized multilingual/Arabic Whisper GGML model (~59.7 MB) for 100% offline recitation
MODEL_FILE="assets/models/ggml-base-q5_1.bin"
if [ ! -s "$MODEL_FILE" ]; then
  echo "Downloading on-device Whisper Base Q5_1 model (~59.7 MB) to bundle inside APK..."
  curl -fL --retry 3 -o "$MODEL_FILE" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin"
fi

# Bundle full 604-page Uthmani Quran JSON (~1.6 MB) so all pages work offline from first launch
QURAN_JSON="assets/data/quran_full_604.json"
if [ ! -s "$QURAN_JSON" ]; then
  echo "Downloading 604-page Uthmani Quran text JSON (~1.6 MB) to bundle inside APK..."
  curl -fL --retry 3 -o "$QURAN_JSON" \
    "https://api.alquran.cloud/v1/quran/quran-uthmani" || echo "{}" > "$QURAN_JSON"
fi

rm -rf _build
flutter create --org com.tasmee --project-name tasmee --platforms android _build

cp pubspec.yaml _build/pubspec.yaml
rm -rf _build/lib _build/assets
cp -r lib _build/lib
cp -r assets _build/assets
if [ -f tasmee-release.jks ]; then
  cp -f tasmee-release.jks _build/android/app/tasmee-release.jks
elif [ -f android_signing/tasmee-release.jks ]; then
  cp -f android_signing/tasmee-release.jks _build/android/app/tasmee-release.jks
else
  echo "WARNING: tasmee-release.jks not found! Release APK will fall back to ephemeral debug signing."
fi
python3 patch_manifest.py _build/android/app/src/main/AndroidManifest.xml

cd _build
flutter pub get
BUILD_NUM="${GITHUB_RUN_NUMBER:-2}"
flutter build apk --release --build-number="$BUILD_NUM"
cp build/app/outputs/flutter-apk/app-release.apk ../tasmee.apk
echo "Done: $(cd .. && pwd)/tasmee.apk"
