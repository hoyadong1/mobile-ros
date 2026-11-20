[CmdletBinding()]
param(
    [string]$SdkPath,
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$FlutterVersion = '3.41.8',
    [switch]$CheckOnly,
    [switch]$SetupOnly
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$propertiesPath = Join-Path $projectRoot 'android\local.properties'
$sdkPointerPath = Join-Path $projectRoot '.dart_tool\flutter-sdk-path.txt'
$toolRoot = Join-Path $projectRoot '.tools'
$candidates = [Collections.Generic.List[string]]::new()

if ($SdkPath) { $candidates.Add($SdkPath) }
if (Test-Path -LiteralPath $sdkPointerPath) {
    $candidates.Add((Get-Content -LiteralPath $sdkPointerPath -Raw).Trim())
}
if ($env:FLUTTER_ROOT) { $candidates.Add($env:FLUTTER_ROOT) }
$flutterCommand = Get-Command flutter.bat -ErrorAction SilentlyContinue
if ($flutterCommand) { $candidates.Add((Split-Path (Split-Path $flutterCommand.Source))) }
if (Test-Path -LiteralPath $propertiesPath) {
    foreach ($line in Get-Content -LiteralPath $propertiesPath) {
        if ($line -match '^flutter\.sdk=(.+)$') {
            $candidates.Add($Matches[1].Replace('\\', '\').Replace('\:', ':'))
        }
    }
}
$candidates.Add('C:\flutter_windows_3.41.8-stable\flutter')
if ($env:USERPROFILE) {
    foreach ($relative in @('develop\flutter', 'development\flutter', 'flutter', 'fvm\default')) {
        $candidates.Add((Join-Path $env:USERPROFILE $relative))
    }
}

$resolvedSdk = $null
$checks = @()
foreach ($candidate in ($candidates | Select-Object -Unique)) {
    try {
        $candidate = [IO.Path]::GetFullPath($candidate)
        $executable = Join-Path $candidate 'bin\flutter.bat'
        $item = Get-Item -LiteralPath $executable -ErrorAction Stop
        if ($item.PSIsContainer) { throw 'flutter.bat is not a file.' }
        $checks += [pscustomobject]@{ Path = $candidate; Status = 'Found' }
        if (-not $resolvedSdk) { $resolvedSdk = $candidate }
    } catch {
        $checks += [pscustomobject]@{ Path = $candidate; Status = $_.CategoryInfo.Category.ToString() }
    }
}

Write-Host ('Running as: ' + [Security.Principal.WindowsIdentity]::GetCurrent().Name)
$checks | Format-Table -AutoSize | Out-Host
if ($CheckOnly) {
    [pscustomobject]@{ SdkAvailable = [bool]$resolvedSdk; SdkPath = $resolvedSdk; Project = $projectRoot }
    return
}
if ($SdkPath -and -not (Test-Path -LiteralPath (Join-Path $SdkPath 'bin\flutter.bat'))) {
    throw 'The supplied -SdkPath is not an accessible Flutter SDK root. No installation was changed.'
}

if (-not $resolvedSdk) {
    # Official Flutter archive only. No firewall, ACL or sandbox changes are made.
    Write-Host "No accessible SDK found. Downloading Flutter $FlutterVersion into this project."
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        $metadata = Invoke-RestMethod -Uri 'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json' -TimeoutSec 30
    } catch {
        throw ('Cannot reach the official Flutter archive. Run this script in your normal Windows PowerShell with network access. Original error: ' + $_.Exception.Message)
    }
    $release = $metadata.releases | Where-Object {
        $_.version -eq $FlutterVersion -and $_.channel -eq 'stable' -and
        (-not $_.PSObject.Properties['dart_sdk_arch'] -or $_.dart_sdk_arch -eq 'x64')
    } | Select-Object -First 1
    if (-not $release -or $release.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw "Flutter $FlutterVersion with a SHA-256 checksum was not found in the official release index."
    }
    if ($release.archive -notmatch '^stable/windows/[^/\\]+\.zip$') {
        throw 'Unexpected archive path in release metadata.'
    }
    New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
    $archivePath = Join-Path $toolRoot "flutter_windows_$FlutterVersion.zip"
    $archiveValid = (Test-Path -LiteralPath $archivePath) -and
        ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -eq $release.sha256)
    if (-not $archiveValid) {
        $downloadUrl = 'https://storage.googleapis.com/flutter_infra_release/releases/' + $release.archive
        Write-Host "Downloading $downloadUrl (the SDK archive is large)..."
        $savedProgress = $ProgressPreference
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $archivePath -TimeoutSec 7200
        } finally { $ProgressPreference = $savedProgress }
    }
    if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ne $release.sha256) {
        throw 'SDK checksum mismatch. The archive will not be extracted.'
    }
    # A fresh extraction directory preserves existing SDKs and interrupted attempts.
    $installRoot = Join-Path $toolRoot ('flutter-' + $FlutterVersion + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $installRoot | Out-Null
    Write-Host "Extracting to $installRoot"
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($tar) {
        & $tar.Source -xf $archivePath -C $installRoot
        if ($LASTEXITCODE -ne 0) { throw 'SDK extraction failed.' }
    } else {
        Expand-Archive -LiteralPath $archivePath -DestinationPath $installRoot
    }
    $resolvedSdk = Join-Path $installRoot 'flutter'
}

