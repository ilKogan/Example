# GodotDeploy - export Godot Web build to gh-pages branch
# Usage: .\deploy\deploy.ps1 init | deploy [-DryRun] [-SkipTag] [-Bump patch|minor|major]

param(
    [Parameter(Position = 0)]
    [ValidateSet("init", "deploy", "help")]
    [string]$Command = "help",

    [switch]$DryRun,
    [switch]$SkipTag,
    [ValidateSet("", "patch", "minor", "major")]
    [string]$Bump = ""
)

$ErrorActionPreference = "Stop"

$DeployDir = $PSScriptRoot
$ProjectRoot = Resolve-Path (Join-Path $DeployDir "..")
$ConfigPath = Join-Path $DeployDir "deploy.json"
$LocalConfigPath = Join-Path $DeployDir "deploy.local.json"
$ConfigExamplePath = Join-Path $DeployDir "deploy.json.example"
$LocalConfigExamplePath = Join-Path $DeployDir "deploy.local.json.example"
$ProjectFile = Join-Path $ProjectRoot "project.godot"
$ShellTemplate = Join-Path $DeployDir "html_shell/shell.html"
$ShellPrepared = Join-Path $DeployDir "html_shell/index.prepared.html"

function Write-Step([string]$Message) {
    Write-Host ">> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "OK  $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "!!  $Message" -ForegroundColor Yellow
}

function Write-Err([string]$Message) {
    Write-Host "ERR $Message" -ForegroundColor Red
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path $Path)) {
        return $null
    }
    return (Get-Content $Path -Raw | ConvertFrom-Json)
}

function Get-Config {
    $config = Read-JsonFile $ConfigPath
    if (-not $config) {
        throw "Missing deploy/deploy.json. Run: .\deploy\deploy.ps1 init"
    }
    $local = Read-JsonFile $LocalConfigPath
    if ($local) {
        foreach ($prop in $local.PSObject.Properties) {
            $config | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
        }
    }
    return $config
}

function Get-ProjectSetting([string]$Key) {
    if (-not (Test-Path $ProjectFile)) {
        throw "project.godot not found at $ProjectRoot"
    }
    $content = Get-Content $ProjectFile -Raw
    $pattern = [regex]::Escape($Key) + '="([^"]*)"'
    $match = [regex]::Match($content, $pattern)
    if (-not $match.Success) {
        return ""
    }
    return $match.Groups[1].Value
}

