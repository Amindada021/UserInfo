<#
Run synthetic UserInfo SQLite benchmarks on a USB-connected Android device.
No user CSV, app data, network transfer or contacts are accessed.
Prerequisites: Flutter + Android SDK, USB debugging, Android scaffold created
with tool/bootstrap.ps1 once on the developer computer.

Examples:
  powershell -ExecutionPolicy Bypass -File tool/run_poco_benchmark.ps1
  powershell -ExecutionPolicy Bypass -File tool/run_poco_benchmark.ps1 -Rows 100000,1000000,5000000
  powershell -ExecutionPolicy Bypass -File tool/run_poco_benchmark.ps1 -Rows 100000000 -AllowHugeRun
#>
[CmdletBinding()]
param(
    [string]$DeviceId = "",
    [long[]]$Rows = @(100000, 1000000, 5000000),
    [ValidateRange(100,5000)][int]$BatchSize = 1500,
    [switch]$AllowHugeRun
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
    throw 'ADB not found. Install Android SDK platform-tools.'
}
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter not found. Add Flutter SDK to PATH.'
}
if (-not (Test-Path 'android/gradlew.bat')) {
    throw 'Run tool/bootstrap.ps1 first to create the Flutter Android scaffold.'
}
$available = @(adb devices | Select-String '^\S+\s+device$' |
    ForEach-Object { ($_ -split '\s+')[0] })
if (-not $DeviceId) {
    if ($available.Count -ne 1) {
        throw "Expected one connected device. Found $($available.Count). Specify -DeviceId."
    }
    $DeviceId = $available[0]
}
if ($available -notcontains $DeviceId) {
    throw "Device '$DeviceId' is not connected and authorized."
}
$model = (& adb -s $DeviceId shell getprop ro.product.model | Out-String).Trim()
$codeName = (& adb -s $DeviceId shell getprop ro.product.device | Out-String).Trim()
$android = (& adb -s $DeviceId shell getprop ro.build.version.release | Out-String).Trim()
if ($model -notmatch 'POCO X7 Pro|2412DPC0AG' -and $codeName -notmatch 'rodin') {
    Write-Warning "Detected '$model' / '$codeName', not confirmed as POCO X7 Pro."
}
if (($Rows | Where-Object { $_ -gt 10000000 }).Count -gt 0 -and
    -not $AllowHugeRun) {
    throw 'Over 10M synthetic rows needs -AllowHugeRun. Ensure ample free space.'
}
if ($Rows.Count -eq 0 -or ($Rows | Where-Object { $_ -lt 1 }).Count -gt 0) {
    throw 'Specify positive row counts.'
}
$folder = Join-Path $PWD 'benchmark_results'
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$summaryPath = Join-Path $folder "poco-$stamp-device.txt"
@(
    "Device model: $model"
    "Device code: $codeName"
    "Android version: $android"
    "Device identifier omitted"
    "Date: $(Get-Date -Format o)"
    "Rows: $($Rows -join ',')"
    "Batch size: $BatchSize"
    "Notes: disposable synthetic DB only; no personal records"
    "Data and benchmark database are deleted by the integration test"
) | Set-Content -Encoding utf8 $summaryPath
& adb -s $DeviceId shell df -k /data |
    Out-File -FilePath $summaryPath -Encoding utf8 -Append
Write-Host "Device $model, Android $android" -ForegroundColor Cyan
foreach ($count in $Rows) {
    if ($count -gt 10000000) {
        Write-Warning "This high-volume trial may require tens of GB of temporary space."
    }
    $runLog = Join-Path $folder "poco-$stamp-$count.log"
    Write-Host "Starting $count synthetic rows ..." -ForegroundColor Cyan
    $flutterArgs = @(
        'test', 'integration_test/device_benchmark_test.dart',
        '-d', $DeviceId, '--profile',
        '--dart-define=USERINFO_BENCHMARK=true',
        "--dart-define=USERINFO_BENCHMARK_ROWS=$count",
        "--dart-define=USERINFO_BATCH_SIZE=$BatchSize"
    )
    & flutter @flutterArgs 2>&1 | Tee-Object -FilePath $runLog
    if ($LASTEXITCODE -ne 0) {
        throw "Benchmark failed at $count rows. See $runLog"
    }
    if (-not (Select-String -Path $runLog -Pattern 'USERINFO_DEVICE_BENCHMARK' -Quiet)) {
        throw "No benchmark report found in $runLog"
    }
}
Write-Host "Done. Synthetic reports saved under $folder" -ForegroundColor Green
Write-Host "Share only the summary and logs after reviewing them for sensitive data."
