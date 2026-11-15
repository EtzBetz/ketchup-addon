# Shared by build-zip.ps1 and deploy.ps1: what belongs to the addon itself.
# Only the toc, root Lua files, Locales and Media ship - tools, docs and other
# repo files never reach the game or the ZIP.

function Get-AddonRepo { Split-Path $PSScriptRoot }

# The toc decides the addon's folder name in WoW (QuestKetchup.toc -> QuestKetchup\).
function Get-AddonToc([string]$Repo) {
    $toc = @(Get-ChildItem $Repo -Filter *.toc)
    if ($toc.Count -ne 1) { throw "expected exactly one .toc in $Repo, found $($toc.Count)" }
    $toc[0]
}

# Repo-relative paths with forward slashes: tracked files plus new untracked
# ones (not ignored), filtered to the addon's own files.
function Get-AddonFiles([string]$Repo) {
    $files = @(git -C $Repo ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw "git ls-files failed in $Repo" }
    $files | Where-Object { $_ -match '^([^/]+\.toc|[^/]+\.lua|Locales/[^/]+\.lua|Media/.+)$' } |
        Where-Object { Test-Path -LiteralPath (Join-Path $Repo $_) }
}
