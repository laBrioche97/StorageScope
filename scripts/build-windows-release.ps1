[CmdletBinding()]
param([Parameter(Mandatory)][string]$Tag, [switch]$Development, [switch]$KeySigned)
$ErrorActionPreference = 'Stop'
if ($Tag -notmatch '^v\d+\.\d+\.\d+$') { throw 'A stable vX.Y.Z tag is required.' }
$version = $Tag.Substring(1)
$project = 'Windows/StorageScope.Windows/StorageScope.Windows.csproj'
if (([xml](Get-Content $project)).Project.PropertyGroup.Version -ne $version) { throw 'Tag and application version differ.' }
New-Item -ItemType Directory -Force release-assets | Out-Null
$certificate = $null
$signTool = $null
$updateKey = [System.Security.Cryptography.RSA]::Create()
try {
    if ($KeySigned -and $Development) { throw 'Choose KeySigned or Development, not both.' }
    if (-not $Development) {
        if ([string]::IsNullOrWhiteSpace($env:WINDOWS_UPDATE_PRIVATE_KEY_PEM_BASE64)) { throw 'Missing Windows update signing key.' }
        $updateKey.ImportFromPem([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:WINDOWS_UPDATE_PRIVATE_KEY_PEM_BASE64)))
        if ($updateKey.KeySize -lt 3072) { throw 'The update signing key must have at least 3072 bits.' }
        $publicPath = Join-Path $PWD 'Packaging/windows-update-public-key.pem'
        $publicPem = $updateKey.ExportSubjectPublicKeyInfoPem()
        if (-not (Test-Path -LiteralPath $publicPath)) { throw 'The update public key must be committed before building a release.' }
        if ([IO.File]::ReadAllText($publicPath).Replace("`r`n", "`n").Trim() -ne $publicPem.Replace("`r`n", "`n").Trim()) { throw 'Release key differs from the public key committed in the application.' }
    }
    if (-not $Development -and -not $KeySigned) {
        foreach ($name in @('WINDOWS_CERTIFICATE_PATH','WINDOWS_CERTIFICATE_PASSWORD')) {
            if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { throw "Missing signing configuration: $name" }
        }
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($env:WINDOWS_CERTIFICATE_PATH, $env:WINDOWS_CERTIFICATE_PASSWORD)
        if ($certificate.NotAfter -le [datetime]::UtcNow) { throw 'Signing certificate expired.' }
        $signTool = (Get-ChildItem 'C:/Program Files (x86)/Windows Kits/10/bin/*/x64/signtool.exe' | Sort-Object FullName -Descending | Select-Object -First 1).FullName
        if (-not $signTool) { throw 'Windows SDK SignTool is required.' }
    }
    foreach ($runtime in @('win-x64','win-arm64')) {
        $arguments = @('publish', $project, '-c', 'Release', '-r', $runtime, '--self-contained', 'true', '-o', "dist/$runtime", '-p:TreatWarningsAsErrors=true')
        if ($certificate) {
            $publisher = $certificate.Subject.Replace('%','%25').Replace(';','%3B').Replace(',','%2C')
            $arguments += "-p:StorageScopePublisher=$publisher"
        }
        & dotnet @arguments
        if ($LASTEXITCODE -ne 0) { throw "Publication failed: $runtime" }
        if ($certificate) {
            & $signTool sign /fd SHA256 /tr 'http://timestamp.digicert.com' /td SHA256 /f $env:WINDOWS_CERTIFICATE_PATH /p $env:WINDOWS_CERTIFICATE_PASSWORD "dist/$runtime/StorageScope.exe"
            if ($LASTEXITCODE -ne 0) { throw 'Executable signing failed.' }
            & $signTool verify /pa /all "dist/$runtime/StorageScope.exe"
            if ($LASTEXITCODE -ne 0) { throw 'Executable signature verification failed.' }
        }
    }
    $compiler = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
    if (-not $compiler) { $compiler = 'C:/Program Files (x86)/Inno Setup 7/ISCC.exe' }
    $arguments = @("/DAppVersion=$version")
    if ($KeySigned -or $Development) { $arguments += '/DUnsignedWindowsBuild' }
    if ($certificate) {
        # SignTool is launched by Inno with a fixed command; the password stays in the runner environment.
        $arguments += '/DSignedBuild'
        $arguments += ('/Spublisher=powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $PWD 'scripts/sign-windows-file.ps1') + '" $f')
    }
    & $compiler @arguments 'Packaging/StorageScope.iss'
    if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
    $fileName = if ($KeySigned -or $Development) { 'StorageScope-Windows-Setup-DEVELOPMENT.exe' } else { 'StorageScope-Windows-Setup.exe' }
    $installer = Join-Path $PWD "release-assets/$fileName"
    if ($certificate) {
        $signature = Get-AuthenticodeSignature $installer
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -ne $certificate.Subject) { throw 'Installer signature verification failed.' }
    }
    if (-not $Development) {
        $metadata = [ordered]@{
            schemaVersion=2; version=$version; minimumWindowsBuild=19041
            notes=[IO.File]::ReadAllText((Join-Path $PWD 'RELEASE_NOTES.md'))
            downloadUrl="https://github.com/laBrioche97/StorageScope/releases/download/$Tag/$fileName"
            sha256=(Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
            size=(Get-Item $installer).Length; architecture='universal'
            authenticodePublisher=$(if ($certificate) { $certificate.Subject } else { $null })
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($metadata | ConvertTo-Json -Depth 3))
        [IO.File]::WriteAllBytes((Join-Path $PWD 'release-assets/windows-update.json'), $bytes)
        [IO.File]::WriteAllBytes((Join-Path $PWD 'release-assets/windows-update.json.sig'), $updateKey.SignData($bytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pss))
    }
    $hash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$installer.sha256", "$hash  $fileName", [Text.Encoding]::ASCII)
} finally { $updateKey.Dispose(); if ($certificate) { $certificate.Dispose() } }
