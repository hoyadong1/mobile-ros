# Builds libmobileros_dds.so (Cyclone DDS + mobileros_dds.c) for the Android ABIs the app ships and copies
# it into android/app/src/main/jniLibs. Needs the Android SDK with NDK 28.2.13676358 and CMake 3.22.1, and git.
#   powershell -ExecutionPolicy Bypass -File native\dds\build_android.ps1 [-Abis arm64-v8a,x86_64]
param([string[]]$Abis = @('arm64-v8a', 'armeabi-v7a', 'x86_64'))
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$repo = Resolve-Path "$here\..\.."
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "$env:LOCALAPPDATA\Android\Sdk" }
$ndk = "$sdk\ndk\28.2.13676358"
$cmakeBin = "$sdk\cmake\3.22.1\bin"
$env:PATH = "$cmakeBin;$env:PATH"
$api = 24   # Flutter's default minSdk
$cycloneCommit = '5041f3560c088c99e5088b2b8520b69169621196'   # releases/0.10.x

$work = "$here\.build"
$src = "$work\cyclonedds"
if (-not (Test-Path "$src\.git")) {
  git clone --quiet --branch releases/0.10.x https://github.com/eclipse-cyclonedds/cyclonedds.git $src
}
Push-Location $src
git -c advice.detachedHead=false checkout --quiet --force $cycloneCommit
git apply --whitespace=nowarn "$here\cyclonedds-android.patch"
Pop-Location

$clangTriples = @{ 'arm64-v8a' = 'aarch64-linux-android'; 'armeabi-v7a' = 'armv7a-linux-androideabi'; 'x86_64' = 'x86_64-linux-android' }
foreach ($abi in $Abis) {
  Write-Host "== $abi"
  $build = "$work\build-$abi"
  $install = "$work\install-$abi"
  & "$cmakeBin\cmake.exe" -S $src -B $build -G Ninja "-DCMAKE_MAKE_PROGRAM=$cmakeBin\ninja.exe" `
    "-DCMAKE_TOOLCHAIN_FILE=$ndk\build\cmake\android.toolchain.cmake" "-DANDROID_ABI=$abi" "-DANDROID_PLATFORM=android-$api" `
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_IDLC=OFF -DBUILD_DDSPERF=OFF -DBUILD_EXAMPLES=OFF `
    -DBUILD_TESTING=OFF -DENABLE_SSL=OFF -DENABLE_SECURITY=OFF -DENABLE_SHM=OFF -DENABLE_LTO=OFF `
    "-DCMAKE_INSTALL_PREFIX=$install" | Out-Null
  if ($LASTEXITCODE) { throw "configure failed for $abi" }
  & "$cmakeBin\cmake.exe" --build $build --target install | Out-Null
  if ($LASTEXITCODE) { throw "build failed for $abi" }

  $cc = "$ndk\toolchains\llvm\prebuilt\windows-x86_64\bin\$($clangTriples[$abi])$api-clang.cmd"
  $out = "$repo\android\app\src\main\jniLibs\$abi"
  New-Item -ItemType Directory -Force $out | Out-Null
  # Only the mr_* functions are exported; 16 KB page alignment for Android 15+ devices.
  & $cc -O2 -fPIC -shared -fvisibility=hidden "-I$install\include" "$here\mobileros_dds.c" "$install\lib\libddsc.a" `
    '-Wl,--exclude-libs,ALL' '-Wl,-z,max-page-size=16384' '-Wl,--gc-sections' -s -o "$out\libmobileros_dds.so"
  if ($LASTEXITCODE) { throw "link failed for $abi" }
  Write-Host "   $out\libmobileros_dds.so ($((Get-Item "$out\libmobileros_dds.so").Length) bytes)"
}
