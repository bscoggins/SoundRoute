SoundRoute macOS App Icon Assets

Use in Xcode:
1. Open Assets.xcassets in Xcode.
2. Delete or replace the existing AppIcon set.
3. Drag the folder "SoundRoute.appiconset" into Assets.xcassets.
4. Make sure your app target's App Icons Source is set to "SoundRoute" or rename the folder to "AppIcon.appiconset".

Optional .icns conversion on macOS:
Run this in Terminal from inside this folder:
iconutil -c icns SoundRoute.iconset

Included:
- SoundRoute.appiconset: Xcode-ready macOS app icon asset catalog set.
- SoundRoute.iconset: macOS iconset folder for iconutil conversion.
- SoundRoute_AppIcon_1024.png: master 1024x1024 PNG.
- SoundRoute_AppIcon_Preview.png: preview sheet.
