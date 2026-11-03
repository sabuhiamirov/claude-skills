#!/usr/bin/env bash
#
# sign.sh - sign or re-sign an Android APK with any keystore (macOS / Linux).
#
# Steps: zipalign -> apksigner sign -> apksigner verify -> (optional) adb install.
# The original APK is never modified; a new "<name>-signed.apk" is written next to it.
#
# Passwords are never accepted as command-line arguments. They are read, in order, from:
#   1. the APKSIGN_KS_PASS / APKSIGN_KEY_PASS environment variables
#   2. a file given with --pass-file (first line = password)
#   3. an interactive prompt (hidden input)

set -euo pipefail

VERSION="1.0.0"

# ---------------------------------------------------------------- output helpers

if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_RESET=""
fi

step() { printf '\n%s==> %s%s\n' "$C_BOLD" "$1" "$C_RESET"; }
info() { printf '    %s\n' "$1"; }
ok()   { printf '    %s✔ %s%s\n' "$C_GREEN" "$1" "$C_RESET"; }
warn() { printf '    %s! %s%s\n' "$C_YELLOW" "$1" "$C_RESET" >&2; }
die()  { printf '\n%sERROR:%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sign.sh -a <app.apk> -k <keystore.jks|.keystore|.p12> [options]
  sign.sh -a <app.apk> --key <key.pk8> --cert <key.x509.pem> [options]
  sign.sh <app.apk> <keystore>            (short form)

Required:
  -a, --apk <file>          APK to sign (signed or unsigned)
  -k, --keystore <file>     Java keystore (.jks / .keystore / .p12 / .pfx).
                            A .pk8 file is accepted too (same as --key).
      --key <file>          PKCS#8 private key (.pk8), used together with --cert
      --cert <file>         X.509 certificate (.x509.pem / .pem). If omitted with
                            --key, <name>.x509.pem next to the .pk8 is used.

Options:
      --alias <name>        Key alias inside the keystore (auto-detected if omitted)
      --pass-file <file>    Read the keystore password from the first line of a file
  -o, --out <file>          Output APK (default: <apk-name>-signed.apk)
  -i, --install             Install the signed APK on a connected device with adb
  -s, --serial <id>         Device serial for --install (asked if several devices)
      --allow-uninstall     If the installed app has a different signature, uninstall
                            it without asking. WARNING: this deletes the app's data.
  -h, --help                Show this help
  -v, --version             Show the version

Environment:
  ANDROID_HOME / ANDROID_SDK_ROOT   Android SDK location (auto-detected otherwise)
  APKSIGN_KS_PASS                   Keystore password (non-interactive use)
  APKSIGN_KEY_PASS                  Key password, if different from the keystore password
EOF
}

# ---------------------------------------------------------------- arguments

APK=""; KEYSTORE=""; KEY=""; CERT=""; ALIAS=""; OUT=""; PASS_FILE=""
INSTALL=0; SERIAL=""; ALLOW_UNINSTALL=0
POSITIONAL=()

need_value() { [ $# -ge 2 ] && [ -n "$2" ] || die "Option $1 needs a value. Run with --help."; }

while [ $# -gt 0 ]; do
  case "$1" in
    -a|--apk)          need_value "$@"; APK="$2"; shift 2 ;;
    -k|--keystore)     need_value "$@"; KEYSTORE="$2"; shift 2 ;;
    --key)             need_value "$@"; KEY="$2"; shift 2 ;;
    --cert)            need_value "$@"; CERT="$2"; shift 2 ;;
    --alias)           need_value "$@"; ALIAS="$2"; shift 2 ;;
    --pass-file)       need_value "$@"; PASS_FILE="$2"; shift 2 ;;
    -o|--out)          need_value "$@"; OUT="$2"; shift 2 ;;
    -i|--install)      INSTALL=1; shift ;;
    -s|--serial)       need_value "$@"; SERIAL="$2"; shift 2 ;;
    --allow-uninstall) ALLOW_UNINSTALL=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    -v|--version)      echo "sign.sh $VERSION"; exit 0 ;;
    -*)                die "Unknown option: $1. Run with --help." ;;
    *)                 POSITIONAL+=("$1"); shift ;;
  esac
done

