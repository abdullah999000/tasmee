import os, sys, re

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

open(path, "w", encoding="utf-8").write(s)
print("manifest patched")

# draw under the notch / camera cutout too (true full screen)
styles = os.path.join(os.path.dirname(path), "..", "res", "values", "styles.xml")
if os.path.exists(styles):
    t = open(styles, encoding="utf-8").read()
    if "windowLayoutInDisplayCutoutMode" not in t:
        item = '        <item name="android:windowLayoutInDisplayCutoutMode">shortEdges</item>\n'
        t = re.sub(r'(<style name="(?:LaunchTheme|NormalTheme)"[^>]*>\n)', lambda m: m.group(1) + item, t)
        open(styles, "w", encoding="utf-8").write(t)
        print("styles patched")

# Prevent Android Lint (AndroidLintWorkAction / lintVitalAnalyzeRelease) crashes during release APK builds
# and ensure noCompress for bundled GGML model so Android loads it fast without double extraction
app_dir = os.path.abspath(os.path.join(os.path.dirname(path), "..", ".."))
for fname, is_kts in [("build.gradle.kts", True), ("build.gradle", False)]:
    gpath = os.path.join(app_dir, fname)
    if os.path.exists(gpath):
        g = open(gpath, encoding="utf-8").read()
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
                open(gpath, "w", encoding="utf-8").write(g_new)
                print(f"{fname} patched (disabled release lint crash + noCompress bin)")
