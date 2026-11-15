# Installs the current working copy into the game: copies the addon files (see
# AddonFiles.ps1) to <AddOnsDir>\<toc name>, e.g. ...\AddOns\QuestKetchup, and
# removes files there that the addon no longer has. Never edit the installed
# copy - it gets overwritten.
# Usage: powershell -File tools\deploy.ps1 [-AddOnsDir <WoW>\_forever_\Interface\AddOns]
param([string]$AddOnsDir = "D:\Program Files\World of Warcraft\_forever_\Interface\AddOns")
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "AddonFiles.ps1")

$repo = (Resolve-Path (Get-AddonRepo)).Path.TrimEnd('\')
$name = (Get-AddonToc $repo).BaseName
if (-not (Test-Path -LiteralPath $AddOnsDir -PathType Container)) { throw "AddOns folder not found: $AddOnsDir" }
$target = Join-Path (Resolve-Path -LiteralPath $AddOnsDir).Path $name

# Safety: the target must be a plain installed copy, never this repo or a working copy.
if ($target -eq $repo -or $target.StartsWith("$repo\") -or $repo.StartsWith("$target\")) {
    throw "target $target overlaps the repo $repo - move the repo out of the AddOns folder first"
}
if (Test-Path -LiteralPath (Join-Path $target ".git")) { throw "$target contains a .git folder - not touching a working copy" }

$files = @(Get-AddonFiles $repo)
$wanted = @{}
$copied = New-Object System.Collections.Generic.List[string]
foreach ($f in $files) {
    $rel = $f -replace '/', '\'
    $wanted[$rel.ToLowerInvariant()] = $true
    $src = Join-Path $repo $rel
    $dst = Join-Path $target $rel
    if ((Test-Path -LiteralPath $dst) -and
        (Get-FileHash -LiteralPath $src).Hash -eq (Get-FileHash -LiteralPath $dst).Hash) { continue }
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $copied.Add($rel)
}

$removed = New-Object System.Collections.Generic.List[string]
foreach ($file in @(Get-ChildItem -LiteralPath $target -Recurse -File)) {
    $rel = $file.FullName.Substring($target.Length + 1)
    if (-not $wanted[$rel.ToLowerInvariant()]) {
        Remove-Item -LiteralPath $file.FullName -Force
        $removed.Add($rel)
    }
}
Get-ChildItem -LiteralPath $target -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending |
    Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force) } | Remove-Item -Force

Write-Output "Deployed to $target ($($files.Count) files)"
if ($copied.Count) { Write-Output ("  updated: " + ($copied -join ", ")) }
if ($removed.Count) { Write-Output ("  removed: " + ($removed -join ", ")) }
if (-not $copied.Count -and -not $removed.Count) { Write-Output "  already up to date" }
# /reload picks up changed Lua; the toc, new or removed files and textures need a game restart
if ($removed.Count -or ($copied | Where-Object { $_ -like "*.toc" -or $_ -like "Media\*" })) {
    Write-Output "  -> restart the game (toc, files or textures changed)"
} elseif ($copied.Count) {
    Write-Output "  -> /reload in-game"
}