function Set-ProjectVersion([string]$Version) {
    $content = Get-Content $ProjectFile -Raw
    if ($content -match 'config/version="[^"]*"') {
        $content = [regex]::Replace($content, 'config/version="[^"]*"', "config/version=`"$Version`"")
    } else {
        $content = $content -replace '(\[application\]\s*\r?\n)', "`$1config/version=`"$Version`"`r`n"
    }
    Set-Content -Path $ProjectFile -Value $content -NoNewline
}

function Parse-SemVer([string]$Version) {
    if ($Version -match '^(\d+)\.(\d+)\.(\d+)$') {
        return [PSCustomObject]@{
            Major = [int]$Matches[1]
            Minor = [int]$Matches[2]
            Patch = [int]$Matches[3]
        }
    }
    throw "Invalid version '$Version'. Use semver: 0.1.0"
}

function Bump-Version([string]$Version, [string]$Part) {
    $semver = Parse-SemVer $Version
    switch ($Part) {
        "major" { return "{0}.0.0" -f ($semver.Major + 1) }
        "minor" { return "{0}.{1}.0" -f $semver.Major, ($semver.Minor + 1) }
        "patch" { return "{0}.{1}.{2}" -f $semver.Major, $semver.Minor, ($semver.Patch + 1) }
        default { return $Version }
    }
}

function Compare-SemVerGreater([string]$A, [string]$B) {
    $sa = Parse-SemVer $A
    $sb = Parse-SemVer $B
    if ($sa.Major -ne $sb.Major) { return $sa.Major -gt $sb.Major }
    if ($sa.Minor -ne $sb.Minor) { return $sa.Minor -gt $sb.Minor }
    return $sa.Patch -gt $sb.Patch
}

function Get-MaxSemVer([string]$A, [string]$B) {
    if (Compare-SemVerGreater $A $B) { return $A }
    return $B
}

function Get-LatestTagVersion {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    git -C $ProjectRoot fetch origin --tags 2>$null | Out-Null
    $ErrorActionPreference = $prevEap

    $latest = "0.0.0"
    $tags = git -C $ProjectRoot tag -l "v*" 2>$null
    foreach ($tag in $tags) {
        if ($tag -match '^v(\d+\.\d+\.\d+)$') {
            $ver = $Matches[1]
            $latest = Get-MaxSemVer $ver $latest
        }
    }
    return $latest
}

function Resolve-NextVersion([object]$Config, [string]$BumpOverride) {
    $part = if ($BumpOverride) { $BumpOverride } elseif ($Config.auto_bump) { $Config.auto_bump } else { "patch" }

    $projectVersion = Get-ProjectSetting "config/version"
    if (-not $projectVersion) {
        $projectVersion = "0.0.0"
    }

    $tagVersion = Get-LatestTagVersion
    $base = Get-MaxSemVer $projectVersion $tagVersion
    return Bump-Version $base $part
}

function Restore-TemplateReadme {
    $template = Join-Path $DeployDir "README.template.md"
    if (-not (Test-Path $template)) {
        Write-Warn "Missing deploy/README.template.md"
        return
    }
    Copy-Item -Path $template -Destination (Join-Path $ProjectRoot "README.md") -Force
}

function Invoke-GitQuiet([string[]]$GitArgs) {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & git -C $ProjectRoot @GitArgs 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    return $code
}

function Complete-ReadmeFromTemplate {
    Restore-TemplateReadme
    Invoke-GitQuiet @("add", "README.md") | Out-Null
}

function Sync-SourceBranchNoHead([string]$Branch) {
    Complete-ReadmeFromTemplate
    Invoke-Git @("add", "-A")
    $status = (git -C $ProjectRoot status --porcelain | Out-String).Trim()
    if ($status) {
        Invoke-Git @("commit", "-m", "Initial project setup")
    } else {
        Invoke-Git @("commit", "--allow-empty", "-m", "Initial project setup")
    }

    $pullExit = Invoke-GitQuiet @(
        "pull", "origin", $Branch,
        "--allow-unrelated-histories", "--no-rebase", "-X", "ours"
    )
    if ($pullExit -ne 0) {
        if ((Invoke-GitQuiet @("rev-parse", "--verify", "MERGE_HEAD")) -eq 0) {
            Complete-ReadmeFromTemplate
            Invoke-Git @("add", "README.md")
            Invoke-Git @("commit", "--no-edit")
        } else {
            throw "git pull failed while initializing main. Resolve conflicts manually and retry."
        }
    }

    Complete-ReadmeFromTemplate
}

function Sync-SourceBranch([object]$Config) {
    if ($Config.pull_before_deploy -eq $false) {
        return
    }
    if ($DryRun) {
        Write-Warn "Dry run: skip git pull"
        return
    }

    $branch = $Config.source_branch
    Complete-ReadmeFromTemplate

    Write-Step "Syncing with origin/$branch..."
    Invoke-GitQuiet @("fetch", "origin") | Out-Null

    if ((Invoke-GitQuiet @("rev-parse", "--verify", "refs/remotes/origin/$branch")) -ne 0) {
        Write-Warn "Remote branch origin/$branch not found - skip pull"
        return
    }

    if ((Invoke-GitQuiet @("rev-parse", "--verify", "HEAD")) -ne 0) {
        Sync-SourceBranchNoHead $branch
        return
    }

    $pullExit = Invoke-GitQuiet @("pull", "--rebase", "--autostash", "origin", $branch)
    if ($pullExit -ne 0) {
        Invoke-GitQuiet @("rebase", "--abort") | Out-Null
        Complete-ReadmeFromTemplate
        $pullExit = Invoke-GitQuiet @("pull", "--no-rebase", "--autostash", "origin", $branch)
        if ($pullExit -ne 0) {
            throw "git pull failed. Commit or stash local changes and retry."
        }
    }

    Complete-ReadmeFromTemplate
}

function Find-Godot([string]$ConfiguredPath) {
    if ($ConfiguredPath -and (Test-Path $ConfiguredPath)) {
        return (Resolve-Path $ConfiguredPath).Path
    }

    $cmd = Get-Command godot -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $candidates = @(
        "$env:ProgramFiles\Godot\Godot*.exe",
        "$env:LOCALAPPDATA\Programs\Godot\Godot*.exe",
        "$env:USERPROFILE\Desktop\Godot*.exe",
        "$env:USERPROFILE\Downloads\Godot*.exe"
    )

    foreach ($pattern in $candidates) {
        $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($found) {
            return $found.FullName
        }
    }

    throw @"
Godot editor not found.
Create deploy/deploy.local.json with:
  { `"godot_path`": `"C:/path/to/Godot_v4.6-stable_win64.exe`" }
Or add Godot to PATH.
"@
}

function Invoke-Git([string[]]$GitArgs) {
    Invoke-GitIn $ProjectRoot $GitArgs
}

function Invoke-GitIn([string]$RepoPath, [string[]]$GitArgs) {
    & git -C $RepoPath @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed (exit $LASTEXITCODE)"
    }
}

function Test-GitRepo {
    Invoke-Git @("rev-parse", "--is-inside-work-tree") | Out-Null
}

function Test-GitOrigin {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    git -C $ProjectRoot remote get-url origin 2>$null | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevEap
    if (-not $ok) {
        throw "Git remote 'origin' not configured. Run: git remote add origin YOUR_REPO_URL"
    }
}

function Get-GitHubPagesUrl {
    try {
        Test-GitRepo
    } catch {
        return $null
    }

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    git -C $ProjectRoot remote get-url origin 2>$null | Out-Null
    $hasOrigin = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevEap
    if (-not $hasOrigin) {
        return $null
    }

    $remote = (git -C $ProjectRoot remote get-url origin | Out-String).Trim()

    if ($remote -match 'github\.com[:/](?<user>[^/]+)/(?<repo>[^/.]+)') {
        $user = $Matches.user
        $repo = $Matches.repo
        if ($repo -eq "$user.github.io") {
            return "https://$user.github.io/"
        }
        return "https://$user.github.io/$repo/"
    }
    return $null
}

function Prepare-HtmlShell([string]$Version) {
    if (-not (Test-Path $ShellTemplate)) {
        throw "Missing HTML shell template: $ShellTemplate"
    }
    $content = Get-Content $ShellTemplate -Raw
    $content = $content -replace '\{\{VERSION\}\}', $Version
    Set-Content -Path $ShellPrepared -Value $content -NoNewline
}

function Invoke-GodotExport([string]$GodotPath, [string]$Preset, [string]$RelativeOutputPath) {
    $outputFile = Join-Path $ProjectRoot ($RelativeOutputPath -replace '/', [IO.Path]::DirectorySeparatorChar)
    $outputDir = Split-Path $outputFile -Parent

    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    Write-Step "Exporting Web build..."
    if ($DryRun) {
        Write-Warn "Dry run: skip Godot export"
        return
    }

    & $GodotPath --headless --path $ProjectRoot --export-release $Preset $RelativeOutputPath
    if ($LASTEXITCODE -ne 0) {
        throw "Godot export failed (exit $LASTEXITCODE). Install Web Export Templates in Godot."
    }

    for ($i = 0; $i -lt 10; $i++) {
        if (Test-Path $outputFile) {
            return
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Export finished but $outputFile was not created."
}

function Clear-DirectoryContents([string]$Path) {
    Get-ChildItem -Path $Path -Force | Where-Object { $_.Name -ne ".git" } | Remove-Item -Recurse -Force
}

function Get-ReleaseCommitLines([string]$SinceVersion) {
    $gitArgs = @("log", "--pretty=format:%h|%s|%an|%ad", "--date=short", "--no-merges")

    if ($SinceVersion -and $SinceVersion -ne "0.0.0") {
        git -C $ProjectRoot rev-parse -q --verify "refs/tags/v$SinceVersion" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $gitArgs += "v${SinceVersion}..HEAD"
        } else {
            $gitArgs += "-n", "30"
        }
    } else {
        $gitArgs += "-n", "30"
    }

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = git -C $ProjectRoot @gitArgs 2>$null
    $ErrorActionPreference = $prevEap

    $lines = @()
    if (-not $output) {
        return @("- Нет записей")
    }

    foreach ($line in ($output -split "`n")) {
        if (-not $line.Trim()) { continue }
        $parts = $line -split '\|', 4
        if ($parts.Count -ge 4) {
            $lines += "- $($parts[1]) ($($parts[2]), $($parts[3]))"
        }
    }
    return $lines
}

function Write-GhPagesReadme([string]$WorktreePath, [string]$Version, [string]$PreviousVersion, [object]$Config) {
    $gameName = Get-ProjectSetting "config/name"
    if (-not $gameName) { $gameName = "Игра" }

    $pagesUrl = $Config.github_pages_url
    if (-not $pagesUrl) { $pagesUrl = Get-GitHubPagesUrl }
    $playLink = if ($pagesUrl) { $pagesUrl } else { "index.html" }

    $date = Get-Date -Format "yyyy-MM-dd HH:mm"
    $commits = Get-ReleaseCommitLines $PreviousVersion
    $commitBlock = ($commits -join "`n")

    $content = @"
# [$gameName]($playLink) $Version
$date
## Изменения
$commitBlock
---
"@

    Set-Content -Path (Join-Path $WorktreePath "README.md") -Value $content -Encoding UTF8
}

function Ensure-ReleaseCommit([object]$Config, [string]$Version) {
    if ($DryRun) {
        Write-Warn "Dry run: skip source commit"
        return
    }

    Restore-TemplateReadme
    $commitMessage = ($Config.source_commit_template -replace '\{version\}', $Version)
    Invoke-Git @("add", "-A")
    $status = (git -C $ProjectRoot status --porcelain | Out-String).Trim()
    if ($status) {
        Invoke-Git @("commit", "-m", $commitMessage)
        Write-Ok "Source committed on $($Config.source_branch)"
    }
}

function Copy-ExportFiles([string]$SourceDir, [string]$TargetDir) {
    Get-ChildItem -Path $SourceDir -Force | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $TargetDir -Recurse -Force
    }
}

