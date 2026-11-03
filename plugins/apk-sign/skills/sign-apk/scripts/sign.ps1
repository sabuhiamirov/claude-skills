<#
.SYNOPSIS
  Sign or re-sign an Android APK with any keystore (Windows; also runs in PowerShell 7 on macOS/Linux).

.DESCRIPTION
  Steps: zipalign -> apksigner sign -> apksigner verify -> (optional) adb install.
  The original APK is never modified; a new "<name>-signed.apk" is written next to it.

  Passwords are never accepted as command-line arguments. They are read, in order, from:
    1. the APKSIGN_KS_PASS / APKSIGN_KEY_PASS environment variables
    2. a file given with -PassFile (first line = password)
    3. an interactive prompt (hidden input)

.EXAMPLE
  .\sign.ps1 -Apk app.apk -Keystore release.jks
.EXAMPLE
  .\sign.ps1 -Apk app.apk -Key key.pk8 -Cert key.x509.pem -Install
.EXAMPLE
  .\sign.ps1 app.apk release.jks
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)] [string] $Apk,
  [Parameter(Position = 1)] [string] $Keystore,
  [string] $Key,
  [string] $Cert,
  [string] $Alias,
  [string] $PassFile,
  [string] $Out,
  [switch] $Install,
  [string] $Serial,
  [switch] $AllowUninstall,
  [switch] $Version
)

$ScriptVersion = "1.0.0"
# Native tools write to stderr; keep going and check exit codes explicitly instead.
$ErrorActionPreference = "Continue"

# ---------------------------------------------------------------- output helpers

function Step([string] $m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor White }
function Info([string] $m) { Write-Host "    $m" }
function Ok([string] $m)   { Write-Host "    OK  $m" -ForegroundColor Green }
function Warn([string] $m) { Write-Host "    !   $m" -ForegroundColor Yellow }
function Fail([string] $m) {
  Write-Host ""
  Write-Host "ERROR: $m" -ForegroundColor Red
  Clear-Secrets
  exit 1
}
function Clear-Secrets {
  Remove-Item Env:APKSIGN_KS_PASS -ErrorAction SilentlyContinue
  Remove-Item Env:APKSIGN_KEY_PASS -ErrorAction SilentlyContinue
}

function Show-Usage {
  @"
Usage:
  sign.ps1 -Apk <app.apk> -Keystore <keystore.jks|.keystore|.p12> [options]
  sign.ps1 -Apk <app.apk> -Key <key.pk8> -Cert <key.x509.pem> [options]
  sign.ps1 <app.apk> <keystore>            (short form)

Required:
  -Apk <file>          APK to sign (signed or unsigned)
  -Keystore <file>     Java keystore (.jks / .keystore / .p12 / .pfx).
                       A .pk8 file is accepted too (same as -Key).
  -Key <file>          PKCS#8 private key (.pk8), used together with -Cert
  -Cert <file>         X.509 certificate (.x509.pem / .pem). If omitted with -Key,
                       <name>.x509.pem next to the .pk8 is used.

Options:
  -Alias <name>        Key alias inside the keystore (auto-detected if omitted)
  -PassFile <file>     Read the keystore password from the first line of a file
  -Out <file>          Output APK (default: <apk-name>-signed.apk)
  -Install             Install the signed APK on a connected device with adb
  -Serial <id>         Device serial for -Install (asked if several devices)
  -AllowUninstall      If the installed app has a different signature, uninstall it
                       without asking. WARNING: this deletes the app's data.
  -Version             Show the version

Environment:
  ANDROID_HOME / ANDROID_SDK_ROOT   Android SDK location (auto-detected otherwise)
  APKSIGN_KS_PASS                   Keystore password (non-interactive use)
  APKSIGN_KEY_PASS                  Key password, if different from the keystore password
"@ | Write-Host
}

if ($Version) { Write-Host "sign.ps1 $ScriptVersion"; exit 0 }

$OnWindows = ($env:OS -eq "Windows_NT")
$Exe = ""; $Bat = ""
if ($OnWindows) { $Exe = ".exe"; $Bat = ".bat" }
$Interactive = -not [Console]::IsInputRedirected

function Read-Secret([string] $prompt) {
  $secure = Read-Host -Prompt "    $prompt" -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Full-Path([string] $p) {
  return [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $p))
}

# Runs a native command, returns @{ Code; Text } with stdout+stderr as one string.
function Run([string] $exe, [string[]] $arguments) {
  $output = & $exe @arguments 2>&1 | ForEach-Object { "$_" }
  return @{ Code = $LASTEXITCODE; Text = ($output -join "`n") }
}

# ---------------------------------------------------------------- arguments

if (-not $Apk) { Show-Usage; Fail "No APK given." }
if (-not (Test-Path -LiteralPath $Apk -PathType Leaf)) { Fail "APK not found: $Apk" }
$Apk = Full-Path $Apk

