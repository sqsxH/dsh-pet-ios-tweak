#requires -Version 5.1
<#
  drive_github.ps1 - Push dsh-pet iOS tweak sources to GitHub, trigger the
  macOS cloud build (GitHub Actions), wait for it, and download the .deb.

  Token handling: do NOT put the token in this file or in chat. Set an env var
  in your own terminal first:
      $env:GITHUB_TOKEN = 'github_pat_xxxx'
  Revoke/rotate the token on GitHub after use.

  Usage:
    .\drive_github.ps1 -Owner <user> -Repo <repo> -CreateRepo
#>
param(
  [Parameter(Mandatory=$true)][string]$Owner,
  [Parameter(Mandatory=$true)][string]$Repo,
  [switch]$CreateRepo,
  [string]$WorkflowFile = 'build-tweak.yml',
  [int]$PollSeconds = 20,
  [int]$MaxWaitSeconds = 1800,
  [string]$OutDir = '.'
)

$ErrorActionPreference = 'Stop'
$token = $env:GITHUB_TOKEN
if (-not $token) { throw 'Set env var GITHUB_TOKEN first (fine-grained PAT with Contents/Workflows/Actions access).' }

$headers = @{
  'Authorization' = 'Bearer ' + $token
  'Accept' = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
  'User-Agent' = 'dsh-pet-tweak-driver'
}

function Invoke-Gh {
  param([string]$Method, [string]$Path, $Body = $null)
  $splat = @{ Method = $Method; Uri = ('https://api.github.com' + $Path); Headers = $headers; TimeoutSec = 60 }
  if ($null -ne $Body) {
    $splat.Body = ($Body | ConvertTo-Json -Depth 30 -Compress)
    $splat.ContentType = 'application/json'
  }
  try { return Invoke-RestMethod @splat }
  catch {
    $msg = $_.Exception.Message
    if ($_.ErrorDetails.Message) { $msg = $msg + ' | ' + $_.ErrorDetails.Message }
    throw ('GitHub API ' + $Method + ' ' + $Path + ' failed: ' + $msg)
  }
}

# Preflight + ensure repo exists
$me = Invoke-Gh -Method GET -Path '/user'
Write-Host ('[preflight] token OK, login=' + $me.login)

try {
  $info = Invoke-Gh -Method GET -Path ('/repos/' + $Owner + '/' + $Repo)
  Write-Host ('[repo] exists: ' + $Owner + '/' + $Repo)
} catch {
  if (-not $CreateRepo) { throw 'Repo not found; add -CreateRepo to create it.' }
  Write-Host '[repo] creating repo (auto_init=true)...'
  Invoke-Gh -Method POST -Path '/user/repos' -Body @{ name = $Repo; private = $false; auto_init = $true } | Out-Null
  $info = Invoke-Gh -Method GET -Path ('/repos/' + $Owner + '/' + $Repo)
}
$Branch = $info.default_branch
Write-Host ('[repo] branch=' + $Branch)

# Collect local files to push (skip temp/generated)
$toolsDir = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent $toolsDir
$paths = @('README.md', '.github/workflows/build-tweak.yml')
foreach ($d in @('docs', 'tweak', 'tools/transcode-webm', 'tools/package-deb')) {
  $abs = Join-Path $projectRoot $d
  if (Test-Path -LiteralPath $abs) {
    Get-ChildItem -LiteralPath $abs -File -Recurse -Force | ForEach-Object {
      $paths += $_.FullName.Substring($projectRoot.Length).TrimStart([char]92, [char]47).Replace([char]92, '/')
    }
  }
}
$paths = $paths | Where-Object { $_ -notmatch '__pycache__|_yamlcheck|\.pyc$|\.deb$|\.zip$|\.log$|\.tmp$' } | Sort-Object -Unique

