#!/usr/bin/env pwsh
# Update the default branch of every git repo under your code folder.
#
#   ./update-default-branches.ps1 [-CodeDir DIR] [-DryRun] [-NoPrune] [-NoCi] [-Summarize]
#
# Behaviour per repo:
#   1. Detect the default branch (origin/HEAD -> origin/main|master -> main|master).
#   2. Always `git fetch` (so even dirty repos get the latest refs locally).
#   3. If the working tree is clean  -> fast-forward the default branch to origin.
#   4. If the working tree is dirty  -> fetch only, never touch the checkout.
#   5. Check whether the fetched default branch is green (GitHub CI rollup of its tip).
#
# A repo counts as "dirty" if `git status --porcelain` prints anything
# (tracked modifications AND untracked files). Untracked-only repos are
# therefore fetch-only too -- safe default for a bulk script.
#
# CI status comes from the GitHub API via `gh` (-GhBin) with one read-only
# GraphQL query per repo: CI-GREEN / CI-RED / CI-PENDING / CI-NONE / CI-?.
# A red or pending default branch is reported inline and again in the closing
# roll-up, but does not change the exit code (that only tracks the git work).
# Repos with no GitHub origin, or with no `gh` available, are skipped.
#
# With -Summarize, every repo whose default branch actually moved gets a
# per-repo change summary via `muse exec` (read-only), followed by one
# combined digest across all updated repos. Summaries go to stdout; all
# progress/diagnostic lines go to the host (Write-Host).
#
# Exit code: 0 if no failures, 1 if any repo failed, 2 on bad usage.

[CmdletBinding()]
param(
  [string]$CodeDir,
  [switch]$DryRun,
  [switch]$NoPrune,
  [switch]$NoCi,
  [switch]$Summarize,
  [string]$MuseBin,
  [string]$SummaryEffort,
  [string]$GhBin,
  [int]$FetchTimeout,
  [switch]$Help
)

$ErrorActionPreference = 'Continue'
# Native command failures are handled by inspecting exit codes, never as
# terminating errors (PowerShell 7.3+ turns them into errors by default).
$PSNativeCommandUseErrorActionPreference = $false

$IsWindowsHost = ($env:OS -eq 'Windows_NT')

if (-not $CodeDir)       { $CodeDir = if ($env:CODE_DIR) { $env:CODE_DIR } else { Join-Path $HOME 'code' } }
if (-not $MuseBin)       { $MuseBin = if ($env:MUSE_BIN) { $env:MUSE_BIN } else { 'muse' } }
if (-not $SummaryEffort) { $SummaryEffort = if ($env:SUMMARY_EFFORT) { $env:SUMMARY_EFFORT } else { 'low' } }
if (-not $GhBin)         { $GhBin = if ($env:GH_BIN) { $env:GH_BIN } else { 'gh' } }
if (-not $PSBoundParameters.ContainsKey('FetchTimeout')) {
  $FetchTimeout = if ($env:FETCH_TIMEOUT) { [int]$env:FETCH_TIMEOUT } else { 120 }
}

$Prune   = -not $NoPrune
$CheckCi = -not $NoCi

