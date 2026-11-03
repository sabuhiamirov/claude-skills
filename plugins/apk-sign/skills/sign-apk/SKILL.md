---
name: sign-apk
description: Sign or re-sign an Android APK with any keystore (.jks, .keystore, .p12, or .pk8 + .x509.pem), verify the signature, and optionally install it on a connected device with adb. Use when the user wants to sign or re-sign an APK, replace an APK's signature, or check which certificate an APK is signed with. Works on macOS, Linux and Windows.
---

# Sign / re-sign an APK

This skill wraps two scripts that live next to this file:

- `scripts/sign.sh` for macOS and Linux (bash)
- `scripts/sign.ps1` for Windows (PowerShell 5.1+ or PowerShell 7)

The scripts do all the work: they find the Android SDK, build-tools and Java, then run
zipalign → apksigner sign → apksigner verify, and optionally adb install. Do not
re-implement these steps by hand; run the script. Resolve the script path from this
skill's base directory.

## 1. Collect the inputs

Ask only for what the user has not already given:

| Input | Notes |
|---|---|
| APK path | Required. Signed or unsigned. It is never modified. |
| Signing key | Required. Either a keystore (`.jks` / `.keystore` / `.p12` / `.pfx`) or a `.pk8` private key. With a `.pk8`, the script looks for `<name>.x509.pem` next to it; ask for `--cert` only if that file doesn't exist. |
| Alias | Do not ask. The script detects it. If the keystore has several keys, the script lists them and you ask the user which one to use. |
| Install on device? | Optional. Ask: "Install the signed APK on a connected device too?" |
| Output path | Optional. The default is `<apk-name>-signed.apk` next to the input. |

Check that the files exist before running anything.

## 2. Passwords: never ask for them in chat

`.pk8` + `.pem` keys have no password, so you can run the script directly (step 3).

A keystore has a password, and your shell is not interactive, so the script cannot
prompt for it. Do **not** ask the user to type the password into the chat. Instead,
offer these options:

1. **Recommended: the user runs it in their own terminal.** Print the exact command
   (see step 3) for them to copy. The script asks for the password with hidden input.
2. **Password file.** The user creates a file that holds only the password, kept outside any
   git repo, and you pass `--pass-file <file>` (`-PassFile` on Windows). Never read or
   print that file yourself.
3. **Environment variable.** The user starts Claude Code from a shell where
   `APKSIGN_KS_PASS` (and `APKSIGN_KEY_PASS` if the key password is different) is
   already exported. Never set it in a command you run, because that would put the password in
   the transcript.

If the user insists on pasting the password into the chat, warn them once that it
will be stored in the conversation history, then use option 3 or 2 rather than putting
it on a command line.

## 3. Run the script

Detect the OS (`uname` on macOS/Linux, `$env:OS` on Windows) and pick the script.

macOS / Linux:
```bash
bash "<skill-dir>/scripts/sign.sh" -a "<app.apk>" -k "<keystore.jks>" [--pass-file <file>] [-i] [-s <serial>]
bash "<skill-dir>/scripts/sign.sh" -a "<app.apk>" --key "<key.pk8>" [--cert "<key.x509.pem>"] [-i]
```

Windows (PowerShell):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\sign.ps1" -Apk "<app.apk>" -Keystore "<keystore.jks>" [-PassFile <file>] [-Install] [-Serial <serial>]
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\sign.ps1" -Apk "<app.apk>" -Key "<key.pk8>" [-Cert "<key.x509.pem>"] [-Install]
```

Always quote paths, because they often contain spaces.

### Several devices or several aliases

In a non-interactive shell, the script stops and lists the choices. Show the list to the user,
let them pick one, and re-run with `--serial` / `-Serial` or `--alias` / `-Alias`.

### Uninstall needs explicit consent

If the device already has the app signed with a different key, Android refuses the
update and the script stops with "signed with a different key". Uninstalling **deletes
the app's data** on the device, such as logins and local settings. Tell the user this and ask before
you continue. Only after a clear "yes" may you re-run with `--allow-uninstall` /
`-AllowUninstall`. Never add that flag on your own.

## 4. Report the result

Tell the user:

- the output APK path
- the signer certificate DN (e.g. `O=...`) and SHA-256, so they can confirm it is the expected key
- which signature schemes verified (v1/v2/v3). With minSdk 24 or higher, only v2/v3 is
  normal; v1 is only added for older minSdk values.
- if installed: the device, the version, and the granted permissions if the user asked about them.

## Troubleshooting

| Message | Meaning / fix |
|---|---|
| `Android SDK not found` | Install Android Studio or the SDK command-line tools + build-tools, or set `ANDROID_HOME`. |
| `Java not found` | Install a JDK 17+ or Android Studio (its bundled JDK is detected automatically). |
| `Wrong keystore password` | Ask the user to re-run with the correct password. |
| `apksigner sign failed (wrong key password?)` | The key password differs from the keystore password; set `APKSIGN_KEY_PASS` or run interactively. |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Different signature on the device. See "Uninstall needs explicit consent". |
| `DELETE_FAILED_APP_PINNED` | The app is pinned (screen pinning / kiosk / lock task mode). The user must unpin it on the device; do not try to change device policies. |
| `No device connected` | Check the cable, run `adb devices`, and accept the USB debugging prompt on the device. |
| Windows: "running scripts is disabled" | Use `powershell -ExecutionPolicy Bypass -File ...` as shown above. |
