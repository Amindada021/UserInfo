<# Compare synthetic Kotlin native and Flutter sqflite on connected Android. #>
[CmdletBinding()]
param(
    [string]$DeviceId = "",
    [ValidateRange(100,1000000)][int]$Rows = 100000,
    [ValidateRange(100,150000)][int]$Batch = 1500
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
    throw 'ADB not installed.'
}
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter not installed.'
}
if (-not (Test-Path 'android/gradlew.bat')) {
    throw 'Run tool/bootstrap.ps1 first.'
}
$devices = @(adb devices | Select-String '^\S+\s+device$' |
    ForEach-Object { ($_ -split '\s+')[0] })
if (-not $DeviceId) {
    if ($devices.Count -ne 1) { throw 'Specify -DeviceId.' }
    $DeviceId = $devices[0]
}
if ($devices -notcontains $DeviceId) { throw 'Device not authorized.' }
$model = (& adb -s $DeviceId shell getprop ro.product.model | Out-String).Trim()
Write-Host "Benchmark device: $model" -ForegroundColor Cyan
if ($model -notmatch 'POCO X7 Pro|2412DPC0AG') {
    Write-Warning 'Not confirmed as POCO X7 Pro.'
}
$folder = Join-Path $PWD 'benchmark_results'
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$log = Join-Path $folder ('native-compare-' +
    (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
$args = @(
    'test',
    'integration_test/native_vs_flutter_benchmark_test.dart',
    '-d', $DeviceId, '--profile',
    "--dart-define=USERINFO_NATIVE_COMPARE_ROWS=$Rows",
    "--dart-define=USERINFO_NATIVE_COMPARE_BATCH=$Batch"
)
# CRITICAL: isolate the benchmark from the user's installed UserInfo APK.
# Flutter integration tests otherwise may try to install/re-sign that package.
# A separate applicationId guarantees the real SQLite user data is untouched.
$gradlePath = Join-Path $PWD 'android/app/build.gradle.kts'
$originalGradle = [IO.File]::ReadAllText($gradlePath)
$prodId = 'applicationId = "com.amindada021.userinfo"'
$testId = 'applicationId = "com.amindada021.userinfo.benchmark"'
if (-not $originalGradle.Contains($prodId)) {
    throw 'Cannot guarantee a separate package ID; refusing to run benchmark.'
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
try {
    $testGradle = $originalGradle.Replace($prodId, $testId)
    [IO.File]::WriteAllText($gradlePath, $testGradle, $utf8)
    Write-Host 'Using isolated Android package: com.amindada021.userinfo.benchmark' -ForegroundColor Yellow
    & flutter @args 2>&1 | Tee-Object -FilePath $log
    if ($LASTEXITCODE -ne 0) { throw "Benchmark failed: $log" }
    if (-not (Select-String -Path $log -Pattern 'USERINFO_NATIVE_COMPARE_RESULT' -Quiet)) {
        throw "No benchmark result in $log"
    }
} finally {
    # Restore the production build configuration regardless of test outcome.
    [IO.File]::WriteAllText($gradlePath, $originalGradle, $utf8)
}
Write-Host "Result saved: $log" -ForegroundColor Green
