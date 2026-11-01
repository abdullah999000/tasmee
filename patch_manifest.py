import sys, re

path = sys.argv[1]
s = open(path, encoding="utf-8").read()

perms = (
    '    <uses-permission android:name="android.permission.INTERNET"/>\n'
    '    <uses-permission android:name="android.permission.RECORD_AUDIO"/>\n'
    '    <uses-permission android:name="android.permission.WAKE_LOCK"/>\n'
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
import os
styles = os.path.join(os.path.dirname(path), "..", "res", "values", "styles.xml")
if os.path.exists(styles):
    t = open(styles, encoding="utf-8").read()
    if "windowLayoutInDisplayCutoutMode" not in t:
        item = '        <item name="android:windowLayoutInDisplayCutoutMode">shortEdges</item>\n'
        t = re.sub(r'(<style name="(?:LaunchTheme|NormalTheme)"[^>]*>\n)', lambda m: m.group(1) + item, t)
        open(styles, "w", encoding="utf-8").write(t)
        print("styles patched")
