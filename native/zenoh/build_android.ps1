# Builds libmobileros_zenoh.so (zenoh-pico 1.8.0 + mobileros_zenoh.c) for the Android ABIs the app ships
# and copies it into android/app/src/main/jniLibs. Needs the Android SDK with NDK 28.2.13676358 and
# CMake 3.22.1, and git. zenoh-pico has no Android target of its own; Android builds it as a POSIX
# system (POSIX_COMPATIBLE), which uses its Unix/Linux platform code.
#   powershell -ExecutionPolicy Bypass -File native\zenoh\build_android.ps1 [-Abis arm64-v8a,x86_64]
param([string[]]$Abis = @('arm64-v8a', 'armeabi-v7a', 'x86_64'))
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$repo = Resolve-Path "$here\..\.."
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "$env:LOCALAPPDATA\Android\Sdk" }
$ndk = "$sdk\ndk\28.2.13676358"
$cmakeBin = "$sdk\cmake\3.22.1\bin"
$api = 24   # Flutter's default minSdk
$picoTag = '1.8.0'   # matches zenoh 1.8.0 in ROS 2 Jazzy's rmw_zenoh (zenoh_cpp_vendor 0.2.11)

$src = "$here\.build\zenoh-pico"
if (-not (Test-Path $src)) {
  git clone --quiet --depth 1 --branch $picoTag https://github.com/eclipse-zenoh/zenoh-pico.git $src
}

foreach ($abi in $Abis) {
  Write-Host "== $abi"
  $build = "$here\.build\android-$abi"
  & "$cmakeBin\cmake.exe" -S $here -B $build -G Ninja "-DCMAKE_MAKE_PROGRAM=$cmakeBin\ninja.exe" `
    "-DCMAKE_TOOLCHAIN_FILE=$ndk\build\cmake\android.toolchain.cmake" "-DANDROID_ABI=$abi" `
    "-DANDROID_PLATFORM=android-$api" -DCMAKE_BUILD_TYPE=Release -DPOSIX_COMPATIBLE=ON | Out-Null
  if ($LASTEXITCODE) { throw "configure failed for $abi" }
  & "$cmakeBin\cmake.exe" --build $build --target mobileros_zenoh | Out-Null
  if ($LASTEXITCODE) { throw "build failed for $abi" }
  $out = "$repo\android\app\src\main\jniLibs\$abi"
  New-Item -ItemType Directory -Force $out | Out-Null
  Copy-Item "$build\libmobileros_zenoh.so" $out -Force
  Write-Host "   $out\libmobileros_zenoh.so ($((Get-Item "$out\libmobileros_zenoh.so").Length) bytes)"
}
