@echo off
rem Death Muffin lighting bake helper (client/addons/dm_bake/README.md). Double-click it: it downloads Godot and the game files it needs,
rem bakes the area lighting on this PC's graphics card and leaves a zip on the Desktop to send back on Discord. Nothing is installed.
title Death Muffin lighting bake
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = Get-Content -LiteralPath '%~f0' -Raw; Invoke-Expression $s.Substring($s.IndexOf('#' + 'POWERSHELL'))"
echo.
pause
exit /b
#POWERSHELL
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # the download progress bar makes Invoke-WebRequest many times slower
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Site = 'https://muffindevelopment.com/death-muffin/bake-kit/'
$Work = Join-Path $env:LOCALAPPDATA 'DeathMuffin\bake'
function Say([string]$m) { Write-Host $m -ForegroundColor Cyan }
function Fail([string]$m) {
  Write-Host ''
  Write-Host ('Something went wrong: ' + $m) -ForegroundColor Red
  Write-Host 'Send a screenshot of this window to Claude on Discord. Nothing on this PC was changed besides the bake folder:' -ForegroundColor Yellow
  Write-Host ('  ' + $Work)
  exit 1
}
function Fetch([string]$url, [string]$file, [string]$algo, [string]$hash, [string]$what) {
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $file
  if ((Get-FileHash -LiteralPath $file -Algorithm $algo).Hash.ToLower() -ne $hash.ToLower()) {
    Remove-Item -LiteralPath $file -Force
    Fail ($what + ' did not download correctly (checksum mismatch). Try again in a minute.')
  }
}
try {
  Say 'Death Muffin lighting bake helper'
  New-Item -ItemType Directory -Force -Path $Work | Out-Null
  # Self-contained mode: this Godot keeps its settings in the bake folder and never touches a Godot already on this PC.
  New-Item -ItemType File -Force -Path (Join-Path $Work '._sc_') | Out-Null
  $kit = Invoke-RestMethod -UseBasicParsing -Uri ($Site + 'latest.json?t=' + [DateTime]::UtcNow.Ticks)
  Say ('Bake kit: build ' + $kit.rev + ', ' + ($kit.scenes -join ', '))

  # Godot 4.7.2, the official build, checked against its published SHA-512.
  $godot = Join-Path $Work $kit.godot.exe
  if (-not (Test-Path -LiteralPath $godot)) {
    Say ('Downloading Godot ' + $kit.godot.version + ' (about 70 MB)...')
    $zip = Join-Path $Work 'godot.zip'
    Fetch $kit.godot.url $zip 'SHA512' $kit.godot.sha512 'Godot'
    Expand-Archive -LiteralPath $zip -DestinationPath $Work -Force
    Remove-Item -LiteralPath $zip -Force
  }

  # The game files at this build: the client project, its import cache and the Windows combat core.
  $kitDir = Join-Path $Work ('kit-' + $kit.rev)
  $project = Join-Path $kitDir 'client'
  if (-not (Test-Path -LiteralPath (Join-Path $project 'project.godot'))) {
    Get-ChildItem -LiteralPath $Work -Directory -Filter 'kit-*' | Remove-Item -Recurse -Force   # older kits
    Say ('Downloading the game files (about ' + $kit.mb + ' MB)...')
    $zip = Join-Path $Work 'kit.zip'
    Fetch ($Site + $kit.file) $zip 'SHA256' $kit.sha256 'The game files'
    Say 'Unpacking...'
    Expand-Archive -LiteralPath $zip -DestinationPath $kitDir -Force
    Remove-Item -LiteralPath $zip -Force
  }

  Say 'Checking the game files (the first time can take a few minutes)...'
  $p = Start-Process -FilePath $godot -ArgumentList @('--headless', '--path', ('"' + $project + '"'), '--import') -Wait -PassThru -WindowStyle Hidden
  if ($p.ExitCode -ne 0) { Fail ('Godot could not open the game files (exit ' + $p.ExitCode + ').') }

  Say 'Baking the lighting on your graphics card. A Godot window opens and closes by itself: please do not click in it.'
  $result = Join-Path $Work ('result-' + $kit.rev + '.json')
  if (Test-Path -LiteralPath $result) { Remove-Item -LiteralPath $result -Force }
  $started = Get-Date
  $bakeArgs = @('--path', ('"' + $project + '"'), '--editor', '--', ('--dm-bake=' + ($kit.scenes -join ',')), ('--dm-bake-result="' + $result + '"'))
  $p = Start-Process -FilePath $godot -ArgumentList $bakeArgs -Wait -PassThru
  if (-not (Test-Path -LiteralPath $result)) { Fail ('the bake did not finish (Godot exit ' + $p.ExitCode + ').') }
  $r = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
  if (-not $r.ok) {
    $why = ($r.scenes | Where-Object { -not $_.ok } | ForEach-Object { $_.scene + ': ' + $_.error }) -join '; '
    Fail ('the bake failed: ' + $why)
  }

  # What goes back: each baked scene's lightmap data and images (with Godot's import settings for them), and the result.
  $files = @($result)
  foreach ($scene in $kit.scenes) {
    $rel = $scene.Substring('res://'.Length)
    $dir = Join-Path $project (Split-Path $rel -Parent)
    $base = [IO.Path]::GetFileNameWithoutExtension($rel)
    $files += Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -like ($base + '.lmbake') -or $_.Name -like ($base + '*.exr') -or $_.Name -like ($base + '*.exr.import') -or $_.Name -like ($base + '*.png') -or $_.Name -like ($base + '*.png.import') } | ForEach-Object { $_.FullName }
  }
  $out = Join-Path ([Environment]::GetFolderPath('Desktop')) ('DeathMuffin-bake-' + $kit.rev + '.zip')
  Compress-Archive -LiteralPath $files -DestinationPath $out -Force
  $mins = [Math]::Round(((Get-Date) - $started).TotalMinutes, 1)
  Write-Host ''
  Write-Host ('Done in ' + $mins + ' min on ' + $r.gpu + '.') -ForegroundColor Green
  Write-Host 'Drag this file from your Desktop into your Discord DM with Muffin Core:' -ForegroundColor Green
  Write-Host ('  ' + $out)
  Start-Process explorer.exe -ArgumentList ('/select,"' + $out + '"')
} catch {
  Fail $_.Exception.Message
}
