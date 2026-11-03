---
name: app-icon
description: Preview, position and resize an app icon for iOS and Android, then generate every launcher icon size (iOS AppIcon.appiconset with Contents.json, Android mipmap PNGs, adaptive icon foreground/background XML, round icons, App Store 1024 and Play Store 512) and install them into a Flutter, React Native, Expo or native project. Use when the user wants to make, fix, resize, re-center or replace an app icon, says the icon looks too big, too small, cropped or off-centre on the home screen, or asks for the Android adaptive icon safe zone.
---

# App icon: preview, adjust, generate, install

This skill has two files next to it. Resolve their paths from this skill's base directory.

- `assets/editor.html`: a self-contained page. It shows the icon on iOS and Android home
  screens (light and dark wallpapers, circle and squircle masks, small sizes), lets the user
  drag and resize the artwork separately per platform, and exports a ZIP with every size.
  All image work happens in the browser, so nothing needs to be installed.
- `scripts/make_editor.py`: copies the page with the user's image and app name already
  loaded. Python standard library only.

Do not re-implement the resizing in another tool. The page encodes the PNGs itself so that
iOS icons have no alpha channel (App Store Connect rejects icons with one).

## 1. Find the source image

Use the image the user gives you. If they don't give one, look for it before asking:

- `flutter_launcher_icons` config in `pubspec.yaml` or `flutter_launcher_icons.yaml` (`image_path`)
- Expo `app.json` / `app.config.*` (`icon`, `android.adaptiveIcon.foregroundImage`)
- `assets/icon*.png`, `assets/images/*icon*`, `resources/icon.png`
- the existing 1024 icon in `ios/**/AppIcon.appiconset/`

A square PNG of at least 1024×1024 works best. If the image is smaller or not square, say so;
the page uses the centre square and still works.

Get the app name from the project (`pubspec.yaml` `name`, `app.json` `name`,
`android:label`, `CFBundleDisplayName`) or ask.

## 2. Open the editor

```bash
python3 "<skill-dir>/scripts/make_editor.py" "<image>" --name "<App name>" --out "<scratch-dir>/icon-editor.html" --open
```

Write the HTML to a temporary or scratch folder, not into the user's project. On Windows use
`python` or `py` instead of `python3`. If Python is missing, open `assets/editor.html`
directly and tell the user to pick the image with the file field.

Tell the user, briefly:

- drag the artwork or use the sliders; scroll on the icon to resize, arrow keys to nudge
- iOS and Android are separate ("Copy from iOS/Android" copies one to the other)
- on Android only the inside of the dashed circle is safe on every launcher
- the fill colours behind the artwork are sampled from the image edges and can be changed
- when it looks right, click **Download icons (.zip)** and tell you

Then wait for the user.

## 3. Get the ZIP

The browser saves `<app-name>-icons.zip`, normally in `~/Downloads`. Find the newest one
(`ls -t ~/Downloads/*-icons.zip | head -1`, or ask for the path) and extract it into a new
empty temporary folder. It contains:

```
ios/AppIcon.appiconset/            Contents.json + Icon-App-*.png (all iPhone/iPad sizes + 1024)
android/res/mipmap-*/              ic_launcher.png, ic_launcher_round.png, ic_launcher_foreground.png
android/res/mipmap-anydpi-v26/     ic_launcher.xml, ic_launcher_round.xml (adaptive icon)
android/res/values/                ic_launcher_background.xml (background colour)
store/                             app-store-1024.png, play-store-512.png, android-adaptive-foreground-1024.png
settings.json                      the editor settings, to reproduce the result
```

## 4. Install into the project

Detect the project type and the target folders:

| Project | iOS | Android res |
|---|---|---|
| Flutter | `ios/Runner/Assets.xcassets/AppIcon.appiconset` | `android/app/src/main/res` |
| React Native (bare) | `ios/<Name>/Images.xcassets/AppIcon.appiconset` | `android/app/src/main/res` |
| Native iOS | `find . -path '*AppIcon.appiconset' -not -path '*/Pods/*'` | |
| Native Android | | `app/src/main/res` (or the module in `settings.gradle`) |
| Capacitor / Ionic | `ios/App/App/Assets.xcassets/AppIcon.appiconset` | `android/app/src/main/res` |
| Expo (managed) | `store/app-store-1024.png` as `icon` | `store/android-adaptive-foreground-1024.png` as `adaptiveIcon.foregroundImage`, colour from `ic_launcher_background.xml` as `backgroundColor` |

Before copying anything:

1. Read `AndroidManifest.xml`. If `android:icon` / `android:roundIcon` use other names than
   `@mipmap/ic_launcher` / `@mipmap/ic_launcher_round`, either rename the generated files to
   match or update the manifest. Ask which the user prefers.
2. Check for existing `mipmap-anydpi-v26/ic_launcher*.xml` and
   `values/ic_launcher_background.xml`. Ours replace them. If the old XML references a
   `@drawable/...` vector background, that drawable stays in place but is no longer used; mention it.
3. If the project uses `flutter_launcher_icons` or another generator, warn that running it
   again would overwrite these icons, and offer to remove or update its config.
4. Show the user the list of files that will be replaced and get a yes. The project should be
   under git so the change can be reverted; if it isn't, say so.

Then:

- iOS: replace the whole `AppIcon.appiconset` folder contents with the generated one (old
  files with other names would otherwise stay referenced by nothing, or by the old Contents.json).
- Android: copy `android/res/*` over the res folder (merge, don't delete other mipmap files).
- Keep `settings.json` only if the user wants it (e.g. `assets/icon-settings.json`).

## 5. Tell the user how to see it

- iOS caches icons: delete the app from the simulator/device and run again.
- Android: reinstall or run again; some launchers need the app removed from the home screen
  and added back.
- Store icons (`store/`) are uploaded by hand in App Store Connect and Google Play Console.

Report which files changed. To redo it later, open the editor again: the page remembers the
last settings for the same app name in that browser.