# A .pk8 passed as -Keystore means key + certificate mode.
if ($Keystore -and ([IO.Path]::GetExtension($Keystore).ToLower() -eq ".pk8")) {
  $Key = $Keystore; $Keystore = ""
}

if ($Key) {
  $Mode = "pk8"
  if (-not (Test-Path -LiteralPath $Key -PathType Leaf)) { Fail "Private key not found: $Key" }
  $Key = Full-Path $Key
  if (-not $Cert) {
    $base = Join-Path ([IO.Path]::GetDirectoryName($Key)) ([IO.Path]::GetFileNameWithoutExtension($Key))
    foreach ($c in @("$base.x509.pem", "$base.pem", "$base.crt")) {
      if (Test-Path -LiteralPath $c -PathType Leaf) { $Cert = $c; break }
    }
    if (-not $Cert) { Fail "No certificate found next to $Key. Pass it with -Cert <file.x509.pem>." }
  }
  if (-not (Test-Path -LiteralPath $Cert -PathType Leaf)) { Fail "Certificate not found: $Cert" }
  $Cert = Full-Path $Cert
} elseif ($Keystore) {
  $Mode = "keystore"
  if (-not (Test-Path -LiteralPath $Keystore -PathType Leaf)) { Fail "Keystore not found: $Keystore" }
  $Keystore = Full-Path $Keystore
} else {
  Show-Usage; Fail "No keystore given. Use -Keystore <file> or -Key <file.pk8> -Cert <file.pem>."
}

if (-not $Out) {
  $Out = Join-Path ([IO.Path]::GetDirectoryName($Apk)) (([IO.Path]::GetFileNameWithoutExtension($Apk)) + "-signed.apk")
}
$Out = Full-Path $Out
if ($Out -eq $Apk) { Fail "Output must differ from the input APK." }
if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($Out)) -PathType Container)) {
  Fail "Output folder does not exist: $([IO.Path]::GetDirectoryName($Out))"
}

# ---------------------------------------------------------------- tools

Step "Looking for tools"

$sdkCandidates = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)
if ($env:LOCALAPPDATA) { $sdkCandidates += (Join-Path $env:LOCALAPPDATA "Android\Sdk") }
if ($env:HOME) {
  $sdkCandidates += @("$env:HOME/Library/Android/sdk", "$env:HOME/Android/Sdk", "$env:HOME/Android/sdk")
}
$Sdk = $null
foreach ($c in $sdkCandidates) {
  if ($c -and (Test-Path -LiteralPath (Join-Path $c "build-tools") -PathType Container)) { $Sdk = $c; break }
}
if (-not $Sdk) {
  Fail ("Android SDK not found.`n       Install Android Studio (or the command-line tools + build-tools) and/or set ANDROID_HOME.`n" +
        "       Typical location on Windows: %LOCALAPPDATA%\Android\Sdk")
}
Info "Android SDK:  $Sdk"

# Highest stable build-tools version (e.g. 36.0.0); release candidates only as a fallback.
$btDirs = Get-ChildItem -LiteralPath (Join-Path $Sdk "build-tools") -Directory
$stable = $btDirs | Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } | Select-Object -Last 1
if (-not $stable) { $stable = $btDirs | Where-Object { $_.Name -match '^\d' } | Sort-Object Name | Select-Object -Last 1 }
if (-not $stable) { Fail "No build-tools installed in $Sdk\build-tools. Install one from Android Studio > SDK Manager > SDK Tools." }
$Bt = $stable.FullName
$Zipalign = Join-Path $Bt "zipalign$Exe"
$Apksigner = Join-Path $Bt "apksigner$Bat"
if (-not (Test-Path -LiteralPath $Zipalign)) { Fail "zipalign not found in $Bt" }
if (-not (Test-Path -LiteralPath $Apksigner)) { Fail "apksigner not found in $Bt" }
Info "Build-tools:  $Bt"

# apksigner and keytool need Java. Fall back to the JDK bundled with Android Studio.
if (-not (Get-Command java -ErrorAction SilentlyContinue) -and -not $env:JAVA_HOME) {
  $jbrCandidates = @()
  if ($env:ProgramFiles) { $jbrCandidates += (Join-Path $env:ProgramFiles "Android\Android Studio\jbr") }
  if ($env:LOCALAPPDATA) { $jbrCandidates += (Join-Path $env:LOCALAPPDATA "Programs\Android Studio\jbr") }
  $jbrCandidates += "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  foreach ($j in $jbrCandidates) {
    if (Test-Path -LiteralPath (Join-Path $j "bin/java$Exe")) { $env:JAVA_HOME = $j; break }
  }
}
if ($env:JAVA_HOME -and (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME "bin/java$Exe"))) {
  $env:PATH = (Join-Path $env:JAVA_HOME "bin") + [IO.Path]::PathSeparator + $env:PATH
}
if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
  Fail "Java not found. Install a JDK (17+) or Android Studio, or set JAVA_HOME."
}
$javaVersion = (Run "java" @("-version")).Text.Split("`n")[0]
Info "Java:         $javaVersion"

