# Builds the CurseForge upload: dist\Quest-Ketchup-<version>.zip with only the
# addon files (see AddonFiles.ps1) under a top-level folder named like the toc.
# Usage: powershell -File tools\build-zip.ps1
param([string]$OutDir = (Join-Path (Split-Path $PSScriptRoot) "dist"))
. (Join-Path $PSScriptRoot "AddonFiles.ps1")

$repo = Get-AddonRepo
$toc = Get-AddonToc $repo
$folder = $toc.BaseName
$version = (Select-String -Path $toc.FullName -Pattern '^## Version:\s*(\S+)').Matches[0].Groups[1].Value
$out = Join-Path $OutDir "Quest-Ketchup-$version.zip"
$files = @(Get-AddonFiles $repo)

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
New-Item -ItemType Directory -Force $OutDir | Out-Null
if (Test-Path $out) { Remove-Item $out -Confirm:$false }
$zip = [System.IO.Compression.ZipFile]::Open($out, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in $files) {
        $src = Join-Path $repo ($f -replace '/', '\')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $src, "$folder/$f",
            [System.IO.Compression.CompressionLevel]::Optimal)
    }
} finally { $zip.Dispose() }
Write-Output "$out  ($($files.Count) files, $((Get-Item $out).Length) bytes)"