# Short form: sign.sh app.apk keystore
if [ ${#POSITIONAL[@]} -ge 1 ] && [ -z "$APK" ]; then APK="${POSITIONAL[0]}"; fi
if [ ${#POSITIONAL[@]} -ge 2 ] && [ -z "$KEYSTORE" ] && [ -z "$KEY" ]; then KEYSTORE="${POSITIONAL[1]}"; fi

[ -n "$APK" ] || { usage; die "No APK given."; }
[ -f "$APK" ] || die "APK not found: $APK"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# A .pk8 passed as --keystore means key + certificate mode.
if [ -n "$KEYSTORE" ] && [ "$(lower "${KEYSTORE##*.}")" = "pk8" ]; then
  KEY="$KEYSTORE"; KEYSTORE=""
fi

if [ -n "$KEY" ]; then
  MODE="pk8"
  [ -f "$KEY" ] || die "Private key not found: $KEY"
  if [ -z "$CERT" ]; then
    base="${KEY%.*}"
    for c in "$base.x509.pem" "$base.pem" "$base.crt"; do
      if [ -f "$c" ]; then CERT="$c"; break; fi
    done
    [ -n "$CERT" ] || die "No certificate found next to $KEY. Pass it with --cert <file.x509.pem>."
  fi
  [ -f "$CERT" ] || die "Certificate not found: $CERT"
elif [ -n "$KEYSTORE" ]; then
  MODE="keystore"
  [ -f "$KEYSTORE" ] || die "Keystore not found: $KEYSTORE"
else
  usage; die "No keystore given. Use -k <keystore> or --key <file.pk8> --cert <file.pem>."
fi

if [ -z "$OUT" ]; then
  OUT="${APK%.*}-signed.apk"
fi
# Resolve both to absolute paths before comparing, so "./a.apk" and "a.apk" match.
abs_path() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s' "$(pwd)" "$(basename "$1")"); }
[ "$(abs_path "$APK")" != "$(abs_path "$OUT")" ] || die "Output must differ from the input APK."
[ -d "$(dirname "$OUT")" ] || die "Output folder does not exist: $(dirname "$OUT")"

# ---------------------------------------------------------------- tools

step "Looking for tools"

find_sdk() {
  local c
  for c in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
           "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" "$HOME/Android/sdk" \
           "/opt/android-sdk" "/usr/lib/android-sdk"; do
    if [ -n "$c" ] && [ -d "$c/build-tools" ]; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

SDK="$(find_sdk)" || die "Android SDK not found.
       Install Android Studio (or the command-line tools + build-tools) and/or set ANDROID_HOME.
       Typical locations: macOS ~/Library/Android/sdk, Linux ~/Android/Sdk"
info "Android SDK:  $SDK"

# Highest stable build-tools version (e.g. 36.0.0); release candidates only as a fallback.
pick_build_tools() {
  local dirs best
  dirs="$(ls -1 "$SDK/build-tools" 2>/dev/null || true)"
  best="$(printf '%s\n' "$dirs" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1 || true)"
  [ -n "$best" ] || best="$(printf '%s\n' "$dirs" | grep -E '^[0-9]' | sort | tail -n1 || true)"
  [ -n "$best" ] || return 1
  printf '%s' "$SDK/build-tools/$best"
}

BT="$(pick_build_tools)" || die "No build-tools installed in $SDK/build-tools.
       Install one from Android Studio > SDK Manager > SDK Tools > Android SDK Build-Tools."
ZIPALIGN="$BT/zipalign"
APKSIGNER="$BT/apksigner"
[ -x "$ZIPALIGN" ] || die "zipalign not found in $BT"
[ -x "$APKSIGNER" ] || die "apksigner not found in $BT"
info "Build-tools:  $BT"

# apksigner and keytool need Java. Fall back to the JDK bundled with Android Studio.
if ! command -v java >/dev/null 2>&1 && [ -z "${JAVA_HOME:-}" ]; then
  for j in "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
           "$HOME/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
           "/opt/android-studio/jbr" "$HOME/android-studio/jbr" "/snap/android-studio/current/jbr"; do
    if [ -x "$j/bin/java" ]; then export JAVA_HOME="$j"; break; fi
  done
fi
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
  export PATH="$JAVA_HOME/bin:$PATH"
fi
command -v java >/dev/null 2>&1 || die "Java not found. Install a JDK (17+) or Android Studio, or set JAVA_HOME."
info "Java:         $(java -version 2>&1 | head -n1)"

# ---------------------------------------------------------------- passwords + alias

cleanup_secrets() { unset APKSIGN_KS_PASS APKSIGN_KEY_PASS 2>/dev/null || true; }

if [ "$MODE" = "keystore" ]; then
  command -v keytool >/dev/null 2>&1 || die "keytool not found (it ships with the JDK)."

  if [ -z "${APKSIGN_KS_PASS:-}" ]; then
    if [ -n "$PASS_FILE" ]; then
      [ -f "$PASS_FILE" ] || die "Password file not found: $PASS_FILE"
      APKSIGN_KS_PASS="$(head -n1 "$PASS_FILE" | tr -d '\r')"
    elif [ -t 0 ]; then
      read -r -s -p "    Keystore password: " APKSIGN_KS_PASS; echo
    else
      die "No keystore password available and no terminal to ask for it.
       Run the script in a terminal, or set APKSIGN_KS_PASS, or use --pass-file <file>."
    fi
  fi
  if [ -z "${APKSIGN_KEY_PASS:-}" ]; then
    if [ -z "$PASS_FILE" ] && [ -t 0 ]; then
      read -r -s -p "    Key password (press Enter if same as keystore password): " APKSIGN_KEY_PASS; echo
    fi
    [ -n "${APKSIGN_KEY_PASS:-}" ] || APKSIGN_KEY_PASS="$APKSIGN_KS_PASS"
  fi
  export APKSIGN_KS_PASS APKSIGN_KEY_PASS
  trap cleanup_secrets EXIT

  step "Reading keystore"
  set +e
  KT_OUT="$(keytool -J-Duser.language=en -list -keystore "$KEYSTORE" -storepass:env APKSIGN_KS_PASS 2>&1)"
  KT_RC=$?
  set -e
  if [ $KT_RC -ne 0 ]; then
    if printf '%s' "$KT_OUT" | grep -qi "password was incorrect\|keystore was tampered"; then
      die "Wrong keystore password."
    fi
    die "Could not read the keystore:
$KT_OUT"
  fi

  # Lines look like: "alias-name, Sep 22, 2020, PrivateKeyEntry,"
  ALIASES="$(printf '%s\n' "$KT_OUT" | grep 'PrivateKeyEntry' | sed 's/,.*//' || true)"
  [ -n "$ALIASES" ] || die "The keystore contains no private key entry."
  ALIAS_COUNT="$(printf '%s\n' "$ALIASES" | wc -l | tr -d ' ')"

  if [ -n "$ALIAS" ]; then
    printf '%s\n' "$ALIASES" | grep -qxF "$ALIAS" || die "Alias '$ALIAS' not found. Available: $(printf '%s' "$ALIASES" | tr '\n' ' ')"
  elif [ "$ALIAS_COUNT" -eq 1 ]; then
    ALIAS="$ALIASES"
  elif [ -t 0 ]; then
    info "The keystore has $ALIAS_COUNT keys:"
    i=1
    while IFS= read -r a; do info "  $i) $a"; i=$((i + 1)); done <<< "$ALIASES"
    read -r -p "    Choose a number: " n
    ALIAS="$(printf '%s\n' "$ALIASES" | sed -n "${n}p")"
    [ -n "$ALIAS" ] || die "Invalid choice."
  else
    die "The keystore has several keys; pass one with --alias. Available: $(printf '%s' "$ALIASES" | tr '\n' ' ')"
  fi
  ok "Key alias: $ALIAS"
fi

# ---------------------------------------------------------------- sign

TMP_ALIGNED="${OUT%.*}.aligned.tmp.apk"
cleanup() { rm -f "$TMP_ALIGNED"; cleanup_secrets; }
trap cleanup EXIT

step "1/3 zipalign (4-byte alignment, required before apksigner)"
"$ZIPALIGN" -f -p 4 "$APK" "$TMP_ALIGNED" || die "zipalign failed."
ok "Aligned"

step "2/3 apksigner sign"
if [ "$MODE" = "keystore" ]; then
  "$APKSIGNER" sign \
    --ks "$KEYSTORE" --ks-key-alias "$ALIAS" \
    --ks-pass env:APKSIGN_KS_PASS --key-pass env:APKSIGN_KEY_PASS \
    --v4-signing-enabled false \
    --out "$OUT" "$TMP_ALIGNED" || die "apksigner sign failed (wrong key password?)."
else
  "$APKSIGNER" sign \
    --key "$KEY" --cert "$CERT" \
    --v4-signing-enabled false \
    --out "$OUT" "$TMP_ALIGNED" || die "apksigner sign failed."
fi
rm -f "$TMP_ALIGNED"
cleanup_secrets
ok "Signed: $OUT"

step "3/3 apksigner verify"
set +e
VERIFY_OUT="$("$APKSIGNER" verify --verbose --print-certs "$OUT" 2>&1)"
VERIFY_RC=$?
set -e
[ $VERIFY_RC -eq 0 ] || die "Verification failed:
$VERIFY_OUT"
printf '%s\n' "$VERIFY_OUT" | grep -E '^Verified using v[0-9.]+ scheme.*: true|^Number of signers|certificate DN|certificate SHA-256' | sed 's/^/    /'
ok "Signature is valid"

# ---------------------------------------------------------------- install (optional)

if [ "$INSTALL" -eq 1 ]; then
  step "Installing on device"
  ADB="$SDK/platform-tools/adb"
  [ -x "$ADB" ] || ADB="$(command -v adb || true)"
  [ -n "$ADB" ] || die "adb not found. Install 'Android SDK Platform-Tools' from the SDK Manager."

  if [ -z "$SERIAL" ]; then
    DEVICES="$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1 }')"
    COUNT="$(printf '%s' "$DEVICES" | grep -c . || true)"
    if [ "$COUNT" -eq 0 ]; then
      die "No device connected (check the USB cable and 'adb devices'; unauthorized devices must accept the USB debugging prompt)."
    elif [ "$COUNT" -eq 1 ]; then
      SERIAL="$DEVICES"
    elif [ -t 0 ]; then
      info "Several devices are connected:"
      i=1
      while IFS= read -r d; do
        model="$("$ADB" -s "$d" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
        info "  $i) $d  $model"; i=$((i + 1))
      done <<< "$DEVICES"
      read -r -p "    Choose a number: " n
      SERIAL="$(printf '%s\n' "$DEVICES" | sed -n "${n}p")"
      [ -n "$SERIAL" ] || die "Invalid choice."
    else
      die "Several devices are connected; choose one with --serial. Devices: $(printf '%s' "$DEVICES" | tr '\n' ' ')"
    fi
  fi
  info "Device: $SERIAL ($("$ADB" -s "$SERIAL" shell getprop ro.product.model 2>/dev/null | tr -d '\r'))"

  PKG="$("$BT/aapt2" dump packagename "$OUT" 2>/dev/null | head -n1 | tr -d '\r' || true)"
  [ -n "$PKG" ] || PKG="$("$BT/aapt" dump badging "$OUT" 2>/dev/null | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -n1 || true)"
  [ -n "$PKG" ] && info "Package: $PKG"

  do_install() { "$ADB" -s "$SERIAL" install -r --no-incremental "$OUT" 2>&1 || true; }

  INSTALL_OUT="$(do_install)"
  if printf '%s' "$INSTALL_OUT" | grep -q "INSTALL_FAILED_UPDATE_INCOMPATIBLE"; then
    warn "The app already installed on the device is signed with a different key."
    warn "It must be uninstalled first. This DELETES the app's data on the device."
    [ -n "$PKG" ] || die "Could not read the package name to uninstall. Uninstall the app manually and re-run."
    answer="n"
    if [ "$ALLOW_UNINSTALL" -eq 1 ]; then
      answer="y"
    elif [ -t 0 ]; then
      read -r -p "    Uninstall $PKG from $SERIAL? [y/N] " answer
    fi
    case "$answer" in
      y|Y|yes|YES) ;;
      *) die "Not uninstalled. Uninstall $PKG manually (or re-run with --allow-uninstall) and try again." ;;
    esac
    UNINSTALL_OUT="$("$ADB" -s "$SERIAL" uninstall "$PKG" 2>&1 || true)"
    if printf '%s' "$UNINSTALL_OUT" | grep -q "DELETE_FAILED_APP_PINNED"; then
      die "Uninstall blocked: the app is pinned (screen pinning / kiosk / lock task mode).
       Unpin the app on the device, then run the script again."
    fi
    printf '%s' "$UNINSTALL_OUT" | grep -q "Success" || die "Uninstall failed: $UNINSTALL_OUT"
    ok "Uninstalled old version"
    INSTALL_OUT="$(do_install)"
  fi
  printf '%s' "$INSTALL_OUT" | grep -q "Success" || die "Install failed:
$INSTALL_OUT"
  ok "Installed"

  if [ -n "$PKG" ]; then
    info "Version: $("$ADB" -s "$SERIAL" shell dumpsys package "$PKG" | grep -m1 'versionName=' | sed 's/^ *//' | tr -d '\r')"
    GRANTED="$("$ADB" -s "$SERIAL" shell dumpsys package "$PKG" | grep -E '^ +[A-Za-z0-9_.]+: granted=true' | sed 's/^ *//; s/,.*//' | tr -d '\r' | sort -u || true)"
    if [ -n "$GRANTED" ]; then
      info "Granted permissions:"
      printf '%s\n' "$GRANTED" | sed 's/^/      /'
    fi
  fi
fi

printf '\n%sDone.%s Signed APK: %s\n' "$C_GREEN" "$C_RESET" "$OUT"
