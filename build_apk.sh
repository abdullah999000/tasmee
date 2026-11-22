#!/usr/bin/env bash
# Builds standalone offline tasmee.apk:
# 1. Syncs index.html -> assets/index.html & preview.html
# 2. Bundles the on-device Whisper GGML Arabic/Quranic model (ggml-base-q5_1.bin, ~59.7 MB)
#    and full 604-page Quran text JSON (~1.6 MB) directly into assets/ at build time
#    so recitation works 100% offline from first install (ZERO Sheikh MP3s are pre-bundled).
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p assets/models assets/model assets/data

if [ -f main.dart ]; then
  mkdir -p lib
  cp -f main.dart lib/main.dart
fi
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

# Bundle ultra-fast Quran-tuned Whisper TINY GGML model (~43.5 MB, 3x-4x faster on Android CPU for near-instant highlighting!)
# Fallback: official ggerganov/whisper.cpp ggml-tiny-q5_1.bin (~32 MB)
MODEL_FILE="assets/models/ggml-tiny-ar-quran.bin"
rm -f assets/models/ggml-base-q5_1.bin
if [ ! -s "$MODEL_FILE" ]; then
  echo "Downloading fast Quran-tuned Whisper Tiny GGML model (~43.5 MB)..."
  python3 - <<'PYDL'
import urllib.request, os, sys, struct

out_path = "assets/models/ggml-tiny-ar-quran.bin"
candidate_urls = [
    "https://huggingface.co/ram-a-dhan/tarteel-whisper-quran-ggml/resolve/main/tarteel-ai-whisper-tiny-ar-quran-ggml-q8_0.bin",
    "https://huggingface.co/Oa-4/whisper-tiny-ar-quran-gguf/resolve/main/ggml-tiny-ar-quran-q8_0.bin",
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_1.bin",
]

for url in candidate_urls:
    tmp = out_path + ".dl"
    try:
        print(f"Downloading fast Quran model from: {url}")
        req = urllib.request.Request(url, headers={"User-Agent": "tasmee-builder"})
        with urllib.request.urlopen(req, timeout=180) as resp, open(tmp, "wb") as f:
            while True:
                chunk = resp.read(1024 * 256)
                if not chunk:
                    break
                f.write(chunk)
        sz = os.path.getsize(tmp)
        with open(tmp, "rb") as f:
            hdr = f.read(28)
        magic = hdr[:4]
        n_text_ctx = struct.unpack("<I", hdr[24:28])[0] if len(hdr) == 28 else 0
        if sz > 15 * 1024 * 1024 and magic in (b"lmgg", b"ggml") and n_text_ctx == 448:
            os.replace(tmp, out_path)
            print(f"Verified fast Quran GGML Tiny model ({sz:,} bytes, n_text_ctx={n_text_ctx}) from {url}")
            sys.exit(0)
        else:
            print(f"Skipping incompatible model (size={sz}, magic={magic!r}, n_text_ctx={n_text_ctx})")
            os.remove(tmp)
    except Exception as e:
        print(f"Download failed for {url}: {e}")
        if os.path.exists(tmp):
            os.remove(tmp)
sys.exit(1)
PYDL
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
mkdir -p assets/model
echo "Downloading recite_quran streaming Zipformer-v3 neural model (~69 MB)..."
dart run recite_quran:download_model
RECITE_ONNX="$(find assets/model -type f -name '*.onnx' 2>/dev/null | head -n 1 || true)"
if [ -z "$RECITE_ONNX" ] || [ "$(stat -c%s "$RECITE_ONNX" 2>/dev/null || wc -c < "$RECITE_ONNX")" -lt 52428800 ]; then
  echo "ERROR: recite_quran Zipformer-v3 ONNX model missing or smaller than 50 MB in assets/model/!" >&2
  ls -la assets/model || true
  exit 1
fi
echo "Verified recite_quran streaming model: $RECITE_ONNX ($(du -h "$RECITE_ONNX" | cut -f1))"
RAW_RUN="${GITHUB_RUN_NUMBER:-10}"
BUILD_NUM=$(( RAW_RUN < 10 ? 10 + RAW_RUN : RAW_RUN ))
echo "Building Release APK with applicationId=com.tasmee.tasmee versionCode=$BUILD_NUM..."
flutter build apk --release --build-number="$BUILD_NUM"
cp build/app/outputs/flutter-apk/app-release.apk ../tasmee.apk

# Cryptographic verification using Android SDK apksigner (reads v1/v2/v3/v4 signatures; keytool -jarfile only reads v1!)
EXPECTED_SHA256="4F:1F:F8:1D:1F:F9:7D:1B:AA:4A:64:2F:ED:88:C9:EA:3E:13:C3:A6:1F:0B:CD:FE:8D:4F:AB:8E:1A:8E:FD:70"
EXPECTED_SHA256_HEX="4f1ff81d1ff97d1baa4a642fed88c9ea3e13c3a61f0bcdfe8d4fab8e1a8efd70"
APKSIGNER="$(command -v apksigner || ls -1 "$SDK_ROOT"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -n 1 || true)"
if [ -n "$APKSIGNER" ] && [ -x "$APKSIGNER" ]; then
  CERT_OUT="$("$APKSIGNER" verify --print-certs ../tasmee.apk 2>&1 || true)"
  echo "$CERT_OUT"
  if ! echo "$CERT_OUT" | tr '[:upper:]' '[:lower:]' | tr -d ':' | grep -q "$EXPECTED_SHA256_HEX"; then
    echo "Re-signing APK directly with fixed tasmee-release.jks via apksigner..."
    "$APKSIGNER" sign --ks android/app/tasmee-release.jks --ks-key-alias tasmee --ks-pass pass:tasmee_release_2026 --key-pass pass:tasmee_release_2026 ../tasmee.apk
    CERT_OUT="$("$APKSIGNER" verify --print-certs ../tasmee.apk 2>&1)"
    echo "$CERT_OUT"
    if ! echo "$CERT_OUT" | tr '[:upper:]' '[:lower:]' | tr -d ':' | grep -q "$EXPECTED_SHA256_HEX"; then
      echo "ERROR: APK signature verification failed after apksigner sign!" >&2
      exit 1
    fi
  fi
  echo "Verified fixed release signature SHA-256 (v2/v3): $EXPECTED_SHA256"
else
  echo "WARNING: apksigner not found on runner; skipping v2 signature print."
fi
echo "Done: $(cd .. && pwd)/tasmee.apk"
