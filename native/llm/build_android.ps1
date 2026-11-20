# Builds the on-device model library (llama.cpp + mobileros_llm.c) for Android and copies it into
# android/app/src/main/jniLibs:
#   arm64-v8a: libmobileros_llm.so (any arm64 phone) and libmobileros_llm_dotprod.so (dot product + fp16,
#              most phones since 2019; the app loads it when the CPU reports asimddp)
#   x86_64:    libmobileros_llm.so (emulator)
# 32-bit ARM is left out: those phones lack the memory for the model. Needs the Android SDK with NDK
# 28.2.13676358 and CMake 3.22.1, and git.
#   powershell -ExecutionPolicy Bypass -File native\llm\build_android.ps1
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$repo = Resolve-Path "$here\..\.."
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "$env:LOCALAPPDATA\Android\Sdk" }
$ndk = "$sdk\ndk\28.2.13676358"
$cmakeBin = "$sdk\cmake\3.22.1\bin"
$api = 24   # Flutter's default minSdk
$llamaTag = 'v0.9.0'

$src = "$here\.build\llama.cpp"
if (-not (Test-Path $src)) {
  git clone --quiet --depth 1 --branch $llamaTag https://github.com/ggml-org/llama.cpp.git $src
}

$builds = @(
  @{ abi = 'arm64-v8a'; arch = ''; name = 'mobileros_llm' },
  @{ abi = 'arm64-v8a'; arch = 'armv8.2-a+dotprod+fp16'; name = 'mobileros_llm_dotprod' },
  @{ abi = 'x86_64'; arch = ''; name = 'mobileros_llm' }
)
foreach ($b in $builds) {
  Write-Host "== $($b.abi) $($b.name)"
  $build = "$here\.build\android-$($b.abi)-$($b.name)"
  & "$cmakeBin\cmake.exe" -S $here -B $build -G Ninja "-DCMAKE_MAKE_PROGRAM=$cmakeBin\ninja.exe" `
    "-DCMAKE_TOOLCHAIN_FILE=$ndk\build\cmake\android.toolchain.cmake" "-DANDROID_ABI=$($b.abi)" `
    "-DANDROID_PLATFORM=android-$api" -DANDROID_STL=c++_static -DCMAKE_BUILD_TYPE=Release `
    "-DML_ARM_ARCH=$($b.arch)" "-DML_OUTPUT_NAME=$($b.name)" | Out-Null
  if ($LASTEXITCODE) { throw "configure failed for $($b.abi)" }
  & "$cmakeBin\cmake.exe" --build $build --target mobileros_llm | Out-Null
  if ($LASTEXITCODE) { throw "build failed for $($b.abi)" }
  $out = "$repo\android\app\src\main\jniLibs\$($b.abi)"
  New-Item -ItemType Directory -Force $out | Out-Null
  Copy-Item "$build\lib$($b.name).so" $out -Force
  Write-Host "   $out\lib$($b.name).so ($((Get-Item "$out\lib$($b.name).so").Length) bytes)"
}