$flutterBat = Join-Path $resolvedSdk 'bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutterBat)) { throw 'The selected SDK does not contain bin\flutter.bat.' }
$logRoot = Join-Path $projectRoot ('.dart_tool\verification\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
$results = [Collections.Generic.List[object]]::new()

function Invoke-FlutterStep {
    param([string]$Name, [string[]]$Arguments)
    Write-Host "`n> flutter $($Arguments -join ' ')"
    $savedErrors = $ErrorActionPreference
    try {
        # Native stderr is logged; success is determined by the actual exit code.
        $ErrorActionPreference = 'Continue'
        & $flutterBat @Arguments 2>&1 | Tee-Object -FilePath (Join-Path $logRoot ($Name + '.log')) | Out-Host
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedErrors }
    $results.Add([pscustomobject]@{ Step = $Name; ExitCode = $code })
    return $code
}

$previousPath = $env:PATH
Push-Location $projectRoot
try {
    # PATH is changed only for this process and restored on completion.
    $env:PATH = (Join-Path $resolvedSdk 'bin') + ';' + $previousPath
    if ((Invoke-FlutterStep -Name 'version' -Arguments @('--version')) -ne 0) {
        throw "Flutter could not start. See $logRoot\version.log"
    }
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($sdkPointerPath, $resolvedSdk, $utf8)
    $propertyLines = @()
    if (Test-Path -LiteralPath $propertiesPath) {
        Copy-Item -LiteralPath $propertiesPath -Destination (Join-Path $logRoot 'local.properties.before')
        $propertyLines = @(Get-Content -LiteralPath $propertiesPath | Where-Object { $_ -notmatch '^flutter\.sdk=' })
    }
    $propertyLines += 'flutter.sdk=' + $resolvedSdk.Replace('\', '/')
    [IO.File]::WriteAllLines($propertiesPath, [string[]]$propertyLines, $utf8)
    if ((Invoke-FlutterStep -Name 'pub-get' -Arguments @('pub', 'get')) -ne 0) {
        throw 'Dependency resolution failed. See pub-get.log.'
    }
    if (-not $SetupOnly) {
        # Run every independent check even if analysis or a test fails.
        $null = Invoke-FlutterStep -Name 'analyze' -Arguments @('analyze')
        $null = Invoke-FlutterStep -Name 'test' -Arguments @('test')
        $null = Invoke-FlutterStep -Name 'build-apk' -Arguments @('build', 'apk', '--debug')
    }
} finally {
    [pscustomobject]@{ SdkPath = $resolvedSdk; Results = @($results.ToArray()) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $logRoot 'summary.json') -Encoding UTF8
    $env:PATH = $previousPath
    Pop-Location
    Write-Host "`nLogs: $logRoot"
}
$results | Format-Table -AutoSize | Out-Host
if (@($results | Where-Object { $_.ExitCode -ne 0 }).Count -gt 0) {
    throw 'One or more checks failed. Open the corresponding log files.'
}
if (-not $SetupOnly) {
    Write-Host ('APK: ' + (Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-debug.apk'))
}
