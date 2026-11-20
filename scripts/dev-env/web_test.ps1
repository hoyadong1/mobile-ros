param(
  [Parameter(Mandatory = $true)][string]$FlutterRoot,
  [string[]]$Tests = @('test/web_startup_test.dart'),
  [string]$ChromeExecutable = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
)

# Flutter 3.50's Windows test handler turns a URL into a backslash path before checking
# the literal 'canvaskit/' prefix, returning 404 for the renderer. Run the tool from
# source with this one correction; restore the SDK file even if a test fails.
# Flutter test uses an isolated browser profile and headless mode (never pause-after-load).
$ErrorActionPreference = 'Stop'
$sdkRoot = (Resolve-Path -LiteralPath $FlutterRoot).Path
$toolSource = Join-Path $sdkRoot 'packages/flutter_tools/lib/src/test/flutter_web_platform.dart'
$originalSource = [IO.File]::ReadAllText($toolSource)
$broken = 'final String fullPath = _fileSystem.path.fromUri(request.url);'
$fixed = 'final String fullPath = request.url.path;'
$patchedSource = $originalSource.Replace($broken, $fixed)
$needsPatch = $patchedSource -ne $originalSource
$oldChrome = $env:CHROME_EXECUTABLE
$result = 1
try {
  if ($needsPatch) {
    [IO.File]::WriteAllText($toolSource, $patchedSource, [Text.UTF8Encoding]::new($false))
    Write-Output 'Applying temporary Windows CanvasKit URL-path workaround.'
  }
  $env:CHROME_EXECUTABLE = (Resolve-Path -LiteralPath $ChromeExecutable).Path
  $dart = Join-Path $sdkRoot 'bin/cache/dart-sdk/bin/dart.exe'
  $packages = Join-Path $sdkRoot 'packages/flutter_tools/.dart_tool/package_config.json'
  $tool = Join-Path $sdkRoot 'packages/flutter_tools/bin/flutter_tools.dart'
  & $dart "--packages=$packages" $tool test --no-pub --platform chrome --timeout 60s @Tests
  $result = $LASTEXITCODE
} finally {
  $env:CHROME_EXECUTABLE = $oldChrome
  if ($needsPatch) {
    if ([IO.File]::ReadAllText($toolSource) -ne $patchedSource) {
      throw 'Flutter tool source changed during testing; refusing to overwrite another edit.'
    }
    [IO.File]::WriteAllText($toolSource, $originalSource, [Text.UTF8Encoding]::new($false))
  }
}
exit $result
