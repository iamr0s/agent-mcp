param(
  [switch]$UniversalOnly
)
$ErrorActionPreference = 'Continue'

$RootDir = Split-Path -Parent $PSScriptRoot
$AppDir = Join-Path $RootDir 'apps\agent_mcp_app'
$FlutterBat = Join-Path $RootDir '.sdk\flutter\bin\flutter.bat'
if (-not (Test-Path $FlutterBat)) {
  $FlutterBat = 'flutter'
}
$ReleaseDir = Join-Path $RootDir 'release'
New-Item -ItemType Directory -Force -Path $ReleaseDir | Out-Null

if (-not $env:JAVA_HOME -or -not (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
  foreach ($cand in @(
    'C:\Program Files\Android\Android Studio1\jbr',
    'C:\Program Files\Android\Android Studio\jbr'
  )) {
    if (Test-Path (Join-Path $cand 'lib\jvm.cfg')) {
      $env:JAVA_HOME = $cand
      break
    }
  }
}

if (-not $env:ANDROID_HOME) {
  $defSdk = Join-Path $env:LOCALAPPDATA 'Android\sdk'
  if (Test-Path $defSdk) {
    $env:ANDROID_HOME = $defSdk
    $env:ANDROID_SDK_ROOT = $defSdk
  }
}

# Inherit active Windows system HTTP proxy into Gradle / Kotlin daemon JVMs automatically
try {
  $pHost = $null
  $pPort = $null
  $inet = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
  if ($inet -and $inet.ProxyEnable -eq 1 -and $inet.ProxyServer) {
    $rawProxy = "$($inet.ProxyServer)".Trim()
    if ($rawProxy -match '^(?:https?=)?([^:;]+):(\d+)') {
      $pHost = $Matches[1]
      $pPort = $Matches[2]
    }
  }
  if (-not $pHost) {
    foreach ($candPort in @(7890, 7897, 10809)) {
      $tcp = New-Object System.Net.Sockets.TcpClient
      try {
        $iar = $tcp.BeginConnect('127.0.0.1', $candPort, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(180) -and $tcp.Connected) {
          $pHost = '127.0.0.1'
          $pPort = "$candPort"
          break
        }
      } catch {} finally {
        $tcp.Close()
      }
    }
  }
  if ($pHost -and $pPort) {
    $env:GRADLE_OPTS = "-Dhttp.proxyHost=$pHost -Dhttp.proxyPort=$pPort -Dhttps.proxyHost=$pHost -Dhttps.proxyPort=$pPort"
    Write-Host "[Proxy] Configured Gradle JVM proxy $pHost`:$pPort"
  }
} catch {}

Push-Location $AppDir
try {
  if (Test-Path '.\android\gradlew.bat') {
    & '.\android\gradlew.bat' --stop | Out-Null
  }

  Write-Host '[1/2] Building Universal Android Release APK...'
  & $FlutterBat build apk --release
  if ($LASTEXITCODE -ne 0) { throw "Universal APK build failed ($LASTEXITCODE)" }

  $uniSrc = Join-Path $AppDir 'build\app\outputs\flutter-apk\app-release.apk'
  $uniDst = Join-Path $ReleaseDir 'AgentMCP-v2.4.2-android-universal.apk'
  Copy-Item -Force $uniSrc $uniDst

  if (-not $UniversalOnly) {
    Write-Host '[2/2] Building Slim arm64-v8a Release APK...'
    & $FlutterBat build apk --release --split-per-abi
    if ($LASTEXITCODE -ne 0) { throw "Split-ABI APK build failed ($LASTEXITCODE)" }

    $arm64Src = Join-Path $AppDir 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
    $arm64Dst = Join-Path $ReleaseDir 'AgentMCP-v2.4.2-android-arm64-v8a.apk'
    if (Test-Path $arm64Src) {
      Copy-Item -Force $arm64Src $arm64Dst
    }
  }

  Get-ChildItem $ReleaseDir -Filter 'AgentMCP-v2.4.2-android-*.apk' | ForEach-Object {
    $mb = [Math]::Round($_.Length / 1MB, 2)
    Write-Host "[OK] $($_.FullName) ($mb MB)"
  }
} finally {
  Pop-Location
}