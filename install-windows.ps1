<#
Spotify translucency installer for Windows.

  .\install-windows.ps1                 install / repair (uses saved opacity, default 79)
  .\install-windows.ps1 -Opacity 70     set window opacity in percent (saved for next time)
  .\install-windows.ps1 -Uninstall      restore the original Spotify files and settings

If scripts are blocked, run:  powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
or double-click install-windows.cmd.

Two parts:
  1. Patches Spotify's UI bundle (Apps\xpui.spa) with spotify-translucency.css,
     which removes the album-art tint/gradients so the window is one flat colour.
  2. Installs a small hidden helper (started at login) that makes the Spotify
     window itself translucent using the Win32 layered-window API.
#>
param(
    [ValidateRange(10, 100)][int]$Opacity = 0,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$Here       = $PSScriptRoot
$CssSrc     = Join-Path $Here 'spotify-translucency.css'
$HelperSrc  = Join-Path $Here 'windows-opacity-helper.ps1'
$CssName    = 'spotify-translucency.css'
$Link       = "<link href=`"/$CssName`" rel=`"stylesheet`">"
$ConfigDir  = Join-Path $env:APPDATA 'SpotifyTranslucency'
$Config     = Join-Path $ConfigDir 'config.json'
$Helper     = Join-Path $ConfigDir 'windows-opacity-helper.ps1'
$Shortcut   = Join-Path ([Environment]::GetFolderPath('Startup')) 'Spotify Translucency.lnk'
$SpotifyDir = Join-Path $env:APPDATA 'Spotify'
$Spa        = Join-Path $SpotifyDir 'Apps\xpui.spa'
$Backup     = "$Spa.translucency-backup"
$Utf8       = New-Object System.Text.UTF8Encoding($false)
$DefaultOpacity = 79

function Info($msg) { Write-Host "==> $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "warning: $msg" -ForegroundColor Yellow }

# ------------------------------------------------------------ zip helpers
function Read-ZipText([string]$zipPath, [string]$name) {
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entry = $zip.GetEntry($name)
        if (-not $entry) { return $null }
        $reader = New-Object IO.StreamReader($entry.Open(), $Utf8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}

function Write-ZipText($zip, [string]$name, [string]$text) {
    $old = $zip.GetEntry($name)
    if ($old) { $old.Delete() }
    $writer = New-Object IO.StreamWriter($zip.CreateEntry($name).Open(), $Utf8)
    try { $writer.Write($text) } finally { $writer.Dispose() }
}

function Test-Patched([string]$zipPath) {
    $html = Read-ZipText $zipPath 'index.html'
    return ($html -and $html.Contains($CssName))
}

function New-PatchedSpa([string]$src, [string]$dst) {
    Copy-Item $src $dst -Force
    $zip = [IO.Compression.ZipFile]::Open($dst, 'Update')
    try {
        $entry = $zip.GetEntry('index.html')
        $reader = New-Object IO.StreamReader($entry.Open(), $Utf8)
        try { $html = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if (-not $html.Contains($CssName)) {
            if (-not $html.Contains('</head>')) { throw 'Unexpected Spotify layout (index.html has no </head>).' }
            $i = $html.IndexOf('</head>')
            $html = $html.Substring(0, $i) + $Link + $html.Substring($i)
        }
        Write-ZipText $zip 'index.html' $html
        Write-ZipText $zip $CssName ([IO.File]::ReadAllText($CssSrc, $Utf8))
    } finally { $zip.Dispose() }
}

# ------------------------------------------------------ stop / start Spotify
$script:WasRunning = $false
function Stop-Spotify {
    $procs = Get-Process -Name Spotify -ErrorAction SilentlyContinue
    if (-not $procs) { return }
    $script:WasRunning = $true
    $procs | Stop-Process -Force
    for ($i = 0; $i -lt 30 -and (Get-Process -Name Spotify -ErrorAction SilentlyContinue); $i++) {
        Start-Sleep -Milliseconds 300
    }
}

function Start-Spotify {
    if (-not $script:WasRunning) { return }
    Info 'Restarting Spotify'
    Start-Process (Join-Path $SpotifyDir 'Spotify.exe')
}

# ------------------------------------------------------- opacity helper
function Stop-Helper {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*windows-opacity-helper.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Install-Helper {
    Copy-Item $HelperSrc $Helper -Force
    $helperArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Helper`""
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Shortcut)
    $lnk.TargetPath = Join-Path $PSHOME 'powershell.exe'
    $lnk.Arguments = $helperArgs
    $lnk.WindowStyle = 7
    $lnk.Description = 'Keeps the Spotify window translucent'
    $lnk.Save()
    # Restart so an updated helper script takes effect.
    Stop-Helper
    Start-Process (Join-Path $PSHOME 'powershell.exe') -ArgumentList $helperArgs -WindowStyle Hidden
}

# ------------------------------------------------------------------ main
if (-not (Test-Path $Spa)) {
    if (Get-AppxPackage -Name '*SpotifyMusic*' -ErrorAction SilentlyContinue) {
        throw 'This is the Microsoft Store version of Spotify, whose files cannot be modified. Uninstall it and install the desktop version from https://www.spotify.com/download/windows/ then run this again.'
    }
    throw "Could not find Spotify at $Spa. Install the desktop version from https://www.spotify.com/download/windows/"
}
Info "Found Spotify UI bundle: $Spa"

if ($Uninstall) {
    Remove-Item $Config -ErrorAction SilentlyContinue   # makes a running helper exit
    Stop-Helper
    Remove-Item $Shortcut, $Helper -ErrorAction SilentlyContinue
    if (Test-Path $Backup) {
        Stop-Spotify
        Copy-Item $Backup $Spa -Force
        Remove-Item $Backup
        Info "Restored original $Spa"
    } elseif (Test-Patched $Spa) {
        Warn "No backup found at $Backup; reinstall Spotify to fully remove the patch."
    }
    Start-Spotify
    Info 'Uninstalled.'
    return
}

foreach ($f in $CssSrc, $HelperSrc) {
    if (-not (Test-Path $f)) { throw "Missing $f (keep install-windows.ps1 next to the other files)." }
}

if ($Opacity -eq 0) {
    $Opacity = $DefaultOpacity
    if (Test-Path $Config) {
        $saved = [int]((Get-Content $Config -Raw | ConvertFrom-Json).Opacity)
        if ($saved -ge 10 -and $saved -le 100) { $Opacity = $saved }
    }
}

# 1. Patch the UI bundle
$css = [IO.File]::ReadAllText($CssSrc, $Utf8)
if ((Test-Patched $Spa) -and ((Read-ZipText $Spa $CssName) -eq $css)) {
    Info 'Spotify UI already patched with the current stylesheet'
} else {
    $src = $Spa
    if (Test-Patched $Spa) {
        # Re-patch from the pristine copy when we have one, so the CSS is refreshed.
        if ((Test-Path $Backup) -and -not (Test-Patched $Backup)) { $src = $Backup }
    } else {
        # Fresh install, or Spotify updated and replaced our patch: refresh backup.
        Info "Backing up original to $Backup"
        Copy-Item $Spa $Backup -Force
    }
    $tmp = [IO.Path]::GetTempFileName()
    New-PatchedSpa $src $tmp
    Stop-Spotify
    Copy-Item $tmp $Spa -Force
    Remove-Item $tmp
    Info "Patched $Spa"
}

# 2. Save the opacity and start the window helper
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
[IO.File]::WriteAllText($Config, (@{ Opacity = $Opacity } | ConvertTo-Json), $Utf8)
Info "Saved opacity $Opacity% to $Config"
Install-Helper
Info 'Window opacity helper installed (starts automatically at login)'

Start-Spotify
Info 'Done. Re-run this script after Spotify updates to re-apply the patch.'
