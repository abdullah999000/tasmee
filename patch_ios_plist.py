import sys

# Patches ios/Runner/Info.plist so iOS Files app exposes "On My iPhone -> مُسمِّع -> Quran App Audio"
# and enables microphone permission for fully offline on-device Quran recitation.
if len(sys.argv) < 2:
    print("Usage: python3 patch_ios_plist.py <path/to/Info.plist>")
    sys.exit(1)

plist_path = sys.argv[1]
s = open(plist_path, encoding="utf-8").read()

additions = ""
if "UIFileSharingEnabled" not in s:
    additions += "\t<key>UIFileSharingEnabled</key>\n\t<true/>\n"
if "LSSupportsOpeningDocumentsInPlace" not in s:
    additions += "\t<key>LSSupportsOpeningDocumentsInPlace</key>\n\t<true/>\n"
if "NSMicrophoneUsageDescription" not in s:
    additions += "\t<key>NSMicrophoneUsageDescription</key>\n\t<string>يستخدم التطبيق الميكروفون للتسميع القرآني المحلي دون إنترنت.</string>\n"

if additions:
    s = s.replace("</dict>\n</plist>", additions + "</dict>\n</plist>", 1)
    open(plist_path, "w", encoding="utf-8").write(s)
    print("Info.plist patched for iOS Files app sharing & offline microphone")
else:
    print("Info.plist already patched")