function Publish-GhPages([object]$Config, [string]$ExportDir, [string]$Version, [string]$PreviousVersion) {
    $pagesBranch = $Config.pages_branch
    $worktreePath = Join-Path $ProjectRoot $Config.worktree_dir
    $commitMessage = ($Config.commit_message_template -replace '\{version\}', $Version)

    $branchExists = $false
    git -C $ProjectRoot show-ref --verify --quiet "refs/heads/$pagesBranch"
    if ($LASTEXITCODE -eq 0) { $branchExists = $true }

    $remoteBranchExists = $false
    git -C $ProjectRoot show-ref --verify --quiet "refs/remotes/origin/$pagesBranch"
    if ($LASTEXITCODE -eq 0) { $remoteBranchExists = $true }

    if ($DryRun) {
        Write-Warn "Dry run: would publish to branch '$pagesBranch' via worktree '$worktreePath'"
        return
    }

    if (Test-Path $worktreePath) {
        Write-Step "Removing old worktree..."
        Invoke-Git @("worktree", "remove", "--force", $Config.worktree_dir)
    }

    Write-Step "Preparing gh-pages worktree..."
    if ($branchExists) {
        Invoke-Git @("worktree", "add", $Config.worktree_dir, $pagesBranch)
    } elseif ($remoteBranchExists) {
        Invoke-Git @("fetch", "origin", "${pagesBranch}:${pagesBranch}")
        Invoke-Git @("worktree", "add", $Config.worktree_dir, $pagesBranch)
    } else {
        Invoke-Git @("worktree", "add", "-B", $pagesBranch, $Config.worktree_dir)
        Clear-DirectoryContents $worktreePath
    }

    Clear-DirectoryContents $worktreePath
    Copy-ExportFiles $ExportDir $worktreePath
    Write-GhPagesReadme $worktreePath $Version $PreviousVersion $Config

    try {
        Invoke-GitIn $worktreePath @("add", "-A")
        $status = (git -C $worktreePath status --porcelain | Out-String).Trim()
        if ($status) {
            Invoke-GitIn $worktreePath @("commit", "-m", $commitMessage)
            Write-Step "Pushing $pagesBranch to origin..."
            Invoke-GitIn $worktreePath @("push", "-u", "origin", $pagesBranch)
        } else {
            Write-Warn "No changes in web build - skip push"
        }
    } finally {
        Invoke-Git @("worktree", "remove", "--force", $Config.worktree_dir)
    }
}

