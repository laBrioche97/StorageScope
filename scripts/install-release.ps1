[CmdletBinding()]
param(
    [string]$Version = "latest"
)

$ErrorActionPreference = "Stop"
$repository = "laBrioche97/StorageScope"
$architecture = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq "Arm64") { "arm64" } else { "x64" }
$asset = "StorageScope-Windows-$architecture.zip"
$checksumAsset = "$asset.sha256"
$releaseBase = if ($Version -eq "latest") {
    "https://github.com/$repository/releases/latest/download"
} else {
    "https://github.com/$repository/releases/download/v$($Version.TrimStart('v'))"
}
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("StorageScope-" + [guid]::NewGuid())
$archive = Join-Path $temporary $asset
$checksum = Join-Path $temporary $checksumAsset
$destination = Join-Path $env:LOCALAPPDATA "Programs\StorageScope"

try {
    New-Item -ItemType Directory -Path $temporary | Out-Null
    Invoke-WebRequest "$releaseBase/$asset" -OutFile $archive
    Invoke-WebRequest "$releaseBase/$checksumAsset" -OutFile $checksum
    $expected = ((Get-Content $checksum -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -ne $actual) { throw "La somme SHA-256 de l'archive ne correspond pas." }

    $expanded = Join-Path $temporary "expanded"
    Expand-Archive $archive -DestinationPath $expanded
    $executable = Join-Path $expanded "StorageScope.exe"
    if (-not (Test-Path $executable)) { throw "StorageScope.exe est absent de l'archive." }

    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Copy-Item (Join-Path $expanded "*") $destination -Recurse -Force
    $shortcutPath = Join-Path ([Environment]::GetFolderPath("Programs")) "StorageScope.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Join-Path $destination "StorageScope.exe"
    $shortcut.WorkingDirectory = $destination
    $shortcut.Description = "Analyse visuelle du stockage"
    $shortcut.Save()
    Write-Host "StorageScope a été installé dans $destination"
    Write-Host "Vous pouvez maintenant le lancer depuis le menu Démarrer."
}
finally {
    if (Test-Path $temporary) { Remove-Item $temporary -Recurse -Force }
}
