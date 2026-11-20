param(
  [string]$SdkRoot = "$env:LOCALAPPDATA\Android\Sdk",
  [string]$OpenSsl = "$env:ProgramFiles\Git\usr\bin\openssl.exe"
)
# Creates only the repo's isolated QA AVD/certificate. Never opens an emulator window.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$qaRoot = Join-Path $repoRoot 'build/android-emulator'
$avdRoot = Join-Path $qaRoot 'avd'
$avdPath = Join-Path $avdRoot 'MobileRosQA.avd'
$image = Join-Path $SdkRoot 'system-images/android-34/google_apis_playstore/x86_64'
$adb = Join-Path $SdkRoot 'platform-tools/adb.exe'
$emulator = Join-Path $SdkRoot 'emulator/emulator.exe'
foreach ($required in @($adb, $emulator, $OpenSsl, (Join-Path $image 'system.img'))) {
  if (!(Test-Path -LiteralPath $required)) { throw "Missing $required. Install Android 34 Google Play x86_64, emulator/platform tools and Git OpenSSL first." }
}
New-Item -ItemType Directory -Force -Path $avdPath | Out-Null
$env:ANDROID_AVD_HOME = $avdRoot
& $adb start-server
$alreadyRunning = (& $adb devices) -match '^emulator-5580\s+device$'
if (!$alreadyRunning) {
  [IO.File]::WriteAllText((Join-Path $avdRoot 'MobileRosQA.ini'), "avd.ini.encoding=UTF-8`npath=$avdPath`ntarget=android-34`n")
  [IO.File]::WriteAllText((Join-Path $avdPath 'config.ini'), @"
avd.ini.encoding=UTF-8
AvdId=MobileRosQA
avd.ini.displayname=Mobile ROS QA
abi.type=x86_64
hw.cpu.arch=x86_64
hw.cpu.ncore=2
hw.ramSize=2048
hw.lcd.width=432
hw.lcd.height=960
hw.lcd.density=180
hw.keyboard=yes
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader_indirect
disk.dataPartition.size=4G
image.sysdir.1=$image\
tag.id=google_apis_playstore
tag.display=Google Play
PlayStore.enabled=true
"@)
  Start-Process -FilePath $emulator -ArgumentList @('-avd','MobileRosQA','-no-window','-no-audio',
    '-no-boot-anim','-no-snapshot','-gpu','swiftshader_indirect','-port','5580') -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $qaRoot 'emulator.out.log') -RedirectStandardError (Join-Path $qaRoot 'emulator.err.log') | Out-Null
}
$booted = $false
for ($attempt = 0; $attempt -lt 180; $attempt++) {
  # Before the emulator registers with adb, Windows PowerShell treats its expected stderr as a
  # terminating error under Stop. Keep polling instead of aborting a normal cold boot.
  try { $bootState = & $adb -s emulator-5580 shell getprop sys.boot_completed 2>$null }
  catch { $bootState = '' }
  if ($bootState -eq '1') { $booted = $true; break }
  Start-Sleep -Seconds 1
}
if (!$booted) { throw 'QA emulator did not boot; inspect build/android-emulator/emulator.*.log.' }
foreach ($setting in @('window_animation_scale','transition_animation_scale','animator_duration_scale')) {
  & $adb -s emulator-5580 shell settings put global $setting 0
}
$certificate = Join-Path $qaRoot 'qa-cert.pem'
$needCertificate = !(Test-Path -LiteralPath $certificate)
if (!$needCertificate) {
  & $OpenSsl x509 -in $certificate -checkend 7200 -noout *> $null
  $needCertificate = $LASTEXITCODE -ne 0
}
if ($needCertificate) {
  $ErrorActionPreference = 'Continue' # OpenSSL's normal key-generation progress is on stderr.
  try {
    & $OpenSsl req -x509 -newkey rsa:2048 -nodes -keyout (Join-Path $qaRoot 'qa-key.pem') `
      -out $certificate -days 2 -subj '/CN=Android QA only' `
      -addext 'subjectAltName=IP:10.0.2.2,IP:127.0.0.1,DNS:localhost' 2> (Join-Path $qaRoot 'certificate-generation.log')
    $certificateExit = $LASTEXITCODE
  } finally { $ErrorActionPreference = 'Stop' }
  if ($certificateExit -ne 0) { throw 'Could not create the local-only QA TLS certificate.' }
}
Write-Output 'Hidden QA emulator ready: emulator-5580. No real account or production key is used.'
