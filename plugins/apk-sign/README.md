# apk-sign

Sign or re-sign an Android APK with **any** keystore, verify the result, and optionally install it on a connected device. One command, the same on macOS, Linux and Windows. You can use it with or without [Claude Code](https://claude.com/claude-code).

Use it whenever an APK needs a different signature: signing an unsigned build, replacing a debug or CI signature with your release key, or signing with a key provided by a third party.

> **Not using Claude Code?** Go to [Option B](#option-b-without-claude-code). Run one script on macOS, Linux or Windows.

```
app.apk  ──zipalign──▶  apksigner sign  ──▶  apksigner verify  ──▶  app-signed.apk  ──(optional)──▶  adb install
```

- Works with `.jks`, `.keystore`, `.p12` / `.pfx`, and `.pk8` + `.x509.pem` key pairs
- Nothing is hard-coded: you pass the APK and the key every time
- The original APK is never modified
- Passwords are never passed as arguments or stored; they are asked with hidden input
- Uses `apksigner` (v2/v3 signatures), not `jarsigner` (v1 only), so the result installs on modern Android

---

## Requirements

| | |
|---|---|
| Android SDK **build-tools** | Comes with Android Studio (SDK Manager → SDK Tools → *Android SDK Build-Tools*) |
| Java 17+ | Any JDK, or the one bundled with Android Studio (detected automatically) |
| Android SDK **platform-tools** | Only for `--install` (provides `adb`) |

The SDK is found through `ANDROID_HOME` / `ANDROID_SDK_ROOT`, or in the default locations:

| OS | Default SDK location |
|---|---|
| macOS | `~/Library/Android/sdk` |
| Linux | `~/Android/Sdk` |
| Windows | `%LOCALAPPDATA%\Android\Sdk` |

---

## Option A: with Claude Code

Install it once:

```
/plugin marketplace add sabuhiamirov/claude-skills
/plugin install apk-sign@sabuhiamirov
```

Then, in any project:

```
/sign-apk
```

You can also just ask, for example "sign ~/Downloads/app.apk with ~/keys/release.jks and install it on the device". Claude asks for anything that is missing, runs the script, and explains the result.

> **Passwords:** Claude never asks for your keystore password in the chat. It gives you the command to run in your own terminal, or you can use a password file or the `APKSIGN_KS_PASS` environment variable (see [Passwords](#passwords)). `.pk8` keys have no password, so Claude can run those directly.

<details>
<summary>Install without the plugin system (copy the skill)</summary>

Copy `plugins/apk-sign/skills/sign-apk` to:

- `~/.claude/skills/sign-apk` to use it in all projects, or
- `<your-project>/.claude/skills/sign-apk` to use it in a single project

</details>

---

## Option B: without Claude Code

Download the repository (green **Code** button → *Download ZIP*, or `git clone`). The scripts are in
`plugins/apk-sign/skills/sign-apk/scripts/`.

### macOS / Linux

```bash
cd plugins/apk-sign/skills/sign-apk/scripts
chmod +x sign.sh            # first time only

# keystore (.jks / .keystore / .p12)
./sign.sh -a ~/Downloads/app.apk -k ~/keys/release.jks

# .pk8 + .x509.pem pair (the .pem next to the .pk8 is found automatically)
./sign.sh -a ~/Downloads/app.apk --key ~/keys/key.pk8

# sign and install on the connected device
./sign.sh -a ~/Downloads/app.apk -k ~/keys/release.jks --install
```

### Windows (PowerShell)

```powershell
cd plugins\apk-sign\skills\sign-apk\scripts

# keystore
powershell -ExecutionPolicy Bypass -File .\sign.ps1 -Apk C:\Users\me\Downloads\app.apk -Keystore C:\keys\release.jks

# .pk8 + .x509.pem pair
powershell -ExecutionPolicy Bypass -File .\sign.ps1 -Apk C:\Users\me\Downloads\app.apk -Key C:\keys\key.pk8

# sign and install on the connected device
powershell -ExecutionPolicy Bypass -File .\sign.ps1 -Apk C:\Users\me\Downloads\app.apk -Keystore C:\keys\release.jks -Install
```

`-ExecutionPolicy Bypass` is needed because Windows blocks downloaded scripts by default. It applies only to this one run.

### Example output

```
==> Reading keystore
    ✔ Key alias: my-key

==> 1/3 zipalign (4-byte alignment, required before apksigner)
    ✔ Aligned

==> 2/3 apksigner sign
    ✔ Signed: app-signed.apk

==> 3/3 apksigner verify
    Verified using v3 scheme (APK Signature Scheme v3): true
    Number of signers: 1
    Signer #1 certificate DN: CN=..., O=Example, C=..
    Signer #1 certificate SHA-256 digest: 3f9a1c...e07b
    ✔ Signature is valid
```

Compare the **SHA-256 digest** with the fingerprint you expect to make sure you used the right key.

---

## Options

| macOS / Linux | Windows | Description |
|---|---|---|
| `-a, --apk <file>` | `-Apk <file>` | APK to sign (signed or unsigned). **Required.** |
| `-k, --keystore <file>` | `-Keystore <file>` | `.jks` / `.keystore` / `.p12` / `.pfx` (a `.pk8` also works) |
| `--key <file>` | `-Key <file>` | `.pk8` private key |
| `--cert <file>` | `-Cert <file>` | `.x509.pem` certificate (auto-detected next to the `.pk8`) |
| `--alias <name>` | `-Alias <name>` | Key alias (auto-detected; asked if there are several) |
| `--pass-file <file>` | `-PassFile <file>` | Read the keystore password from a file |
| `-o, --out <file>` | `-Out <file>` | Output path (default `<name>-signed.apk`) |
| `-i, --install` | `-Install` | Install with `adb` after signing |
| `-s, --serial <id>` | `-Serial <id>` | Which device to use (asked if several are connected) |
| `--allow-uninstall` | `-AllowUninstall` | Uninstall an app with a different signature without asking (**deletes app data**) |
| `-h, --help` | `Get-Help .\sign.ps1` | Help |

Short form: `./sign.sh app.apk release.jks` or `.\sign.ps1 app.apk release.jks`.

## Passwords

The keystore password is read in this order:

1. the environment variables `APKSIGN_KS_PASS` and `APKSIGN_KEY_PASS` (the key password, only if it differs)
2. `--pass-file` / `-PassFile`: the first line of the file
3. a prompt in the terminal, with hidden input

Passwords are passed to `keytool` and `apksigner` through environment variables, never on the command line, so they don't appear in shell history or process lists. They are cleared when the script ends.

## Installing over an existing app

Android only lets an app update another app if both are **signed with the same key**. If the device already has the app with a different signature, the install fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. The script then offers to uninstall the old app first.

Uninstalling **deletes the app's data** on the device, such as logins and local settings, so the script always asks first. Use `--allow-uninstall` only when you are sure.

If the uninstall fails with `DELETE_FAILED_APP_PINNED`, the app is pinned (screen pinning / kiosk / lock task mode). Unpin the app (exit kiosk mode) on the device and run the script again.

---

## Doing it by hand

These are the commands the script runs for you. `BT` is your build-tools folder, e.g. `~/Library/Android/sdk/build-tools/36.0.0`.

```bash
# 1. Align the APK to 4-byte boundaries (required before apksigner)
"$BT/zipalign" -f -p 4 app.apk app-aligned.apk

# 2. Sign: this replaces any existing signature. You will be asked for the password.
"$BT/apksigner" sign --ks release.jks --ks-key-alias <alias> --out app-signed.apk app-aligned.apk
#    or with a .pk8 + .pem pair:
"$BT/apksigner" sign --key key.pk8 --cert key.x509.pem --out app-signed.apk app-aligned.apk

# 3. Verify and show the signing certificate
"$BT/apksigner" verify --verbose --print-certs app-signed.apk

# 4. (optional) Install. -r = replace the existing app
adb install -r app-signed.apk
```

To list the aliases in a keystore, run `keytool -list -keystore release.jks`.

> **Why not `jarsigner`?** Many older guides still use `jarsigner`, which only creates the old v1 signature. APKs that target Android 11+ (API 30+) need a v2 or v3 signature, so use `apksigner`.

---

## Security

- **Never commit signing keys** to git. Anyone who has your key and its password can sign APKs that Android accepts as updates of your app. This repo's `.gitignore` blocks key files and APKs.
- Keep keys and password files outside your project folders.
- The script reads your keys locally and does not send anything over the network.

## License

[MIT](../../LICENSE)