function Push-SourceAndTag([object]$Config, [string]$Version) {
    if ($DryRun) {
        Write-Warn "Dry run: would tag and push v$Version"
        return
    }

    $tagName = "v$Version"

    git -C $ProjectRoot rev-parse -q --verify "refs/tags/$tagName" 2>$null
    if ($LASTEXITCODE -eq 0) {
        throw "Tag $tagName already exists."
    }

    if (-not $SkipTag) {
        Invoke-Git @("tag", $tagName)
        Write-Step "Pushing $($Config.source_branch) and tag..."
        Invoke-Git @("push", "origin", $Config.source_branch)
        Invoke-Git @("push", "origin", $tagName)
    } else {
        Write-Step "Pushing $($Config.source_branch)..."
        Invoke-Git @("push", "origin", $Config.source_branch)
    }
}

function Initialize-GhPagesBranch([object]$Config) {
    try {
        Test-GitRepo
        Test-GitOrigin
    } catch {
        Write-Warn "gh-pages будет создана при первом deploy (нужны git + origin)"
        return
    }

    $pagesBranch = $Config.pages_branch
    if (-not $pagesBranch) { $pagesBranch = "gh-pages" }

    Invoke-GitQuiet @("fetch", "origin") | Out-Null

    git -C $ProjectRoot show-ref --verify --quiet "refs/remotes/origin/$pagesBranch"
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Branch $pagesBranch already on GitHub"
        return
    }

    Write-Step "Creating branch $pagesBranch on GitHub..."

    $worktreePath = Join-Path $ProjectRoot $Config.worktree_dir
    if (Test-Path $worktreePath) {
        Invoke-Git @("worktree", "remove", "--force", $Config.worktree_dir)
    }

    Invoke-Git @("worktree", "add", "-B", $pagesBranch, $Config.worktree_dir)
    Clear-DirectoryContents $worktreePath

    $placeholder = @"
