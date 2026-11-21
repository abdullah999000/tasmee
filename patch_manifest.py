import base64, os, sys, re

EMBEDDED_KEYSTORE_B64 = "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"

path = sys.argv[1]
s = open(path, encoding="utf-8").read()

perms = (
    '    <uses-permission android:name="android.permission.INTERNET"/>\n'
    '    <uses-permission android:name="android.permission.RECORD_AUDIO"/>\n'
    '    <uses-permission android:name="android.permission.WAKE_LOCK"/>\n'
    '    <uses-permission android:name="android.permission.VIBRATE"/>\n'
    '    <uses-permission android:name="android.permission.READ_MEDIA_AUDIO"/>\n'
    '    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>\n'
    '    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29"/>\n'
)
queries = (
    '    <queries>\n'
    '        <intent><action android:name="android.speech.RecognitionService"/></intent>\n'
    '    </queries>\n'
)

if "RECORD_AUDIO" not in s:
    s = s.replace("<application", perms + "    <application", 1)
if "RecognitionService" not in s:
    s = s.replace("</manifest>", queries + "</manifest>", 1)
# Arabic app name on the launcher
s = re.sub(r'android:label="[^"]*"', 'android:label="مُسمِّع"', s, count=1)
if "android:largeHeap" not in s:
    s = s.replace("<application", '<application android:largeHeap="true"', 1)

open(path, "w", encoding="utf-8").write(s)
print("manifest patched")

# Draw under the notch / camera cutout too (true full screen)
styles = os.path.join(os.path.dirname(path), "..", "res", "values", "styles.xml")
if os.path.exists(styles):
    t = open(styles, encoding="utf-8").read()
    if "windowLayoutInDisplayCutoutMode" not in t:
        item = '        <item name="android:windowLayoutInDisplayCutoutMode">shortEdges</item>\n'
        t = re.sub(r'(<style name="(?:LaunchTheme|NormalTheme)"[^>]*>\n)', lambda m: m.group(1) + item, t)
        open(styles, "w", encoding="utf-8").write(t)
        print("styles patched")

# Ensure fixed release keystore exists inside android/app/ even if .jks file wasn't uploaded separately
app_dir = os.path.abspath(os.path.join(os.path.dirname(path), "..", ".."))
ks_file = os.path.join(app_dir, "tasmee-release.jks")
if not os.path.exists(ks_file):
    with open(ks_file, "wb") as f:
        f.write(base64.b64decode(EMBEDDED_KEYSTORE_B64))
    print("tasmee-release.jks reconstructed from embedded deterministic keystore")

# Patch build.gradle.kts / build.gradle:
# 1) Disable release Lint crash + noCompress("bin") for fast GGML loading
# 2) Ensure minSdk >= 24 (required by whisper_ggml)
# 3) Wire fixed release signingConfig (tasmee-release.jks) so all future APKs install seamlessly over prior builds
for fname, is_kts in [("build.gradle.kts", True), ("build.gradle", False)]:
    gpath = os.path.join(app_dir, fname)
    if os.path.exists(gpath):
        g = open(gpath, encoding="utf-8").read()
        changed = False

        if "checkReleaseBuilds" not in g:
            lint_block = (
                "\n    lint {\n"
                "        checkReleaseBuilds = false\n"
                "        abortOnError = false\n"
                "    }\n"
                "    androidResources {\n"
                "        noCompress += listOf(\"bin\")\n"
                "    }\n"
                if is_kts else
                "\n    lint {\n"
                "        checkReleaseBuilds false\n"
                "        abortOnError false\n"
                "    }\n"
                "    aaptOptions {\n"
                "        noCompress \"bin\"\n"
                "    }\n"
            )
            g_new = re.sub(r'(android\s*\{)', r'\1' + lint_block, g, count=1)
            if g_new != g:
                g = g_new
                changed = True
                print(f"{fname} patched (disabled release lint crash + noCompress bin)")

        # Enforce minSdk = 24 and ndkVersion = "29.0.13113456" for whisper_ggml compatibility
        if is_kts:
            g_min = re.sub(r'minSdk\s*=\s*flutter\.minSdkVersion', 'minSdk = 24', g)
            g_min = re.sub(r'ndkVersion\s*=\s*flutter\.ndkVersion', 'ndkVersion = "29.0.13113456"', g_min)
        else:
            g_min = re.sub(r'minSdk(?:Version)?\s+flutter\.minSdkVersion', 'minSdkVersion 24', g)
            g_min = re.sub(r'ndkVersion\s+flutter\.ndkVersion', 'ndkVersion "29.0.13113456"', g_min)
        if g_min != g:
            g = g_min
            changed = True
            print(f"{fname} patched (minSdk = 24)")

        if os.path.exists(ks_file) and "tasmee-release.jks" not in g:
            if is_kts:
                sign_block = (
                    "\n    signingConfigs {\n"
                    "        create(\"release\") {\n"
                    "            storeFile = file(\"tasmee-release.jks\")\n"
                    "            storePassword = \"tasmee_release_2026\"\n"
                    "            keyAlias = \"tasmee\"\n"
                    "            keyPassword = \"tasmee_release_2026\"\n"
                    "        }\n"
                    "    }\n"
                )
                g_s = re.sub(r'(android\s*\{)', r'\1' + sign_block, g, count=1)
                g_s = re.sub(
                    r"""signingConfig\s*=\s*signingConfigs\.(?:getByName|findByName)\(["']debug["']\)|signingConfig\s*=\s*signingConfigs\[["']debug["']\]""",
                    'signingConfig = signingConfigs.getByName("release")',
                    g_s,
                )
            else:
                sign_block = (
                    "\n    signingConfigs {\n"
                    "        release {\n"
                    "            storeFile file(\"tasmee-release.jks\")\n"
                    "            storePassword \"tasmee_release_2026\"\n"
                    "            keyAlias \"tasmee\"\n"
                    "            keyPassword \"tasmee_release_2026\"\n"
                    "        }\n"
                    "    }\n"
                )
                g_s = re.sub(r'(android\s*\{)', r'\1' + sign_block, g, count=1)
                g_s = re.sub(
                    r'signingConfig\s+signingConfigs\.debug',
                    'signingConfig signingConfigs.release',
                    g_s,
                )
            if g_s != g:
                g = g_s
                changed = True
                print(f"{fname} patched (fixed release signing keystore)")

        if changed:
            open(gpath, "w", encoding="utf-8").write(g)
