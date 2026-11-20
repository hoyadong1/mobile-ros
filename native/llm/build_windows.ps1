# Builds native/llm/prebuilt/windows-x64/mobileros_llm.dll (llama.cpp + mobileros_llm.c) with
# MSVC, so the on-device assistant model can run in `flutter test` and the Windows app on a PC.
# Needs Visual Studio Build Tools (C++), and the Android SDK's CMake 3.22.1 (it brings Ninja).
#   powershell -ExecutionPolicy Bypass -File native/llm/build_windows.ps1
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$sdk = "$env:LOCALAPPDATA\Android\Sdk"
$cmakeBin = "$sdk\cmake\3.22.1\bin"
$llamaTag = 'v0.9.0'
$src = "$here\.build\llama.cpp"

if (-not (Test-Path $src)) {
  git clone --quiet --depth 1 --branch $llamaTag https://github.com/ggml-org/llama.cpp.git $src
}
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vcvars = & $vswhere -latest -products * -find 'VC\Auxiliary\Build\vcvars64.bat' | Select-Object -First 1
if (-not $vcvars) { throw 'Visual Studio C++ build tools not found (vcvars64.bat)' }

$build = "$here\.build\windows-x64"
$cmake = "`"$cmakeBin\cmake.exe`""
cmd /c "`"$vcvars`" >nul && $cmake -S `"$here`" -B `"$build`" -G Ninja -DCMAKE_MAKE_PROGRAM=`"$cmakeBin\ninja.exe`" -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl >nul && $cmake --build `"$build`" --target mobileros_llm"
if ($LASTEXITCODE -ne 0) { throw "build failed ($LASTEXITCODE)" }

$out = "$here\prebuilt\windows-x64"
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item "$build\mobileros_llm.dll" $out -Force
Write-Host "Built $out\mobileros_llm.dll"