# ---------------------------------------------------------------- passwords + alias

if ($Mode -eq "keystore") {
  $keytool = Get-Command keytool -ErrorAction SilentlyContinue
  if (-not $keytool) { Fail "keytool not found (it ships with the JDK)." }

  if (-not $env:APKSIGN_KS_PASS) {
    if ($PassFile) {
      if (-not (Test-Path -LiteralPath $PassFile -PathType Leaf)) { Fail "Password file not found: $PassFile" }
      $env:APKSIGN_KS_PASS = (Get-Content -LiteralPath $PassFile -TotalCount 1)
    } elseif ($Interactive) {
      $env:APKSIGN_KS_PASS = Read-Secret "Keystore password"
    } else {
      Fail ("No keystore password available and no terminal to ask for it.`n" +
            "       Run the script in a terminal, or set APKSIGN_KS_PASS, or use -PassFile <file>.")
    }
  }
  if (-not $env:APKSIGN_KEY_PASS) {
    if (-not $PassFile -and $Interactive) {
      $kp = Read-Secret "Key password (press Enter if same as keystore password)"
      if ($kp) { $env:APKSIGN_KEY_PASS = $kp }
    }
    if (-not $env:APKSIGN_KEY_PASS) { $env:APKSIGN_KEY_PASS = $env:APKSIGN_KS_PASS }
  }

  Step "Reading keystore"
  $kt = Run $keytool.Source @("-J-Duser.language=en", "-list", "-keystore", $Keystore, "-storepass:env", "APKSIGN_KS_PASS")
  if ($kt.Code -ne 0) {
    if ($kt.Text -match "password was incorrect|keystore was tampered") { Fail "Wrong keystore password." }
    Fail "Could not read the keystore:`n$($kt.Text)"
  }

  # Lines look like: "alias-name, Sep 22, 2020, PrivateKeyEntry,"
  $aliases = @($kt.Text.Split("`n") | Where-Object { $_ -match "PrivateKeyEntry" } | ForEach-Object { ($_ -split ",")[0].Trim() })
  if ($aliases.Count -eq 0) { Fail "The keystore contains no private key entry." }

  if ($Alias) {
    if ($aliases -notcontains $Alias) { Fail "Alias '$Alias' not found. Available: $($aliases -join ', ')" }
  } elseif ($aliases.Count -eq 1) {
    $Alias = $aliases[0]
  } elseif ($Interactive) {
    Info "The keystore has $($aliases.Count) keys:"
    for ($i = 0; $i -lt $aliases.Count; $i++) { Info "  $($i + 1)) $($aliases[$i])" }
    $n = Read-Host "    Choose a number"
    $idx = 0
    if (-not [int]::TryParse($n, [ref]$idx) -or $idx -lt 1 -or $idx -gt $aliases.Count) { Fail "Invalid choice." }
    $Alias = $aliases[$idx - 1]
  } else {
    Fail "The keystore has several keys; pass one with -Alias. Available: $($aliases -join ', ')"
  }
  Ok "Key alias: $Alias"
}

# ---------------------------------------------------------------- sign

$TmpAligned = Join-Path ([IO.Path]::GetDirectoryName($Out)) (([IO.Path]::GetFileNameWithoutExtension($Out)) + ".aligned.tmp.apk")

try {
  Step "1/3 zipalign (4-byte alignment, required before apksigner)"
  $r = Run $Zipalign @("-f", "-p", "4", $Apk, $TmpAligned)
  if ($r.Code -ne 0) { Fail "zipalign failed:`n$($r.Text)" }
  Ok "Aligned"

  Step "2/3 apksigner sign"
  if ($Mode -eq "keystore") {
    $signArgs = @("sign", "--ks", $Keystore, "--ks-key-alias", $Alias,
                  "--ks-pass", "env:APKSIGN_KS_PASS", "--key-pass", "env:APKSIGN_KEY_PASS",
                  "--v4-signing-enabled", "false", "--out", $Out, $TmpAligned)
  } else {
    $signArgs = @("sign", "--key", $Key, "--cert", $Cert,
                  "--v4-signing-enabled", "false", "--out", $Out, $TmpAligned)
  }
  $r = Run $Apksigner $signArgs
  if ($r.Code -ne 0) { Fail "apksigner sign failed (wrong key password?):`n$($r.Text)" }
  Ok "Signed: $Out"
} finally {
  Remove-Item -LiteralPath $TmpAligned -ErrorAction SilentlyContinue
  Clear-Secrets
}