# Скоро здесь будет игра

Запусти ``deploy.bat deploy`` из ветки main.
"@
    Set-Content -Path (Join-Path $worktreePath "README.md") -Value $placeholder -Encoding UTF8

    try {
        Invoke-GitIn $worktreePath @("add", "README.md")
        Invoke-GitIn $worktreePath @("commit", "-m", "Initialize gh-pages")
        Invoke-GitIn $worktreePath @("push", "-u", "origin", $pagesBranch)
        Write-Ok "Branch $pagesBranch created - enable GitHub Pages"
    } finally {
        Invoke-Git @("worktree", "remove", "--force", $Config.worktree_dir)
    }
}

function Show-Help {
    @"

GodotDeploy - one-repo Web deploy to GitHub Pages

Usage:
  .\deploy\deploy.ps1 init
  .\deploy\deploy.ps1 deploy [-DryRun] [-SkipTag] [-Bump patch|minor|major]

Commands:
  init    Create config files and verify setup
  deploy  Auto-bump version, export, push gh-pages, tag main

Each deploy automatically increments patch (0.1.0 -> 0.1.1).
Uses the highest version from project.godot and git tags.

GitHub Pages: Settings -> Build and deployment -> Branch: gh-pages, folder: /

"@
}

function Invoke-Init {
    Write-Step "Initializing GodotDeploy..."

    if (-not (Test-Path $ProjectFile)) {
        throw "Run this from a Godot project root (project.godot missing)."
    }

    Restore-TemplateReadme
    Write-Ok "README restored from template"

    if (-not (Test-Path $ConfigPath)) {
        Copy-Item $ConfigExamplePath $ConfigPath
        Write-Ok "Created deploy/deploy.json"
    } else {
        Write-Warn "deploy/deploy.json already exists"
    }

    if (-not (Test-Path $LocalConfigPath)) {
        Copy-Item $LocalConfigExamplePath $LocalConfigPath
        Write-Ok "Created deploy/deploy.local.json - set godot_path if needed"
    }

    $version = Get-ProjectSetting "config/version"
    Prepare-HtmlShell $version
    Write-Ok "Prepared HTML shell for v$version"

    try {
        Test-GitRepo
        Write-Ok "Git repository detected"
    } catch {
        Write-Warn 'Not a git repo yet. Run: git init; git remote add origin YOUR_REPO_URL'
    }

    $godot = Find-Godot (Read-JsonFile $LocalConfigPath).godot_path
    Write-Ok "Godot: $godot"

    $config = Read-JsonFile $ConfigPath
    if ($config) {
        Initialize-GhPagesBranch $config
    }

    $pagesUrl = Get-GitHubPagesUrl
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor White
    Write-Host "  1. Rename game in project.godot (config/name)"
    Write-Host "  2. Install Web Export Templates in Godot (Editor -> Manage Export Templates)"
    Write-Host "  3. Enable GitHub Pages: branch gh-pages, folder /"
    Write-Host "  4. Run: .\deploy\deploy.ps1 deploy"
    if ($pagesUrl) {
        Write-Host "  5. Game URL: $pagesUrl" -ForegroundColor Green
    }
}

