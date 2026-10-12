# Keeps Spotify's window translucent on Windows. Installed and started by
# install-windows.ps1; runs hidden at login. Reads the opacity from
# %APPDATA%\SpotifyTranslucency\config.json every couple of seconds, so a new
# value applies live, and exits on its own once that file is removed (uninstall).
$ErrorActionPreference = 'SilentlyContinue'
$config = Join-Path $env:APPDATA 'SpotifyTranslucency\config.json'

$mutex = New-Object System.Threading.Mutex($false, 'Local\SpotifyTranslucencyHelper')
try { $owned = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $owned = $true }  # previous helper was killed
if (-not $owned) { exit }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class SpotifyGlass {
    delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongW")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    [DllImport("user32.dll")] static extern bool GetLayeredWindowAttributes(IntPtr hwnd, out uint key, out byte alpha, out uint flags);
    [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint key, byte alpha, uint flags);

    const int GWL_EXSTYLE = -20;
    const int WS_EX_LAYERED = 0x80000;
    const uint LWA_ALPHA = 0x2;

    public static void Apply(int[] pids, byte alpha) {
        var owned = new HashSet<uint>();
        foreach (var p in pids) owned.Add((uint)p);
        EnumWindows(delegate (IntPtr hwnd, IntPtr lParam) {
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            if (!owned.Contains(pid) || !IsWindowVisible(hwnd) || GetWindowTextLength(hwnd) == 0) return true;
            var cls = new StringBuilder(256);
            GetClassName(hwnd, cls, cls.Capacity);
            if (!cls.ToString().StartsWith("Chrome_WidgetWin")) return true;

            int ex = GetWindowLong(hwnd, GWL_EXSTYLE);
            if (alpha == 255) {
                if ((ex & WS_EX_LAYERED) != 0) SetWindowLong(hwnd, GWL_EXSTYLE, ex & ~WS_EX_LAYERED);
                return true;
            }
            uint key, flags; byte current;
            if ((ex & WS_EX_LAYERED) != 0 && GetLayeredWindowAttributes(hwnd, out key, out current, out flags)
                && (flags & LWA_ALPHA) != 0 && current == alpha) return true;
            SetWindowLong(hwnd, GWL_EXSTYLE, ex | WS_EX_LAYERED);
            SetLayeredWindowAttributes(hwnd, 0, alpha, LWA_ALPHA);
            return true;
        }, IntPtr.Zero);
    }
}
'@

while (Test-Path $config) {
    $opacity = [int]((Get-Content $config -Raw | ConvertFrom-Json).Opacity)
    if ($opacity -ge 10 -and $opacity -le 100) {
        $alpha = [byte][math]::Round($opacity * 255 / 100)
        $pids = @(Get-Process -Name Spotify -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        if ($pids.Count -gt 0) { [SpotifyGlass]::Apply([int[]]$pids, $alpha) }
    }
    Start-Sleep -Seconds 2
}
