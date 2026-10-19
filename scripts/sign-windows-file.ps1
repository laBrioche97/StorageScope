param([Parameter(Mandatory)][string]$Path)
$ErrorActionPreference = 'Stop'
$signTool = (Get-ChildItem 'C:/Program Files (x86)/Windows Kits/10/bin/*/x64/signtool.exe' | Sort-Object FullName -Descending | Select-Object -First 1).FullName
& $signTool sign /fd SHA256 /tr 'http://timestamp.digicert.com' /td SHA256 /f $env:WINDOWS_CERTIFICATE_PATH /p $env:WINDOWS_CERTIFICATE_PASSWORD $Path
if ($LASTEXITCODE -ne 0) { throw 'Signature failed.' }