foreach ($rel in $paths) {
  $local = Join-Path $projectRoot ($rel.Replace('/', [string][char]92))
  if (-not (Test-Path -LiteralPath $local)) { Write-Warning ('skip missing file: ' + $rel); continue }
  $apiPath = '/repos/' + $Owner + '/' + $Repo + '/contents/' + $rel + '?ref=' + $Branch
  $bytes = [System.IO.File]::ReadAllBytes($local)
  $b64 = [Convert]::ToBase64String($bytes)
  $sha = $null
  try { $sha = (Invoke-Gh -Method GET -Path $apiPath).sha } catch { }
  $body = @{ message = ('import dsh-pet iOS tweak sources: ' + $rel); content = $b64; branch = $Branch }
  if ($sha) { $body['sha'] = $sha }
  Invoke-Gh -Method PUT -Path ('/repos/' + $Owner + '/' + $Repo + '/contents/' + $rel) -Body $body | Out-Null
  Write-Host ('[push] ' + $rel)
}

# Trigger workflow_dispatch
$before = ((Invoke-Gh -Method GET -Path ('/repos/' + $Owner + '/' + $Repo + '/actions/runs?per_page=1')).workflow_runs | Select-Object -First 1).id
Invoke-Gh -Method POST -Path ('/repos/' + $Owner + '/' + $Repo + '/actions/workflows/' + $WorkflowFile + '/dispatches') -Body @{ ref = $Branch } | Out-Null
Write-Host '[dispatch] workflow_dispatch triggered'

# Locate the run
$runId = $null
$findDeadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $findDeadline) {
  Start-Sleep -Seconds 5
  $latest = (Invoke-Gh -Method GET -Path ('/repos/' + $Owner + '/' + $Repo + '/actions/runs?per_page=10')).workflow_runs |
    Where-Object { $_.id -gt $before } | Sort-Object id -Descending | Select-Object -First 1
  if ($latest) { $runId = $latest.id; break }
}
if (-not $runId) { throw 'Could not locate the run. Check that the workflow is enabled and the token has Actions access.' }
Write-Host ('[run] id=' + $runId)

# Wait for completion
$deadline = (Get-Date).AddSeconds($MaxWaitSeconds)
$run = $null
while ((Get-Date) -lt $deadline) {
  $run = Invoke-Gh -Method GET -Path ('/repos/' + $Owner + '/' + $Repo + '/actions/runs/' + $runId)
  Write-Host ('[run] status=' + $run.status + ' conclusion=' + $run.conclusion)
  if ($run.status -eq 'completed') { break }
  Start-Sleep -Seconds $PollSeconds
}
if (-not $run -or $run.status -ne 'completed') { throw ('Build timed out; see ' + $run.html_url) }
if ($run.conclusion -ne 'success') { throw ('Build not successful: ' + $run.conclusion + '; see ' + $run.html_url) }

# Download and unzip the .deb
$arts = Invoke-Gh -Method GET -Path ('/repos/' + $Owner + '/' + $Repo + '/actions/runs/' + $runId + '/artifacts')
$art = $arts.artifacts | Where-Object { $_.name -like '*arm64e*' } | Select-Object -First 1
if (-not $art) { $art = $arts.artifacts | Select-Object -First 1 }
if (-not $art) { throw 'Build succeeded but no artifact found (check upload-artifact step).' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$zipPath = Join-Path $OutDir ('dshpet-artifact-' + $runId + '.zip')
Invoke-WebRequest -Uri ('https://api.github.com/repos/' + $Owner + '/' + $Repo + '/actions/artifacts/' + $art.id + '/zip') -Headers $headers -OutFile $zipPath -TimeoutSec 300
Write-Host ('[artifact] ' + $zipPath)
$exDir = Join-Path $OutDir ('dshpet-artifact-' + $runId)
Expand-Archive -Path $zipPath -DestinationPath $exDir -Force
Get-ChildItem -LiteralPath $exDir -Recurse -Filter '*.deb' | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination $OutDir -Force
  Write-Host ('[deb] ' + (Join-Path $OutDir $_.Name))
}

Write-Host ''
Write-Host 'Next, on the iPhone 12 (rootless):'
Write-Host '  scp the.deb root@IP:~/dshpet.deb'
Write-Host '  ssh root@IP dpkg -i ~/dshpet.deb'
Write-Host '  ssh root@IP killall -9 SpringBoard'
