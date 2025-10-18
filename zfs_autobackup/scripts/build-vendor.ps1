# build-vendor.ps1
param(
  [string[]]$Packages = @('colorama','coverage','coveralls'),
  [string]$PkgsDir = ".\pkgs",
  [string]$VendorDir = ".\vendor"
)

$ErrorActionPreference = "Stop"

function Get-PythonCmd {
  $candidates = @(
    @('py','-3'),
    @('py'),
    @('python'),
    @('python3')
  )
  foreach ($cand in $candidates) {
    try {
      & $cand -c 'import sys; print(sys.version)' | Out-Null
      if ($LASTEXITCODE -eq 0) { return $cand }
    } catch {}
  }
  throw "No Python interpreter found. Install Python 3 first."
}

function New-CleanDir([string]$Path) {
  if (Test-Path $Path) { Remove-Item -Recurse -Force $Path }
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Expand-AnyArchive([string]$ArchivePath, [string]$DestDir) {
  $lower = $ArchivePath.ToLowerInvariant()
  if ($lower -match '\.tar\.gz$' -or $lower -match '\.tgz$') {
    tar -xf $ArchivePath -C $DestDir
  } elseif ($lower.EndsWith('.whl') -or $lower.EndsWith('.zip')) {
    Expand-Archive -Path $ArchivePath -DestinationPath $DestDir -Force
  } else {
    Write-Warning "Skipping unknown archive: $ArchivePath"
  }
}

function MatchesAny([string]$Text, [string[]]$Patterns) {
  $norm = ($Text -replace '\\','/').ToLowerInvariant()
  foreach ($p in $Patterns) { if ($norm -match $p) { return $true } }
  return $false
}

function Copy-PythonPackages([string]$SrcRoot, [string]$VendorDest) {
  $excludePatterns = @('(^|/)(tests?|testing|docs?|examples?|demo|contrib|benchmarks?)(/|$)')

  # 1) Package directories (contain __init__.py)
  Get-ChildItem -Path $SrcRoot -Recurse -Directory | ForEach-Object {
    $pkgDir = $_.FullName
    $init = Join-Path $pkgDir "__init__.py"
    if (Test-Path $init) {
      if (-not (MatchesAny $pkgDir $excludePatterns)) {
        $name = Split-Path $pkgDir -Leaf
        $dest = Join-Path $VendorDest $name
        if (-not (Test-Path $dest)) {
          Copy-Item -Recurse -Force $pkgDir $dest
        }
      }
    }
  }

  # 2) Single-file modules at top/root or under src/
  Get-ChildItem -Path $SrcRoot -Recurse -Filter *.py | ForEach-Object {
    $full = $_.FullName
    if (MatchesAny $full $excludePatterns) { return }
    $dir = $_.DirectoryName
    $parent = Split-Path $dir -Leaf
    $grand  = Split-Path (Split-Path $dir -Parent) -Leaf
    $isTopish = ($dir -eq $SrcRoot -or $parent -eq 'src' -or $grand -eq 'src')
    if ($isTopish) {
      $dest = Join-Path $VendorDest (Split-Path $full -Leaf)
      if (-not (Test-Path $dest)) {
        Copy-Item -Force $full $dest
      }
    }
  }

  # 3) Keep metadata (optional but harmless)
  Get-ChildItem -Path $SrcRoot -Recurse -Directory -Filter "*.dist-info" -ErrorAction SilentlyContinue | ForEach-Object {
    $dest = Join-Path $VendorDest (Split-Path $_.FullName -Leaf)
    if (-not (Test-Path $dest)) {
      Copy-Item -Recurse -Force $_.FullName $dest
    }
  }
}

# --- Main ---
$pythonCmd = Get-PythonCmd
Write-Host "Using Python: $($pythonCmd -join ' ')" -ForegroundColor Cyan

New-CleanDir $PkgsDir
New-CleanDir $VendorDir

$tempRoot = Join-Path $env:TEMP ("pyvend_" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Write-Host "Downloading source dists for: $($Packages -join ', ')" -ForegroundColor Cyan
  & $pythonCmd -m pip install --upgrade pip
  & $pythonCmd -m pip download --no-binary=:all: --dest $PkgsDir @Packages

  Write-Host "Expanding archives..." -ForegroundColor Cyan
  $extractionRoot = Join-Path $tempRoot "extract"
  New-Item -ItemType Directory -Path $extractionRoot | Out-Null

  Get-ChildItem $PkgsDir | ForEach-Object {
    $pkgTmp = Join-Path $extractionRoot ([System.IO.Path]::GetFileNameWithoutExtension($_.Name) + "_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $pkgTmp | Out-Null
    Expand-AnyArchive $_.FullName $pkgTmp
    Copy-PythonPackages -SrcRoot $pkgTmp -VendorDest $VendorDir
  }

  Write-Host "`nDone. Vendored packages are in: $VendorDir" -ForegroundColor Green
  Write-Host "On TrueNAS (same folder as vendor):" -ForegroundColor Yellow
  Write-Host '  # Option A: set PYTHONPATH' -ForegroundColor DarkYellow
  Write-Host '  PYTHONPATH=./vendor python3 your_script.py' -ForegroundColor DarkYellow
  Write-Host '  # Option B: add bootstrap at top of your_script.py:' -ForegroundColor DarkYellow
  Write-Host '  import os, sys; sys.path.insert(0, os.path.join(os.path.dirname(__file__), "vendor"))' -ForegroundColor DarkYellow
}
finally {
  if (Test-Path $tempRoot) { Remove-Item -Recurse -Force $tempRoot }
}
