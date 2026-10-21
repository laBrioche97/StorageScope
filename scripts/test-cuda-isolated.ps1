param([ValidateSet('Download','Install','Uninstall')][string]$Phase)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') { throw 'Only disposable GitHub hosted runners may run this test.' }
$report = Join-Path $env:RUNNER_TEMP 'cuda-validation'
New-Item -ItemType Directory -Force -Path $report | Out-Null
$installer = Join-Path $env:RUNNER_TEMP 'cuda_12.1.1_531.14_windows.exe'
if ($Phase -eq 'Download') {
$cudaKeys = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object DisplayName -Like 'NVIDIA CUDA*')
if ($cudaKeys.Count -gt 0) { throw 'Runner already has CUDA; no installation will be modified.' }
@(Get-CimInstance Win32_PnPSignedDriver | Where-Object DriverProviderName -Match 'NVIDIA' | Select-Object DeviceID,DriverVersion) | ConvertTo-Json -Compress | Set-Content (Join-Path $report 'drivers-before.json')
curl.exe --fail --location --retry 3 --output $installer 'https://developer.download.nvidia.com/compute/cuda/12.1.1/local_installers/cuda_12.1.1_531.14_windows.exe'
if ($LASTEXITCODE -ne 0) { throw 'NVIDIA download failed.' }
if ((Get-FileHash -LiteralPath $installer -Algorithm MD5).Hash -ne '7DA46C38277AB61B78C24D267C5BACAE') { throw 'Official NVIDIA checksum mismatch.' }
$signature = Get-AuthenticodeSignature -LiteralPath $installer
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=NVIDIA Corporation(?:,|$)') { throw 'NVIDIA publisher signature invalid.' }
Write-Output 'PASS official fixture checksum and NVIDIA signature.'
}
if ($Phase -eq 'Install') {
$install = Start-Process -FilePath $installer -ArgumentList '-s nvcc_12.1 documentation_12.1 -n' -WindowStyle Hidden -PassThru
if (!$install.WaitForExit(600000)) { Get-Process | Select-Object ProcessName,Id,MainWindowTitle | Out-File (Join-Path $report 'install-processes.txt'); throw 'CUDA fixture installer did not exit within ten minutes.' }
if ($install.ExitCode -notin @(0,1,3010)) { throw "CUDA fixture installation failed: $($install.ExitCode)" }
Write-Output "CUDA fixture installer exited: $($install.ExitCode)"
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object DisplayName -Like 'NVIDIA CUDA*' | Select-Object DisplayName,UninstallString | ConvertTo-Json | Set-Content (Join-Path $report 'installed-components.json')
}
if ($Phase -eq 'Uninstall') {
$env:STORAGESCOPE_CUDA_DISPOSABLE = '12.1'
dotnet run --project Windows/StorageScope.Windows.Tests -c Release -- --cuda-isolated-uninstall | Tee-Object -FilePath (Join-Path $report 'result.log')
if ($LASTEXITCODE -ne 0) { throw 'CUDA official uninstall verification failed.' }
$driverAfter = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object DriverProviderName -Match 'NVIDIA' | Select-Object DeviceID,DriverVersion) | ConvertTo-Json -Compress
$driverBefore = [string](Get-Content (Join-Path $report 'drivers-before.json') -Raw)
if ($driverBefore.Trim() -ne ([string]$driverAfter).Trim()) { throw 'Graphics driver inventory changed.' }
@{ cudaDevelopmentRemoved=$true; otherComponentsPreserved=$true; graphicsDriversUnchanged=$true; runner=$env:ImageOS } | ConvertTo-Json | Set-Content (Join-Path $report 'validation.json')
}