function Invoke-Deploy {
    $config = Get-Config
    Test-GitRepo
    Test-GitOrigin

    Sync-SourceBranch $config

    $previousVersion = Get-LatestTagVersion
    $version = Resolve-NextVersion $config $Bump
    if (-not $DryRun) {
        Set-ProjectVersion $version
    }
    Write-Ok "Auto version: $version"

    Ensure-ReleaseCommit $config $version

    $godot = Find-Godot $config.godot_path
    Write-Ok "Godot: $godot"

    $exportDir = Join-Path $ProjectRoot $config.export_output_dir
    $exportRelative = "$($config.export_output_dir)/index.html".Replace('\', '/')
    Prepare-HtmlShell $version
    Invoke-GodotExport $godot $config.export_preset $exportRelative
    Write-Ok "Export complete"

    Publish-GhPages $config $exportDir $version $previousVersion
    Write-Ok "Published to branch $($config.pages_branch)"

    Push-SourceAndTag $config $version

    $pagesUrl = $config.github_pages_url
    if (-not $pagesUrl) {
        $pagesUrl = Get-GitHubPagesUrl
    }

    Write-Host ""
    Write-Host "Deploy complete - v$version" -ForegroundColor Green
    if ($pagesUrl) {
        Write-Host "Play: $pagesUrl" -ForegroundColor Green
    }
    Write-Warn "If you see an old build in browser, hard-refresh (Ctrl+F5)."
}

Push-Location $ProjectRoot
try {
    switch ($Command) {
        "init" { Invoke-Init }
        "deploy" { Invoke-Deploy }
        default { Show-Help }
    }
} finally {
    Pop-Location
}