Step "3/3 apksigner verify"
$r = Run $Apksigner @("verify", "--verbose", "--print-certs", $Out)
if ($r.Code -ne 0) { Fail "Verification failed:`n$($r.Text)" }
$r.Text.Split("`n") |
  Where-Object { $_ -match '^Verified using v[0-9.]+ scheme.*: true|^Number of signers|certificate DN|certificate SHA-256' } |
  ForEach-Object { Info $_ }
Ok "Signature is valid"

# ---------------------------------------------------------------- install (optional)

if ($Install) {
  Step "Installing on device"
  $Adb = Join-Path $Sdk "platform-tools/adb$Exe"
  if (-not (Test-Path -LiteralPath $Adb)) {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { $Adb = $cmd.Source } else { Fail "adb not found. Install 'Android SDK Platform-Tools' from the SDK Manager." }
  }

  if (-not $Serial) {
    $devices = @((Run $Adb @("devices")).Text.Split("`n") | Select-Object -Skip 1 |
                 Where-Object { $_ -match '^\S+\s+device\s*$' } | ForEach-Object { ($_ -split '\s+')[0] })
    if ($devices.Count -eq 0) {
      Fail "No device connected (check the USB cable and 'adb devices'; unauthorized devices must accept the USB debugging prompt)."
    } elseif ($devices.Count -eq 1) {
      $Serial = $devices[0]
    } elseif ($Interactive) {
      Info "Several devices are connected:"
      for ($i = 0; $i -lt $devices.Count; $i++) {
        $model = (Run $Adb @("-s", $devices[$i], "shell", "getprop", "ro.product.model")).Text.Trim()
        Info "  $($i + 1)) $($devices[$i])  $model"
      }
      $n = Read-Host "    Choose a number"
      $idx = 0
      if (-not [int]::TryParse($n, [ref]$idx) -or $idx -lt 1 -or $idx -gt $devices.Count) { Fail "Invalid choice." }
      $Serial = $devices[$idx - 1]
    } else {
      Fail "Several devices are connected; choose one with -Serial. Devices: $($devices -join ', ')"
    }
  }
  $model = (Run $Adb @("-s", $Serial, "shell", "getprop", "ro.product.model")).Text.Trim()
  Info "Device: $Serial ($model)"

  $pkg = ""
  $aapt2 = Join-Path $Bt "aapt2$Exe"
  if (Test-Path -LiteralPath $aapt2) {
    $p = Run $aapt2 @("dump", "packagename", $Out)
    if ($p.Code -eq 0) { $pkg = $p.Text.Split("`n")[0].Trim() }
  }
  if ($pkg) { Info "Package: $pkg" }

  $inst = Run $Adb @("-s", $Serial, "install", "-r", "--no-incremental", $Out)
  if ($inst.Text -match "INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
    Warn "The app already installed on the device is signed with a different key."
    Warn "It must be uninstalled first. This DELETES the app's data on the device."
    if (-not $pkg) { Fail "Could not read the package name to uninstall. Uninstall the app manually and re-run." }
    $answer = "n"
    if ($AllowUninstall) { $answer = "y" }
    elseif ($Interactive) { $answer = Read-Host "    Uninstall $pkg from ${Serial}? [y/N]" }
    if ($answer -notmatch '^(y|yes)$') {
      Fail "Not uninstalled. Uninstall $pkg manually (or re-run with -AllowUninstall) and try again."
    }
    $un = Run $Adb @("-s", $Serial, "uninstall", $pkg)
    if ($un.Text -match "DELETE_FAILED_APP_PINNED") {
      Fail ("Uninstall blocked: the app is pinned (screen pinning / kiosk / lock task mode).`n" +
            "       Unpin the app on the device, then run the script again.")
    }
    if ($un.Text -notmatch "Success") { Fail "Uninstall failed: $($un.Text)" }
    Ok "Uninstalled old version"
    $inst = Run $Adb @("-s", $Serial, "install", "-r", "--no-incremental", $Out)
  }
  if ($inst.Text -notmatch "Success") { Fail "Install failed:`n$($inst.Text)" }
  Ok "Installed"

  if ($pkg) {
    $dump = (Run $Adb @("-s", $Serial, "shell", "dumpsys", "package", $pkg)).Text.Split("`n")
    $ver = $dump | Where-Object { $_ -match 'versionName=' } | Select-Object -First 1
    if ($ver) { Info "Version: $($ver.Trim())" }
    $granted = $dump | Where-Object { $_ -match '^\s+[A-Za-z0-9_.]+: granted=true' } |
               ForEach-Object { ($_.Trim() -split ",")[0] } | Sort-Object -Unique
    if ($granted) {
      Info "Granted permissions:"
      $granted | ForEach-Object { Info "  $_" }
    }
  }
}

Write-Host ""
Write-Host "Done. Signed APK: $Out" -ForegroundColor Green
