$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true' -or -not $env:RUNNER_TEMP) { throw 'Installation regression tests require an isolated CI runner.' }
$root = Join-Path $env:RUNNER_TEMP 'storagescope-installation-regression'
$current = 'HKCU:/Software/LaBrioche/StorageScope'
if (Test-Path -LiteralPath $current) { throw 'Existing StorageScope installation found. Refusing to alter it.' }
$version = ([xml](Get-Content 'Windows/StorageScope.Windows/StorageScope.Windows.csproj')).Project.PropertyGroup.Version
$old = Join-Path $root 'versions/3.1.0'
New-Item -ItemType Directory -Path $old -Force | Out-Null
Copy-Item -Path 'dist/win-x64/*' -Destination $old -Recurse
New-Item -Path $current -Force | Out-Null
New-ItemProperty -LiteralPath $current -Name CurrentVersion -Value '3.1.0' -Force | Out-Null
$installer = Join-Path $PWD 'release-assets/StorageScope-Windows-Setup-DEVELOPMENT.exe'
$arguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/NOICONS',('/DIR="'+$root+'"'))
$env:STORAGESCOPE_TEST_HEALTH_FAILURE = '1'
$failed = Start-Process $installer -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait
if ($failed.ExitCode -eq 0) { throw 'Injected replacement failure was accepted.' }
if (-not (Test-Path -LiteralPath (Join-Path $old 'StorageScope.exe'))) { throw 'Previous version lost after failure.' }
if ((Get-ItemProperty -LiteralPath $current).CurrentVersion -ne '3.1.0') { throw 'Failed version became current.' }
Remove-Item Env:/STORAGESCOPE_TEST_HEALTH_FAILURE
$success = Start-Process $installer -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait
if ($success.ExitCode -ne 0) { throw "Replacement failed: $($success.ExitCode)" }
$versions = @(Get-ChildItem -LiteralPath (Join-Path $root 'versions') -Directory)
if ($versions.Count -ne 1 -or $versions[0].Name -ne $version) { throw 'More than one managed version remains after replacement.' }
$application = Join-Path $versions[0].FullName 'StorageScope.exe'
$env:HTTP_PROXY = 'http://127.0.0.1:9'; $env:HTTPS_PROXY = 'http://127.0.0.1:9'
$health = Start-Process $application -ArgumentList '--verify-installation' -WindowStyle Hidden -PassThru -Wait
if ($health.ExitCode -ne 0) { throw 'Offline installation verification failed.' }
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'StorageScope.lnk'
if (Test-Path -LiteralPath $shortcut) {
    $target = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut).TargetPath
    if ($target -ne $application) { throw 'Shortcut still targets an old version.' }
}
Write-Output 'PASS failed replacement preserves old version; successful replacement leaves one version; offline health succeeds.'
