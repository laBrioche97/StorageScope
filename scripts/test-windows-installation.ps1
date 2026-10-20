$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true' -or -not $env:RUNNER_TEMP) { throw 'Installation regression tests require an isolated CI runner.' }
function Invoke-FixtureProcess([string]$Label, [string]$File, [string[]]$Arguments, [string]$Log = '') {
    Write-Host "START $Label"
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    # Wait only for the process under test. -Wait also tracks descendants, which
    # may include the application's crash monitor or an intentionally restarted UI.
    if (-not $process.WaitForExit(120000)) {
        if ($Log -and (Test-Path -LiteralPath $Log)) { Get-Content -LiteralPath $Log -Tail 60 | ForEach-Object { Write-Host $_ } }
        try { $process.Kill($true) } catch { }
        throw "$Label exceeded two minutes (process $($process.Id))."
    }
    Write-Host "END $Label : $($process.ExitCode)"
    return $process
}
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
$arguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/DIR="'+$root+'"'))
$env:STORAGESCOPE_TEST_HEALTH_FAILURE = '1'
$failureLog = Join-Path $env:RUNNER_TEMP 'storagescope-installation-failure.log'
$failed = Invoke-FixtureProcess 'injected failure and rollback' $installer ($arguments + ('/LOG="'+$failureLog+'"')) $failureLog
if ($failed.ExitCode -eq 0) { throw ('Injected replacement failure was accepted. CurrentVersion=' + (Get-ItemProperty -LiteralPath $current).CurrentVersion) }
if (-not (Test-Path -LiteralPath (Join-Path $old 'StorageScope.exe'))) { throw 'Previous version lost after failure.' }
if ((Get-ItemProperty -LiteralPath $current).CurrentVersion -ne '3.1.0') { throw 'Failed version became current.' }
Remove-Item Env:/STORAGESCOPE_TEST_HEALTH_FAILURE
$successLog = Join-Path $env:RUNNER_TEMP 'storagescope-installation-success.log'
$success = Invoke-FixtureProcess 'successful replacement' $installer ($arguments + ('/LOG="'+$successLog+'"')) $successLog
if ($success.ExitCode -ne 0) { throw "Replacement failed: $($success.ExitCode)" }
$versions = @(Get-ChildItem -LiteralPath (Join-Path $root 'versions') -Directory)
if ($versions.Count -ne 1 -or $versions[0].Name -ne $version) { throw 'More than one managed version remains after replacement.' }
$application = Join-Path $versions[0].FullName 'StorageScope.exe'
$env:HTTP_PROXY = 'http://127.0.0.1:9'; $env:HTTPS_PROXY = 'http://127.0.0.1:9'
$health = Invoke-FixtureProcess 'offline health check' $application @('--verify-installation')
if ($health.ExitCode -ne 0) { throw 'Offline installation verification failed.' }
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'StorageScope.lnk'
if (Test-Path -LiteralPath $shortcut) {
    $target = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut).TargetPath
    if ($target -ne $application) { throw 'Shortcut still targets an old version.' }
}
Write-Output 'PASS failed replacement preserves old version; successful replacement leaves one version; offline health succeeds.'

# Simulate a managed update and prove that silent installation restarts the GUI.
New-Item -ItemType Directory -Path $old -Force | Out-Null
Copy-Item -Path 'dist/win-x64/*' -Destination $old -Recurse
Set-ItemProperty -LiteralPath $current -Name CurrentVersion -Value '3.1.0'
$updateLog = Join-Path $env:RUNNER_TEMP 'storagescope-installation-update.log'
$updated = Invoke-FixtureProcess 'managed update and restart' $installer ($arguments + @('/UPDATE=1',('/LOG="'+$updateLog+'"'))) $updateLog
if ($updated.ExitCode -ne 0) { throw 'Managed update failed.' }
$deadline = [DateTime]::UtcNow.AddSeconds(20)
$restarted = $null
do {
    $restarted = Get-Process -Name StorageScope -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $application -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $restarted) { Start-Sleep -Milliseconds 250 }
} until ($restarted -or [DateTime]::UtcNow -gt $deadline)
if (-not $restarted) { throw 'Update did not restart the application.' }
if (@(Get-ChildItem -LiteralPath (Join-Path $root 'versions') -Directory).Count -ne 1) { throw 'Old version remains after managed update.' }
Start-Sleep -Seconds 2
$closed = $restarted.CloseMainWindow()
if (-not $closed -or -not $restarted.WaitForExit(15000)) {
    Write-Output ('Window title: ' + $restarted.MainWindowTitle + '; close accepted: ' + $closed)
    $diagnostics = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'StorageScope/Diagnostics/StorageScope-crashes.log'
    if (Test-Path -LiteralPath $diagnostics) { Get-Content -LiteralPath $diagnostics -Tail 12 | Write-Output }
    throw 'Restarted application could not close normally.'
}
Write-Output 'PASS accepted update restarts StorageScope and leaves exactly one managed version.'