# Batch mode: never prompt for credentials/passphrases -- a repo whose remote
# needs interactive auth fails fast (FAIL + continue) instead of hanging the
# whole sweep waiting on input. Override from your environment if you want.
if (-not $env:GIT_TERMINAL_PROMPT) { $env:GIT_TERMINAL_PROMPT = '0' }
if (-not $env:GIT_SSH_COMMAND) { $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o ConnectTimeout=15' }
# Last-resort prompt program (POSIX only): if no credential helper can supply
# creds (e.g. a private repo with an expired token), fail fast instead of
# popping up a dialog that looks like a hang. Windows has no `true`, so there
# we rely on GIT_TERMINAL_PROMPT=0 alone.
if (-not $IsWindowsHost -and -not $env:GIT_ASKPASS) { $env:GIT_ASKPASS = 'true' }

function Show-Usage {
  $name = Split-Path -Leaf $PSCommandPath
  @"
Usage: $name [options]

Options:
  -CodeDir DIR      Folder containing your repos (default: `$CODE_DIR or `$HOME/code)
  -DryRun           Print what would happen without changing anything
  -NoPrune          Do not pass --prune to git fetch
  -NoCi             Do not check default-branch CI status via 'gh' (-GhBin)
  -Summarize        Run 'muse exec' on each updated repo for a change summary,
                    plus one combined digest (-MuseBin, -SummaryEffort)
  -FetchTimeout N   Seconds to allow one git fetch (0 disables, default: 120)
  -Help             Show this help
"@
}

if ($Help) { Show-Usage; exit 0 }

if (-not (Test-Path -LiteralPath $CodeDir -PathType Container)) {
  Write-Host -ForegroundColor Red "error: code dir not found: $CodeDir"
  exit 2
}

# --- status lines (colours degrade automatically when not attached to a console) ---
function Write-Ok   { param([string]$Message) Write-Host -ForegroundColor Green    "OK $Message" }
function Write-Skip { param([string]$Message) Write-Host -ForegroundColor Yellow   "SKIP $Message" }
function Write-Fail { param([string]$Message) Write-Host -ForegroundColor Red      "FAIL $Message" }
function Write-Info { param([string]$Message) Write-Host -ForegroundColor DarkGray "$Message" }
function Write-CiLine {
  param([string]$Color, [string]$Tag, [string]$Message)
  Write-Host -ForegroundColor $Color "$Tag $Message"
}

# --- running external commands ---------------------------------------------------

# Quote one argument for the Windows/DOS command-line parser (only needed on
# Windows PowerShell 5.1, which has no ProcessStartInfo.ArgumentList).
function ConvertTo-ArgString {
  param([string]$Argument)
  if ($Argument -ne '' -and $Argument -notmatch '[\s"]') { return $Argument }
  $sb = [System.Text.StringBuilder]::new()
  [void]$sb.Append('"')
  $backslashes = 0
  foreach ($ch in $Argument.ToCharArray()) {
    if ($ch -eq '\') { $backslashes++; continue }
    if ($ch -eq '"') {
      [void]$sb.Append((('\' * ($backslashes * 2 + 1)) -join ''))
      [void]$sb.Append('"')
    } else {
      [void]$sb.Append((('\' * $backslashes) -join ''))
      [void]$sb.Append($ch)
    }
    $backslashes = 0
  }
  [void]$sb.Append((('\' * ($backslashes * 2)) -join ''))
  [void]$sb.Append('"')
  $sb.ToString()
}

# Run a program, capture stdout/stderr, and cap the wall time.
# Returns @{ ExitCode; StdOut; StdErr; Output } -- Output is both streams merged.
# ExitCode 124 means the timeout fired and the process was killed.
function Invoke-Process {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [int]$TimeoutSec = 0,
    [string]$WorkingDirectory = $PWD.ProviderPath
  )
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $FilePath
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  # Child processes inherit the *process* working directory, which does not
  # follow Push-Location on its own -- pass the current PowerShell location.
  if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  if ($psi.PSObject.Properties['ArgumentList']) {
    foreach ($a in $ArgumentList) { $psi.ArgumentList.Add($a) }
  } else {
    $psi.Arguments = (($ArgumentList | ForEach-Object { ConvertTo-ArgString $_ }) -join ' ')
  }

  $proc = [System.Diagnostics.Process]::new()
  $proc.StartInfo = $psi
  try {
    if (-not $proc.Start()) { throw "could not start $FilePath" }
  } catch {
    return [pscustomobject]@{ ExitCode = 127; StdOut = ''; StdErr = "$_"; Output = "$_" }
  }

  $outTask = $proc.StandardOutput.ReadToEndAsync()
  $errTask = $proc.StandardError.ReadToEndAsync()
  $code = 0
  if ($TimeoutSec -gt 0) {
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
      try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } }
      [void]$proc.WaitForExit(5000)
      $code = 124
    } else {
      $code = $proc.ExitCode
    }
  } else {
    $proc.WaitForExit()
    $code = $proc.ExitCode
  }

  $stdOut = ''; $stdErr = ''
  try { $stdOut = $outTask.Result } catch { }
  try { $stdErr = $errTask.Result } catch { }
  $proc.Dispose()

  [pscustomobject]@{
    ExitCode = $code
    StdOut   = ($stdOut -replace "`r`n", "`n")
    StdErr   = ($stdErr -replace "`r`n", "`n")
    Output   = ((($stdOut + "`n" + $stdErr) -replace "`r`n", "`n")).Trim()
  }
}

function Invoke-Git {
  param([Parameter(Position = 0, ValueFromRemainingArguments)][string[]]$GitArgs, [int]$TimeoutSec = 0)
  Invoke-Process -FilePath 'git' -ArgumentList $GitArgs -TimeoutSec $TimeoutSec
}

function Test-GitRef {
  param([string]$Ref)
  (Invoke-Git 'show-ref' '--verify' '--quiet' $Ref).ExitCode -eq 0
}

# Detect the default branch name (e.g. "main"); $null if unknown.
function Get-DefaultBranch {
  $r = Invoke-Git 'symbolic-ref' '--quiet' '--short' 'refs/remotes/origin/HEAD'
  if ($r.ExitCode -eq 0) {
    $ref = $r.StdOut.Trim()
    if ($ref.StartsWith('origin/')) { return $ref.Substring(7) }
  }
  # Prefer whichever remote-tracking branch exists locally, then local branches.
  foreach ($b in 'main', 'master') { if (Test-GitRef "refs/remotes/origin/$b") { return $b } }
  foreach ($b in 'main', 'master') { if (Test-GitRef "refs/heads/$b") { return $b } }
  return $null
}

# "owner/repo" for a GitHub origin remote, $null if it isn't one.
function Get-GitHubSlug {
  $r = Invoke-Git 'config' '--get' 'remote.origin.url'
  if ($r.ExitCode -ne 0) { return $null }
  $url = $r.StdOut.Trim()
  if (-not $url) { return $null }
  if ($url -match '^(?:git@|ssh://git@|https?://(?:[^@/]*@)?|git://|)github\.com[:/](?<slug>[^/]+/[^/]+?)(?:\.git)?/?$') {
    return $Matches['slug']
  }
  return $null
}

# --- CI status -------------------------------------------------------------------

$CiQuery = 'query($owner:String!,$name:String!,$oid:GitObjectID!){repository(owner:$owner,name:$name){object(oid:$oid){... on Commit{statusCheckRollup{state contexts(first:100){nodes{__typename ... on CheckRun{name status conclusion} ... on StatusContext{context state}}}}}}}}'
$OkConclusions = @('SUCCESS', 'NEUTRAL', 'SKIPPED', '')

# Shorten a message to one readable line for the roll-up.
function Format-Note {
  param([string]$Text)
  $first = ($Text -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
  if (-not $first) { return 'no output' }
  $first = $first.Trim()
  if ($first.Length -gt 120) { return $first.Substring(0, 120) }
  $first
}

# Check the CI rollup of one commit and report it. Never fails the script.
function Invoke-CiCheck {
  param([string]$Name, [string]$Slug, [string]$Sha, [string]$Branch)

  if (-not $Slug) {
    Write-CiLine DarkGray 'CI-?' "$Name`: not a GitHub origin, skipping CI check"
    return
  }

  $parts = $Slug.Split('/', 2)
  $r = Invoke-Process -FilePath $GhBin -TimeoutSec 60 -ArgumentList @(
    'api', 'graphql',
    '-f', "query=$CiQuery",
    '-f', "owner=$($parts[0])",
    '-f', "name=$($parts[1])",
    '-f', "oid=$Sha"
  )

  if ($r.ExitCode -eq 124) {
    $note = "timed out after 60s"
    Write-CiLine DarkGray 'CI-?' "$Name`: could not query CI for origin/$Branch ($note)"
    $script:Bad.Add([pscustomobject]@{ Tag = 'UNKNOWN'; Name = $Name; Branch = $Branch; Detail = $note })
    $script:Counters.ciUnknown++
    return
  }

  $payload = $null
  if ($r.ExitCode -eq 0) {
    try { $payload = $r.StdOut | ConvertFrom-Json -ErrorAction Stop } catch { $payload = $null }
  }
  if (-not $payload) {
    $note = Format-Note $r.Output
    Write-CiLine DarkGray 'CI-?' "$Name`: could not query CI for origin/$Branch ($note)"
    $script:Bad.Add([pscustomobject]@{ Tag = 'UNKNOWN'; Name = $Name; Branch = $Branch; Detail = "query failed: $note" })
    $script:Counters.ciUnknown++
    return
  }

  $state = $null; $failing = @(); $pending = @()
  $repository = $payload.data.repository
  if (-not $repository -or -not $repository.object) {
    $state = 'UNKNOWN'
  } else {
    $rollup = $repository.object.statusCheckRollup
    if (-not $rollup) {
      $state = 'NONE'
    } else {
      $state = $rollup.state
      $nodes = @($rollup.contexts.nodes)
      $failing = @($nodes | Where-Object {
        if ($_.__typename -eq 'CheckRun') {
          $_.status -eq 'COMPLETED' -and ($_.conclusion -notin $OkConclusions)
        } else {
          $_.state -eq 'FAILURE' -or $_.state -eq 'ERROR'
        }
      } | ForEach-Object { if ($_.__typename -eq 'CheckRun') { $_.name } else { $_.context } })
      $pending = @($nodes | Where-Object {
        if ($_.__typename -eq 'CheckRun') { $_.status -ne 'COMPLETED' } else { $_.state -eq 'PENDING' }
      } | ForEach-Object { if ($_.__typename -eq 'CheckRun') { $_.name } else { $_.context } })
    }
  }

  $failingText = if ($failing.Count) { $failing -join ', ' } else { '' }
  $pendingText = if ($pending.Count) { $pending -join ', ' } else { '' }

  switch ($state) {
    'SUCCESS' {
      $script:Counters.ciGreen++
      Write-CiLine Green 'CI-GREEN' "$Name`: default branch origin/$Branch is green"
    }
    { $_ -eq 'FAILURE' -or $_ -eq 'ERROR' } {
      $script:Counters.ciRed++
      $detail = if ($failingText) { "failing: $failingText" } else { 'failing: unknown' }
      $script:Bad.Add([pscustomobject]@{ Tag = 'RED'; Name = $Name; Branch = $Branch; Detail = $detail })
      Write-CiLine Red 'CI-RED' "$Name`: default branch origin/$Branch is RED ($(if ($failingText) { $failingText } else { 'see GitHub' }))"
    }
    { $_ -eq 'PENDING' -or $_ -eq 'EXPECTED' } {
      $script:Counters.ciPending++
      $detail = if ($pendingText) { "running: $pendingText" } else { 'running: unknown' }
      $script:Bad.Add([pscustomobject]@{ Tag = 'PENDING'; Name = $Name; Branch = $Branch; Detail = $detail })
      Write-CiLine Yellow 'CI-PENDING' "$Name`: default branch origin/$Branch is not green yet ($(if ($pendingText) { $pendingText } else { 'see GitHub' }))"
    }
    'NONE' {
      $script:Counters.ciNone++
      Write-CiLine DarkGray 'CI-NONE' "$Name`: no CI checks reported for origin/$Branch"
    }
    default {
      $script:Counters.ciUnknown++
      $shown = if ($state) { $state } else { 'empty response' }
      $script:Bad.Add([pscustomobject]@{ Tag = 'UNKNOWN'; Name = $Name; Branch = $Branch; Detail = "unexpected state: $shown" })
      Write-CiLine DarkGray 'CI-?' "$Name`: default branch origin/$Branch is not green yet (unknown state: $shown)"
    }
  }
}

# --- change summaries (muse exec) ------------------------------------------------

function Invoke-Summarize {
  param([object[]]$Repos)

  Write-Host ''
  Write-Host '=== Change summaries ==='

  $digestParts = [System.Collections.Generic.List[string]]::new()
  $summaryFailures = 0

  foreach ($repo in $Repos) {
    $shortBefore = $repo.Before.Substring(0, 7)
    $shortAfter = $repo.After.Substring(0, 7)

    # -C so these run against the repo even though the sweep's cwd is elsewhere.
    $log = ((Invoke-Git -TimeoutSec 60 '-C' $repo.Dir 'log' '--oneline' '--no-decorate' "$($repo.Before)..$($repo.After)" '--').StdOut -split "`n" |
      Where-Object { $_ } | Select-Object -First 50) -join "`n"
    $stat = ((Invoke-Git -TimeoutSec 60 '-C' $repo.Dir 'diff' '--stat' $repo.Before $repo.After '--').StdOut -split "`n" |
      Where-Object { $_ } | Select-Object -First 60) -join "`n"

    $prompt = @"
You are summarizing new commits that just landed on branch '$($repo.Branch)' of the '$($repo.Name)' repository (updated $shortBefore..$shortAfter). Using ONLY the commit list and diffstat below, write a concise summary: a one-line overview plus short bullets grouped by theme, mentioning notable files. Keep it under 15 lines. Do not browse or change anything.

Commits:
$(if ($log) { $log } else { '(no commit list available)' })

Diffstat:
$(if ($stat) { $stat } else { '(no diffstat available)' })
"@

    Write-Output ("## {0} ({1} {2}..{3})" -f $repo.Name, $repo.Branch, $shortBefore, $shortAfter)
    $res = Invoke-Process -FilePath $MuseBin -TimeoutSec 300 -ArgumentList @(
      'exec', '--workspace', $repo.Dir, '--reasoning-effort', $SummaryEffort, '--disable-write', $prompt
    )
    if ($res.ExitCode -eq 0) {
      Write-Output $res.StdOut.TrimEnd()
      Write-Output ''
      $digestParts.Add("### $($repo.Name)`n$($res.StdOut.TrimEnd())")
    } else {
      Write-Output "(summary failed for $($repo.Name))"
      Write-Output ''
      $summaryFailures++
    }
  }

  if ($digestParts.Count -gt 0) {
    Write-Host '=== Overall digest ==='
    $digestPrompt = @"
Below are per-repository change summaries from a bulk update of many git repos. Write a short overall digest: what changed across the fleet, grouped by theme, under 20 lines. Then list the repos covered. Base it ONLY on the summaries below.

$($digestParts -join "`n`n")
"@
    $digest = Invoke-Process -FilePath $MuseBin -TimeoutSec 300 -ArgumentList @(
      'exec', '--reasoning-effort', $SummaryEffort, '--disable-write', $digestPrompt
    )
    if ($digest.ExitCode -eq 0) {
      Write-Output $digest.StdOut.TrimEnd()
    } else {
      Write-Skip 'Overall digest failed; per-repo summaries above still stand.'
      $summaryFailures++
    }
  }

  if ($summaryFailures -gt 0) { Write-Skip "$summaryFailures summarizer call(s) failed." }
}

# --- one repo --------------------------------------------------------------------

# Update one repo. Prints its status lines and returns the sh-compatible code:
# 0 = updated, 10 = skipped, 20 = dirty (fetch only), 30 = up to date, 1 = failed.
function Invoke-RepoUpdate {
  param([string]$Name, [string]$Dir)

  Push-Location -LiteralPath $Dir
  try {
    if ((Invoke-Git 'remote' 'get-url' 'origin').ExitCode -ne 0) {
      Write-Skip "$Name`: no 'origin' remote, skipping"
      return 10
    }

    $branch = Get-DefaultBranch
    if (-not $branch) {
      Write-Skip "$Name`: could not determine default branch, skipping"
      return 10
    }

    # Progress marker: if the sweep ever stalls, the last line names the repo.
    Write-Info "-> $Name ($branch): fetching origin..."

    # Always fetch first so dirty repos still get fresh refs.
    $fetchArgs = @()
    if ($Prune) { $fetchArgs += '--prune' }
    $fetchArgs += 'origin'

    if ($DryRun) {
      Write-Info "$Name`: [dry-run] would run: git fetch $($fetchArgs -join ' ')"
    } else {
      $res = Invoke-Git -TimeoutSec $FetchTimeout -GitArgs (@('fetch') + $fetchArgs)
      if ($res.ExitCode -eq 124) {
        Write-Fail "$Name`: git fetch timed out after ${FetchTimeout}s"
        return 1
      } elseif ($res.ExitCode -ne 0) {
        Write-Fail "$Name`: git fetch failed ($(Format-Note $res.StdErr))"
        return 1
      }
    }

    # Remote default branch must exist after fetching.
    if (-not (Test-GitRef "refs/remotes/origin/$branch")) {
      Write-Skip "$Name`: origin/$branch does not exist, skipping"
      return 10
    }

    # Dirty? `git status --porcelain` covers staged, unstaged AND untracked.
    if ((Invoke-Git 'status' '--porcelain').StdOut.Trim()) {
      Write-Ok "$Name`: dirty -> fetched only ($branch left untouched)"
      return 20
    }

    if ($DryRun) {
      Write-Info "$Name`: [dry-run] would fast-forward '$branch' to 'origin/$branch'"
      return 30
    }

    $current = (Invoke-Git 'branch' '--show-current').StdOut.Trim()

    if ($current -eq $branch) {
      # On the default branch: merge the fetched remote (ff-only, never creates a merge commit).
      $before = (Invoke-Git 'rev-parse' 'HEAD').StdOut.Trim()
      $merge = Invoke-Git -TimeoutSec $FetchTimeout 'merge' '--ff-only' "origin/$branch"
      if ($merge.ExitCode -ne 0) {
        Write-Fail "$Name`: $branch cannot fast-forward (diverged?), left untouched"
        return 1
      }
      $after = (Invoke-Git 'rev-parse' 'HEAD').StdOut.Trim()
      if ($before -eq $after) {
        Write-Info "$Name`: already up to date ($branch)"
        return 30
      }
      Write-Ok "$Name`: updated $branch ($before -> $after)"
      $script:Updated.Add([pscustomobject]@{ Name = $Name; Dir = $Dir; Branch = $branch; Before = $before; After = $after })
      return 0
    }

    # On another branch (or detached): move the local default branch ref
    # forward without checking it out. `git fetch origin <src>:<dst>` only
    # succeeds on a fast-forward, so it never force-clobbers work.
    $where = if ($current) { "on '$current'" } else { 'detached HEAD' }
    $before = (Invoke-Git 'rev-parse' $branch).StdOut.Trim()
    $res = Invoke-Git -TimeoutSec $FetchTimeout 'fetch' 'origin' "${branch}:${branch}"
    if ($res.ExitCode -eq 124) {
      Write-Fail "$Name`: git fetch timed out after ${FetchTimeout}s, left untouched ($where)"
      return 1
    } elseif ($res.ExitCode -eq 0) {
      $after = (Invoke-Git 'rev-parse' $branch).StdOut.Trim()
      if ($before -eq $after) {
        Write-Info "$Name`: already up to date ($branch, $where)"
        return 30
      }
      Write-Ok "$Name`: updated $branch ($before -> $after; $where, checkout untouched)"
      $script:Updated.Add([pscustomobject]@{ Name = $Name; Dir = $Dir; Branch = $branch; Before = $before; After = $after })
      return 0
    }

    # Fetch of <src>:<dst> is a no-op success when already equal, so reaching
    # here means non-fast-forward (local ahead/diverged).
    if ((Invoke-Git 'merge-base' '--is-ancestor' $branch "origin/$branch").ExitCode -eq 0) {
      Write-Info "$Name`: already up to date ($branch, $where)"
      return 30
    }
    Write-Fail "$Name`: $branch diverged from origin/$branch, left untouched ($where)"
    return 1
  } finally {
    Pop-Location
  }
}

# --- main ------------------------------------------------------------------------

$script:Counters = @{
  updated = 0; uptodate = 0; fetched = 0; failed = 0; skipped = 0
  ciGreen = 0; ciRed = 0; ciPending = 0; ciNone = 0; ciUnknown = 0; ciChecked = 0
}
$script:Updated = [System.Collections.Generic.List[object]]::new()
$script:Bad     = [System.Collections.Generic.List[object]]::new()

if ($CheckCi -and -not (Get-Command $GhBin -ErrorAction SilentlyContinue)) {
  Write-Skip "'$GhBin' not found on PATH -- skipping default-branch CI checks"
  $CheckCi = $false
}

foreach ($child in (Get-ChildItem -LiteralPath $CodeDir -Directory -Force | Sort-Object Name)) {
  $dir = $child.FullName
  $name = $child.Name

  # Not a repo (covers dirs; worktree-linked repos use a .git file too).
  if (-not (Test-Path -LiteralPath (Join-Path $dir '.git'))) { continue }

  $rc = Invoke-RepoUpdate -Name $name -Dir $dir

  switch ($rc) {
    0  { $script:Counters.updated++ }
    20 { $script:Counters.fetched++ }
    30 { $script:Counters.uptodate++ }
    10 { $script:Counters.skipped++ }
    default { $script:Counters.failed++ }
  }

  # Is the (freshly fetched) default branch of this repo green? Skipped for
  # repos we can't identify a remote branch for, and in dry-run (no fetch ran).
  if ($CheckCi -and -not $DryRun -and $rc -ne 10 -and $rc -ne 1) {
    Push-Location -LiteralPath $dir
    try {
      $ciBranch = Get-DefaultBranch
      if ($ciBranch -and (Test-GitRef "refs/remotes/origin/$ciBranch")) {
        $ciSha = (Invoke-Git 'rev-parse' "refs/remotes/origin/$ciBranch").StdOut.Trim()
        if ($ciSha) {
          $script:Counters.ciChecked++
          Invoke-CiCheck -Name $name -Slug (Get-GitHubSlug) -Sha $ciSha -Branch $ciBranch
        }
      }
    } finally {
      Pop-Location
    }
  }
}

$exitCode = if ($script:Counters.failed -eq 0) { 0 } else { 1 }

Write-Host '---'
Write-Host ("updated={0} up-to-date={1} fetched-only(dirty)={2} skipped={3} failed={4}" -f `
  $script:Counters.updated, $script:Counters.uptodate, $script:Counters.fetched, `
  $script:Counters.skipped, $script:Counters.failed)

if ($CheckCi -and -not $DryRun -and $script:Counters.ciChecked -gt 0) {
  Write-Host ("ci: green={0} red={1} pending={2} none={3} unknown={4}" -f `
    $script:Counters.ciGreen, $script:Counters.ciRed, $script:Counters.ciPending, `
    $script:Counters.ciNone, $script:Counters.ciUnknown)
  if ($script:Bad.Count -gt 0) {
    Write-Host '--- default branches not green ---'
    foreach ($entry in $script:Bad) {
      $color = switch ($entry.Tag) { 'RED' { 'Red' } 'PENDING' { 'Yellow' } default { 'DarkGray' } }
      Write-CiLine $color $entry.Tag "$($entry.Name) ($($entry.Branch)): $($entry.Detail)"
    }
  }
}

if ($Summarize) {
  if ($DryRun) {
    Write-Info "[dry-run] would run '$MuseBin exec' on each updated repo for change summaries"
  } elseif ($script:Updated.Count -eq 0) {
    Write-Info 'No repos updated -- nothing to summarize.'
  } elseif (-not (Get-Command $MuseBin -ErrorAction SilentlyContinue)) {
    Write-Skip "'$MuseBin' not found on PATH -- skipping change summaries"
  } else {
    Invoke-Summarize -Repos $script:Updated.ToArray()
  }
}

exit $exitCode
