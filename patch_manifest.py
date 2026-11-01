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
