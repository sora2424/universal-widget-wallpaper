# 万能ウィジェット壁紙 - 操作ヘルパー v7
# 壁紙から http://localhost:39217/<command> を受け取って、次のことだけを行います。
#   - メディア操作（再生/一時停止・次へ・前へ・シーク）と音量
#   - フォルダ / Webサイトを開く（プログラムの実行はできません）
#   - CPU・GPU・メモリ・ディスク・ネットワーク・バッテリーなどの状態を返す
#   - 設定エディタ（ブラウザ）を表示し、設定を保存する
# 安全のしくみ:
#   - 自分のPC（localhost）からの接続だけを受け付けます（Host ヘッダーも確認）
#   - 起動のたびに秘密の合言葉（トークン）を作り、ユーザーが「接続する」と許可した壁紙フォルダにだけ渡します
#   - 合言葉を持たない命令（ほかのWebサイトなど）はすべて拒否します

$port = 39217
# 配布者へ: ワークショップ公開後、その作品IDをここに入れると、その壁紙は確認なしで接続されます（例: @('3123456789')）
$OfficialWorkshopIds = @('3834059703')

$mutex = New-Object System.Threading.Mutex($false, "Global\UniversalWidgetWallpaperHelper")
if (-not $mutex.WaitOne(0)) { exit }

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class UwwSys {
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    public static void Tap(byte vk) { keybd_event(vk, 0, 1, UIntPtr.Zero); keybd_event(vk, 0, 3, UIntPtr.Zero); }

    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    static long pIdle, pTotal;
    public static double Cpu() {
        long i, k, u; GetSystemTimes(out i, out k, out u);
        long t = k + u, di = i - pIdle, dt = t - pTotal; pIdle = i; pTotal = t;
        if (dt <= 0) return 0; return Math.Round((1.0 - (double)di / dt) * 100.0, 1);
    }
    [StructLayout(LayoutKind.Sequential)]
    public class MEMSTAT { public uint len = (uint)Marshal.SizeOf(typeof(MEMSTAT)); public uint load; public ulong total; public ulong avail;
        public ulong tp; public ulong ap; public ulong tv; public ulong av; public ulong ave; }
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx([In, Out] MEMSTAT m);
    public static ulong[] Mem() { var m = new MEMSTAT(); GlobalMemoryStatusEx(m); return new ulong[] { m.total, m.avail }; }
    [StructLayout(LayoutKind.Sequential)]
    public struct PWR { public byte ac; public byte flag; public byte pct; public byte r; public int life; public int full; }
    [DllImport("kernel32.dll")] static extern bool GetSystemPowerStatus(out PWR p);
    public static int[] Power() { PWR p; GetSystemPowerStatus(out p); bool none = (p.flag & 128) != 0 || p.pct == 255;
        return new int[] { none ? -1 : p.pct, p.ac == 1 ? 1 : 0 }; }
    [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
}

// ---- performance counters (English names, so they work on Japanese Windows too) ----
public static class UwwPdh {
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhOpenQuery(string src, IntPtr user, out IntPtr q);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhAddEnglishCounter(IntPtr q, string path, IntPtr user, out IntPtr c);
    [DllImport("pdh.dll")] static extern uint PdhCollectQueryData(IntPtr q);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhGetFormattedCounterArray(IntPtr c, uint fmt, ref uint size, out uint count, IntPtr buf);
    static IntPtr q;
    static Dictionary<string, IntPtr> ctr = new Dictionary<string, IntPtr>();
    public static void Init(string[] paths) {
        PdhOpenQuery(null, IntPtr.Zero, out q);
        foreach (var p in paths) { IntPtr c; if (PdhAddEnglishCounter(q, p, IntPtr.Zero, out c) == 0) ctr[p] = c; }
        PdhCollectQueryData(q);
    }
    public static void Collect() { PdhCollectQueryData(q); }
    public static Dictionary<string, double> Read(string path) {
        var r = new Dictionary<string, double>(); IntPtr c;
        if (!ctr.TryGetValue(path, out c)) return r;
        uint size = 0, count = 0, fmt = 0x200 | 0x8000; // DOUBLE | NOCAP100
        PdhGetFormattedCounterArray(c, fmt, ref size, out count, IntPtr.Zero);
        if (size == 0) return r;
        IntPtr buf = Marshal.AllocHGlobal((int)size);
        try {
            if (PdhGetFormattedCounterArray(c, fmt, ref size, out count, buf) != 0) return r;
            int stride = IntPtr.Size + 16;
            for (int i = 0; i < count; i++) {
                IntPtr item = new IntPtr(buf.ToInt64() + (long)i * stride);
                string name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(item));
                uint st = (uint)Marshal.ReadInt32(item, IntPtr.Size);
                double v = BitConverter.Int64BitsToDouble(Marshal.ReadInt64(item, IntPtr.Size + 8));
                if ((st == 0 || st == 1) && name != null) r[name] = v;
            }
        } finally { Marshal.FreeHGlobal(buf); }
        return r;
    }
}

// ---- master volume (Core Audio) ----
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
    int f(); int g(); int h(); int i();
    int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
    int j();
    int GetMasterVolumeLevelScalar(out float pfLevel);
    int k(); int l(); int m(); int n();
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
    int GetMute(out bool pbMute);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice { int Activate(ref Guid id, int clsCtx, IntPtr activationParams, out IAudioEndpointVolume aev); }
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator { int f(); int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint); }
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject { }

public static class UwwVol {
    static IAudioEndpointVolume Vol() {
        var e = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
        IMMDevice dev; Marshal.ThrowExceptionForHR(e.GetDefaultAudioEndpoint(0, 1, out dev));
        IAudioEndpointVolume v; var iid = typeof(IAudioEndpointVolume).GUID;
        Marshal.ThrowExceptionForHR(dev.Activate(ref iid, 23, IntPtr.Zero, out v)); return v;
    }
    public static float Get() { float f; Marshal.ThrowExceptionForHR(Vol().GetMasterVolumeLevelScalar(out f)); return f; }
    public static bool Muted() { bool m; Marshal.ThrowExceptionForHR(Vol().GetMute(out m)); return m; }
    public static void Set(float f) { var v = Vol(); Marshal.ThrowExceptionForHR(v.SetMasterVolumeLevelScalar(Math.Max(0f, Math.Min(1f, f)), Guid.Empty)); if (f > 0) v.SetMute(false, Guid.Empty); }
    public static void ToggleMute() { var v = Vol(); bool m; v.GetMute(out m); v.SetMute(!m, Guid.Empty); }
}
"@

$keys = @{ "playpause" = 0xB3; "next" = 0xB0; "prev" = 0xB1 }

# ---- seeking via Windows media sessions (SMTC) ----
$smtc = $null
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    function Await($op, [Type]$t) { $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op)); $null = $task.Wait(3000); $task.Result }
    [void][Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
    $smtc = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
} catch { $smtc = $null }
function Seek([string]$to, [string]$by) {
    if (-not $smtc) { return 501 }
    $s = $smtc.GetCurrentSession(); if (-not $s) { return 404 }
    if (-not $s.GetPlaybackInfo().Controls.IsPlaybackPositionEnabled) { return 409 }
    $tl = $s.GetTimelineProperties()
    if ($to -ne '') { $target = [double]::Parse($to, [Globalization.CultureInfo]::InvariantCulture) }
    else {
        $cur = $tl.Position.TotalSeconds
        if ([string]$s.GetPlaybackInfo().PlaybackStatus -eq 'Playing') { $cur += ([DateTimeOffset]::Now - $tl.LastUpdatedTime).TotalSeconds }
        $target = $cur + [double]::Parse($by, [Globalization.CultureInfo]::InvariantCulture)
    }
    $target = [Math]::Max(0, [Math]::Min($tl.EndTime.TotalSeconds - 0.5, $target))
    $ok = Await ($s.TryChangePlaybackPositionAsync([long]($target * 10000000))) ([bool])
    if ($ok) { return 200 } else { return 409 }
}

# ---- editor support: static files, saved settings, file pickers ----
Add-Type -AssemblyName System.Windows.Forms
$root = $null                                     # the wallpaper folder used by the editor / preview (found below)
$wallpapers = @()
$cfgDir = Join-Path $env:APPDATA 'UniversalWidgetWallpaper'; if (-not (Test-Path $cfgDir)) { $null = New-Item -ItemType Directory -Path $cfgDir }
$cfgFile = Join-Path $cfgDir 'user-config.json'
$editorOrigin = "http://localhost:$port"
$mime = @{ '.html'='text/html; charset=utf-8'; '.js'='text/javascript; charset=utf-8'; '.css'='text/css; charset=utf-8'; '.json'='application/json; charset=utf-8'
           '.jpg'='image/jpeg'; '.jpeg'='image/jpeg'; '.png'='image/png'; '.webp'='image/webp'; '.gif'='image/gif'; '.svg'='image/svg+xml'; '.mp4'='video/mp4'; '.webm'='video/webm'; '.ico'='image/x-icon' }
function Get-ConfigRev([string]$f = $cfgFile) { if (Test-Path -LiteralPath $f) { return [long]((Get-Item -LiteralPath $f).LastWriteTimeUtc - [DateTime]'1970-01-01').TotalMilliseconds } return 0 }

# ---- one settings file per screen ----
# Wallpaper Engine gives every screen its own browser storage, so the wallpaper on each screen sends its own random id
# (?inst=). Its editor settings live in user-config-<id>.json; until the first edit, the shared user-config.json is used.
$instFile = Join-Path $cfgDir 'screens.json'
$insts = @{}
try { if (Test-Path $instFile) { $j = Get-Content $instFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $j.PSObject.Properties) { $insts[$p.Name] = @{ first = [long]$p.Value.first; last = [long]$p.Value.last; th = [string]$p.Value.th } } } } catch { }
$instSaved = [DateTime]::MinValue
function Now-Ms { return [long]([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalMilliseconds }
function Get-Inst([string]$raw) { $i = (Get-Query $raw 'inst').ToLower(); if ($i -match '^[a-f0-9]{8,32}$') { return $i } return '' }
function Cfg-Read([string]$inst) { $f = $cfgFile; if ($inst) { $pf = Join-Path $cfgDir "user-config-$inst.json"; if (Test-Path $pf) { $f = $pf } }; return $f }
function Cfg-Write([string]$inst) { if ($inst) { return (Join-Path $cfgDir "user-config-$inst.json") } return $cfgFile }
function Seen-Inst([string]$inst, [string]$th) {
    if (-not $inst) { return }
    $now = Now-Ms; $new = -not $insts.ContainsKey($inst)
    if ($new) { if ($insts.Count -ge 16) { return }; $insts[$inst] = @{ first = $now; last = $now; th = '' } }
    $e = $insts[$inst]; $changed = $new -or ($th -match '^[a-z]{1,20}$' -and $e.th -ne $th)
    $e.last = $now; if ($th -match '^[a-z]{1,20}$') { $e.th = $th }
    if ($changed -or ([DateTime]::UtcNow - $script:instSaved).TotalMinutes -gt 10) {
        $script:instSaved = [DateTime]::UtcNow
        try { $o = [ordered]@{}; foreach ($k in $insts.Keys) { $o[$k] = $insts[$k] }; [IO.File]::WriteAllText($instFile, ($o | ConvertTo-Json -Compress -Depth 3), (New-Object Text.UTF8Encoding $false)) } catch { }
    }
}
function Insts-Json {
    $now = Now-Ms; $list = @()
    foreach ($k in $insts.Keys) { $e = $insts[$k]; if ($now - $e.last -gt 60L * 86400000) { continue }
        $list += [ordered]@{ id = $k; first = $e.first; th = $e.th; active = ($now - $e.last -lt 20000); own = (Test-Path (Join-Path $cfgDir "user-config-$k.json")) } }
    $list = @($list | Sort-Object { $_.first })
    return (ConvertTo-Json -InputObject $list -Compress -Depth 3)
}
function Pick([string]$kind) {
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true; $owner.ShowInTaskbar = $false; $owner.Opacity = 0; $owner.StartPosition = 'CenterScreen'
    $owner.Show(); $owner.Activate()
    try {
        if ($kind -eq 'folder' -or $kind -eq 'backup') {
            $d = New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description = $(if ($kind -eq 'backup') { '予定のバックアップを保存するフォルダを選んでください' } else { 'ショートカットにするフォルダを選んでください' })
            if ($d.ShowDialog($owner) -eq 'OK') { return $d.SelectedPath }
        } else {
            $d = New-Object System.Windows.Forms.OpenFileDialog
            $d.Filter = $(if ($kind -eq 'video') { '動画|*.mp4;*.webm;*.mov|すべて|*.*' } elseif ($kind -eq 'audio') { '音声|*.mp3;*.wav;*.ogg;*.m4a;*.aac;*.flac;*.opus|すべて|*.*' } else { '画像|*.png;*.jpg;*.jpeg;*.webp;*.gif;*.bmp;*.ico|すべて|*.*' })
            if ($d.ShowDialog($owner) -eq 'OK') { return $d.FileName }
        }
    } finally { $owner.Close() }
    return ''
}

# ---- static info (read once) ----
$cpuReg = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction SilentlyContinue
$cpuName = ([string]$cpuReg.ProcessorNameString).Trim()
$cpuBaseMHz = [double]$cpuReg.'~MHz'
$gpuName = ''; $vramTotal = 0
Get-ChildItem 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    $mem = [double]($p.'HardwareInformation.qwMemorySize')
    if ($p.DriverDesc -and ($mem -gt $vramTotal -or -not $gpuName)) { if ($mem -ge $vramTotal) { $gpuName = $p.DriverDesc; $vramTotal = $mem } }
}

$P_CORE = '\Processor(*)\% Processor Time'
$P_PERF = '\Processor Information(_Total)\% Processor Performance'
$P_GPU  = '\GPU Engine(*)\Utilization Percentage'
$P_VRAM = '\GPU Adapter Memory(*)\Dedicated Usage'
$P_DR   = '\PhysicalDisk(_Total)\Disk Read Bytes/sec'
$P_DW   = '\PhysicalDisk(_Total)\Disk Write Bytes/sec'
$P_DI   = '\PhysicalDisk(_Total)\% Idle Time'
[UwwPdh]::Init(@($P_CORE, $P_PERF, $P_GPU, $P_VRAM, $P_DR, $P_DW, $P_DI))

function Get-NetBytes {
    $rx = 0; $tx = 0
    foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        try { if ($n.OperationalStatus -eq 'Up' -and $n.NetworkInterfaceType -ne 'Loopback') { $s = $n.GetIPStatistics(); $rx += $s.BytesReceived; $tx += $s.BytesSent } } catch { }
    }
    return ,@($rx, $tx)
}
function First($d) { foreach ($v in $d.Values) { return $v }; return 0 }

function Get-Sys([bool]$withTop) {
    [UwwPdh]::Collect()
    $m = [UwwSys]::Mem(); $p = [UwwSys]::Power()
    $now = [DateTime]::UtcNow; $nb = Get-NetBytes; $sec = [Math]::Max(0.2, ($now - $script:lastNetT).TotalSeconds)
    $down = [Math]::Max(0, ($nb[0] - $script:lastNet[0]) / $sec); $up = [Math]::Max(0, ($nb[1] - $script:lastNet[1]) / $sec)
    $script:lastNet = $nb; $script:lastNetT = $now

    $cores = @(); $coreMap = [UwwPdh]::Read($P_CORE)
    foreach ($k in ($coreMap.Keys | Where-Object { $_ -ne '_Total' } | Sort-Object { [int]$_ })) { $cores += [Math]::Round([Math]::Min(100, $coreMap[$k]), 1) }
    $perf = First ([UwwPdh]::Read($P_PERF))
    # GPU% like Task Manager: busiest engine type, summed over processes
    $eng = @{}
    $gpuMap = [UwwPdh]::Read($P_GPU)
    foreach ($k in $gpuMap.Keys) { if ($k -match 'engtype_(.+)$') { $t = $Matches[1]; $eng[$t] = [double]$eng[$t] + $gpuMap[$k] } }
    $gpu = 0; foreach ($v in $eng.Values) { if ($v -gt $gpu) { $gpu = $v } }
    $vram = 0; foreach ($v in ([UwwPdh]::Read($P_VRAM)).Values) { if ($v -gt $vram) { $vram = $v } }

    $drives = @()
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        try { if ($d.DriveType -eq 'Fixed' -and $d.IsReady) { $drives += [ordered]@{ n = $d.Name.TrimEnd('\'); t = $d.TotalSize; f = $d.AvailableFreeSpace } } } catch { }
    }
    $procs = [System.Diagnostics.Process]::GetProcesses()
    $top = @()
    if ($withTop) {
        $top = @($procs | Group-Object ProcessName | ForEach-Object { [ordered]@{ n = $_.Name; m = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum } } |
            Sort-Object { $_.m } -Descending | Select-Object -First 5)
    }
    $o = [ordered]@{
        cpu = [UwwSys]::Cpu(); cores = $cores; mhz = [Math]::Round($cpuBaseMHz * $perf / 100); cpuName = $cpuName
        gpu = [Math]::Round([Math]::Min(100, $gpu), 1); gpuName = $gpuName; vramUsed = $vram; vramTotal = $vramTotal
        memTotal = $m[0]; memAvail = $m[1]; drives = $drives
        dRead = [Math]::Round((First ([UwwPdh]::Read($P_DR)))); dWrite = [Math]::Round((First ([UwwPdh]::Read($P_DW))))
        dActive = [Math]::Round([Math]::Max(0, 100 - (First ([UwwPdh]::Read($P_DI)))), 1)
        bat = $p[0]; ac = $p[1]; down = [Math]::Round($down); up = [Math]::Round($up)
        uptime = [Math]::Floor([UwwSys]::GetTickCount64() / 1000); procs = $procs.Length; top = $top
    }
    return ($o | ConvertTo-Json -Compress -Depth 4)
}

# ---- find this wallpaper in Wallpaper Engine and connect to it (only after the user agrees) ----
$utf8 = New-Object Text.UTF8Encoding $false
$approvedFile = Join-Path $cfgDir 'connected-wallpapers.json'
function Get-Trust {
    $t = @{ approved = @(); declined = @() }
    if (Test-Path $approvedFile) { try { $j = Get-Content $approvedFile -Raw -Encoding UTF8 | ConvertFrom-Json; $t.approved = @($j.approved); $t.declined = @($j.declined) } catch { } }
    return $t
}
function Save-Trust($t) { [IO.File]::WriteAllText($approvedFile, (@{ approved = @($t.approved); declined = @($t.declined) } | ConvertTo-Json -Compress), $utf8) }
function Get-SteamLibraries {
    $libs = @(); $sp = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if ($sp) {
        $sp = $sp -replace '/', '\'; $libs += $sp
        $vdf = Join-Path $sp 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) { foreach ($m in (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"')) { $libs += ($m.Matches[0].Groups[1].Value -replace '\\\\', '\') } }
    }
    return @($libs | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)
}
function Find-Wallpapers {
    $found = @()
    foreach ($lib in (Get-SteamLibraries)) {
        foreach ($base in @((Join-Path $lib 'steamapps\common\wallpaper_engine\projects\myprojects'), (Join-Path $lib 'steamapps\workshop\content\431960'))) {
            if (-not (Test-Path $base)) { continue }
            foreach ($d in (Get-ChildItem $base -Directory -ErrorAction SilentlyContinue)) {
                $idx = Join-Path $d.FullName 'index.html'
                if (-not (Test-Path $idx)) { continue }
                try { $fs = [IO.File]::OpenRead($idx); $b = New-Object byte[] 4096; $n = $fs.Read($b, 0, 4096); $fs.Close()
                      if ([Text.Encoding]::UTF8.GetString($b, 0, $n) -match 'name="universal-widget-wallpaper"') { $found += $d.FullName } } catch { }
            }
        }
    }
    return ,$found
}
function Ask-Connect([string]$path) {
    $title = '万能ウィジェット壁紙'
    try { $title = (Get-Content (Join-Path $path 'project.json') -Raw -Encoding UTF8 | ConvertFrom-Json).title } catch { }
    $owner = New-Object System.Windows.Forms.Form; $owner.TopMost = $true; $owner.ShowInTaskbar = $false; $owner.Opacity = 0; $owner.Show(); $owner.Activate()
    $msg = "次の壁紙が見つかりました。ヘルパーと接続しますか？`r`n`r`n  名前: $title`r`n  場所: $path`r`n`r`n" +
           "接続すると、この壁紙から 再生・音量・フォルダを開く・PCの状態 が使えるようになります。`r`n" +
           "自分で入れた「万能ウィジェット壁紙」なら［はい］を押してください。"
    $r = [System.Windows.Forms.MessageBox]::Show($owner, $msg, '万能ウィジェット壁紙 ヘルパー', 'YesNo', 'Question'); $owner.Close()
    return ($r -eq 'Yes')
}
$lastSync = [DateTime]::MinValue
function Sync-Wallpapers {
    $script:lastSync = [DateTime]::UtcNow
    $t = Get-Trust; $changed = $false
    foreach ($p in (Find-Wallpapers)) {
        if ($t.approved -contains $p -or $t.declined -contains $p) { continue }
        $official = $false; foreach ($id in $OfficialWorkshopIds) { if ($id -and $p -like "*\workshop\content\431960\$id") { $official = $true } }
        if ($official -or (Ask-Connect $p)) { $t.approved += $p } else { $t.declined += $p }
        $changed = $true
    }
    if ($changed) { Save-Trust $t }
    $script:wallpapers = @($t.approved | Where-Object { $_ -and (Test-Path (Join-Path $_ 'index.html')) })
    $want = "window.UWW_TOKEN='$token';"
    foreach ($p in $script:wallpapers) {
        try { $hd = Join-Path $p 'helper'; if (-not (Test-Path $hd)) { $null = New-Item -ItemType Directory -Path $hd }
              $tf = Join-Path $hd 'token.js'; if (-not (Test-Path $tf) -or [IO.File]::ReadAllText($tf) -ne $want) { [IO.File]::WriteAllText($tf, $want, $utf8) } } catch { }
    }
    # the editor / preview uses the wallpaper Wallpaper Engine is showing now (else the first connected one)
    $script:root = $null; $weCfg = ''
    foreach ($lib in (Get-SteamLibraries)) { $c = Join-Path $lib 'steamapps\common\wallpaper_engine\config.json'; if (Test-Path $c) { $weCfg += [IO.File]::ReadAllText($c) } }
    # (Wallpaper Engine's config also remembers wallpapers used long ago, so among those, the newest copy wins)
    $inCfg = @($script:wallpapers | Where-Object { $weCfg.IndexOf(($_ -replace '\\', '/'), [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if (-not $inCfg.Count) { $inCfg = @($script:wallpapers) }
    $script:root = $inCfg | Sort-Object { try { (Get-Item -LiteralPath (Join-Path $_ 'index.html')).LastWriteTimeUtc } catch { [DateTime]::MinValue } } -Descending | Select-Object -First 1
}

function Resolve-Target([string]$t) {
    $t = $t.Trim().Trim('"')
    if (-not $t) { return $null }
    $map = @{
        'ダウンロード' = 'shell:Downloads'; 'downloads' = 'shell:Downloads'
        'ドキュメント' = [Environment]::GetFolderPath('MyDocuments'); 'documents' = [Environment]::GetFolderPath('MyDocuments')
        'デスクトップ' = [Environment]::GetFolderPath('Desktop'); 'desktop' = [Environment]::GetFolderPath('Desktop')
        'ピクチャ' = [Environment]::GetFolderPath('MyPictures'); '画像' = [Environment]::GetFolderPath('MyPictures'); 'pictures' = [Environment]::GetFolderPath('MyPictures')
        'ミュージック' = [Environment]::GetFolderPath('MyMusic'); '音楽' = [Environment]::GetFolderPath('MyMusic'); 'music' = [Environment]::GetFolderPath('MyMusic')
        'ビデオ' = [Environment]::GetFolderPath('MyVideos'); '動画' = [Environment]::GetFolderPath('MyVideos'); 'videos' = [Environment]::GetFolderPath('MyVideos')
        'ホーム' = [Environment]::GetFolderPath('UserProfile'); 'home' = [Environment]::GetFolderPath('UserProfile')
        'pc' = 'shell:MyComputerFolder'; 'ごみ箱' = 'shell:RecycleBinFolder'; 'ゴミ箱' = 'shell:RecycleBinFolder'; 'recycle' = 'shell:RecycleBinFolder'
    }
    if ($map.ContainsKey($t)) { return @{ kind = 'folder'; path = $map[$t] } }
    if ($t -match '^[\w-]+(\.[\w-]+)+(/.*)?$') { $t = 'https://' + $t }
    $u = $null
    if ([Uri]::TryCreate($t, [UriKind]::Absolute, [ref]$u) -and ($u.Scheme -eq 'http' -or $u.Scheme -eq 'https')) { return @{ kind = 'url'; path = $u.AbsoluteUri } }
    if ($u -and $u.Scheme -eq 'file') { $t = $u.LocalPath }
    $p = [Environment]::ExpandEnvironmentVariables($t.Replace('/', '\'))
    if (Test-Path -LiteralPath $p -PathType Container) { return @{ kind = 'folder'; path = (Resolve-Path -LiteralPath $p).ProviderPath } }
    return $null
}
function Get-Query([string]$raw, [string]$name) {
    $i = $raw.IndexOf('?'); if ($i -lt 0) { return '' }
    foreach ($pair in $raw.Substring($i + 1).Split('&')) { $kv = $pair.Split('=', 2); if ($kv[0] -eq $name -and $kv.Length -eq 2) { return [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) } }
    return ''
}
function VolJson { return ([ordered]@{ vol = [Math]::Round([UwwVol]::Get(), 3); mute = [UwwVol]::Muted() } | ConvertTo-Json -Compress) }

# ---- calendar events (shared by every screen): %APPDATA%\UniversalWidgetWallpaper\events.json ----
$evFile = Join-Path $cfgDir 'events.json'
$evCats = @('plan', 'work', 'meet', 'due', 'bday', 'anniv', 'hosp', 'off')
# where the daily backups go: chosen on the calendar page (storage.json), otherwise %APPDATA%\UniversalWidgetWallpaper\backup
$storeFile = Join-Path $cfgDir 'storage.json'
function Bak-Default { return (Join-Path $cfgDir 'backup') }
function Bak-Custom { try { if (Test-Path $storeFile) { $d = [string](Get-Content $storeFile -Raw -Encoding UTF8 | ConvertFrom-Json).backupDir
    if ($d -and [IO.Path]::IsPathRooted($d) -and (Test-Path -LiteralPath $d -PathType Container)) { return $d } } } catch { }; return '' }
function Bak-Dir { $c = Bak-Custom; if ($c) { return $c }; return (Bak-Default) }
function Ev-Load { if (Test-Path $evFile) { try { $j = Get-Content $evFile -Raw -Encoding UTF8 | ConvertFrom-Json; return @($j.events | Where-Object { $_ }) } catch { } }; return @() }
function Ev-Save($list) {
    # keep one copy per day of the events as they were before today's first change (the newest 30 days are kept):
    # %APPDATA%\UniversalWidgetWallpaper\backup\events-YYYYMMDD.json — the calendar page can read these back
    try {
        if (Test-Path $evFile) {
            $bd = Bak-Dir; if (-not (Test-Path $bd)) { $null = New-Item -ItemType Directory -Path $bd }
            $bf = Join-Path $bd ('events-' + (Get-Date -Format 'yyyyMMdd') + '.json')
            if (-not (Test-Path $bf)) { Copy-Item -LiteralPath $evFile -Destination $bf }
            Get-ChildItem $bd -Filter 'events-*.json' | Sort-Object Name -Descending | Select-Object -Skip 30 | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    $json = ConvertTo-Json -InputObject ([ordered]@{ events = @($list) }) -Depth 4 -Compress
    $tmp = $evFile + '.tmp'; [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false)); Move-Item -LiteralPath $tmp -Destination $evFile -Force
}
# only well-formed events are kept (dates, times, lengths and categories are checked; anything else is dropped)
function Ev-Clean($e) {
    if ($null -eq $e) { return $null }
    $id = [string]$e.id; $date = [string]$e.date; $time = [string]$e.time; $title = [string]$e.title; $cat = [string]$e.cat; $memo = [string]$e.memo
    if ($id -notmatch '^[A-Za-z0-9_-]{1,40}$') { return $null }
    if ($date -notmatch '^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$') { return $null }
    if ($time -and $time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { $time = '' }
    $title = ($title -replace '[\x00-\x1f]', ' ').Trim(); if ($title.Length -gt 200) { $title = $title.Substring(0, 200) }
    if (-not $title) { return $null }
    if ($evCats -notcontains $cat) { $cat = 'plan' }
    $memo = $memo -replace '[\x00-\x08\x0b\x0c\x0e-\x1f]', ''; if ($memo.Length -gt 2000) { $memo = $memo.Substring(0, 2000) }
    return [ordered]@{ id = $id; date = $date; time = $time; title = $title; cat = $cat; memo = $memo }
}
function Read-Body($req, [int]$max) {
    $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8); $buf = New-Object char[] ($max + 1); $n = 0
    while ($n -lt $buf.Length) { $k = $sr.Read($buf, $n, $buf.Length - $n); if ($k -le 0) { break }; $n += $k }
    $sr.Close(); if ($n -gt $max) { return $null }; return (New-Object string ($buf, 0, $n))
}

$log = Join-Path $env:TEMP 'uww-helper.log'

function Log($s) {
    try { if ((Test-Path $log) -and (Get-Item $log).Length -gt 200KB) { Remove-Item $log }
          Add-Content -LiteralPath $log -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $s) -Encoding UTF8 } catch { }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
try { $listener.Start() } catch { exit }

# ---- per-start secret token ----
# Every command needs this token. Only wallpaper folders the user approved receive it (helper\token.js, a local
# file that web pages cannot read); the editor gets it from /token (same-origin only). A new token is made on every start.
$rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $tb = New-Object byte[] 32; $rng.GetBytes($tb)
$token = ($tb | ForEach-Object { $_.ToString('x2') }) -join ''
try { [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'token.js'), "window.UWW_TOKEN='$token';", $utf8) } catch { }
Log "helper v7 started"
try { Sync-Wallpapers } catch { Log "sync error: $_" }
[void][UwwSys]::Cpu()
$lastNet = Get-NetBytes; $lastNetT = [DateTime]::UtcNow
$seen = @{}
$okHosts = @("localhost:$port", "127.0.0.1:$port", "[::1]:$port")
$staticExt = @('.html', '.js', '.json', '.jpg', '.jpeg', '.png', '.webp', '.gif', '.svg', '.css')

while ($listener.IsListening) {
    try {
        $ctx = $listener.GetContext(); $req = $ctx.Request; $res = $ctx.Response
        # DNS-rebinding guard: only accept requests addressed to localhost itself
        if ($okHosts -notcontains ([string]$req.UserHostName).ToLower()) { $res.StatusCode = 400; $res.Close(); Log "bad host [$($req.UserHostName)]"; continue }
        # look for newly installed / updated wallpapers every 2 minutes
        if (([DateTime]::UtcNow - $lastSync).TotalSeconds -gt 120) { try { Sync-Wallpapers } catch { Log "sync error: $_" } }
        $origin = [string]$req.Headers['Origin']
        # same-origin GETs carry no Origin header; browsers add an unforgeable Sec-Fetch-Site instead
        $fromEditor = ($origin -eq $editorOrigin) -or (-not $origin -and [string]$req.Headers['Sec-Fetch-Site'] -eq 'same-origin')
        $trusted = ($origin -eq 'null') -or ($origin -like 'file://*') -or $fromEditor
        $cmd = $req.Url.AbsolutePath.Trim('/').ToLower()

        # static pages (read-only): the editor and the YouTube host page from the helper folder,
        # and the connected wallpaper's own web files (for the editor's preview)
        if ($req.HttpMethod -eq 'GET' -and ($cmd -eq 'editor' -or $cmd -eq 'calendar' -or $cmd -eq 'monitor' -or $cmd.StartsWith('files/'))) {
            $full = $null
            if ($cmd -eq 'editor') { $full = Join-Path $PSScriptRoot 'editor.html' }
            elseif ($cmd -eq 'calendar') { $full = Join-Path $PSScriptRoot 'calendar.html' }
            elseif ($cmd -eq 'monitor') { $full = Join-Path $PSScriptRoot 'monitor.html' }
            elseif ($root) {
                try {
                    $rel = [Uri]::UnescapeDataString($req.Url.AbsolutePath.Substring(7)).Replace('/', '\')
                    $full = [IO.Path]::GetFullPath((Join-Path $root $rel))
                    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or $full -like '*\helper\*' -or
                        $staticExt -notcontains [IO.Path]::GetExtension($full).ToLower()) { $full = $null }
                } catch { $full = $null }
            }
            if ($full -and (Test-Path -LiteralPath $full -PathType Leaf)) {
                $t = $mime[[IO.Path]::GetExtension($full).ToLower()]; if (-not $t) { $t = 'application/octet-stream' }
                $res.ContentType = $t; $res.Headers.Add('Cache-Control', 'no-cache'); $res.Headers.Add('X-Content-Type-Options', 'nosniff')
                # anti-clickjacking: the editor and the preview may only be framed by the editor itself
                if ($cmd -eq 'editor' -or $cmd -eq 'calendar' -or $cmd -eq 'files/index.html') { $res.Headers.Add('Content-Security-Policy', "frame-ancestors 'self'") }
                $b = [IO.File]::ReadAllBytes($full); $res.OutputStream.Write($b, 0, $b.Length)
            } else { $res.StatusCode = 404 }
            $res.Close(); continue
        }
        $res.Headers.Add('Cache-Control', 'no-store')
        if ($trusted) {
            $res.Headers.Add('Access-Control-Allow-Origin', $origin)
            $res.Headers.Add('Access-Control-Allow-Headers', 'X-Uww-Token, Content-Type')
            $res.Headers.Add('Access-Control-Allow-Private-Network', 'true')
        }
        $status = 200; $body = 'ok'; $ctype = 'text/plain; charset=utf-8'

        if ($req.HttpMethod -eq 'OPTIONS') { $status = $(if ($trusted) { 204 } else { 403 }); $body = '' }
        elseif ($cmd -eq 'ping') { $body = 'ok v7' }
        elseif ($cmd -eq 'token') { if ($fromEditor) { $body = $token } else { $status = 403; $body = 'forbidden' } }
        elseif (-not $trusted -or -not $token -or [string]$req.Headers['X-Uww-Token'] -cne $token) { $status = 403; $body = 'forbidden' }
        elseif ($cmd -eq 'hello') { $body = 'hi' }
        elseif ($cmd -eq 'screen') {
            # where the taskbar is: the gaps between the whole screen and the usable "working area", as fractions of the screen
            $s = [System.Windows.Forms.Screen]::PrimaryScreen; $b = $s.Bounds; $w = $s.WorkingArea
            $body = ([ordered]@{ left = ($w.Left - $b.Left) / $b.Width; top = ($w.Top - $b.Top) / $b.Height
                                 right = ($b.Right - $w.Right) / $b.Width; bottom = ($b.Bottom - $w.Bottom) / $b.Height } | ConvertTo-Json -Compress)
            $ctype = 'application/json; charset=utf-8'
        }
        elseif ($cmd -eq 'seek') { $status = Seek (Get-Query $req.RawUrl 'to') (Get-Query $req.RawUrl 'by'); $body = "$status" }
        elseif ($cmd -eq 'config' -and $req.HttpMethod -eq 'GET') {
            $inst = Get-Inst $req.RawUrl; if (-not $fromEditor) { Seen-Inst $inst (Get-Query $req.RawUrl 'th') }
            $f = Cfg-Read $inst; $txt = '{}'; if (Test-Path -LiteralPath $f) { $txt = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) }
            if (-not $txt.Trim()) { $txt = '{}' }
            $body = '{"rev":' + (Get-ConfigRev $f) + ',"values":' + $txt + '}'; $ctype = 'application/json; charset=utf-8'
        }
        elseif ($cmd -eq 'events' -and $req.HttpMethod -eq 'GET') {
            $txt = '{"events":[]}'; if (Test-Path $evFile) { $txt = [IO.File]::ReadAllText($evFile, [Text.Encoding]::UTF8) }
            $body = '{"rev":' + (Get-ConfigRev $evFile) + ',"data":' + $txt + '}'; $ctype = 'application/json; charset=utf-8'
        }
        elseif ($cmd -eq 'events-store') {
            # GET: the backup folder in use / POST {dir}: change it (calendar page only; an existing folder, or '' for the default)
            if ($req.HttpMethod -eq 'POST') {
                if (-not $fromEditor) { $status = 403; $body = 'forbidden' }
                else { $txt = Read-Body $req 4096; $dir = $null; try { $dir = [string]($txt | ConvertFrom-Json).dir } catch { }
                    if ($null -eq $dir) { $status = 400; $body = 'bad json' }
                    elseif ($dir -and -not ([IO.Path]::IsPathRooted($dir) -and (Test-Path -LiteralPath $dir -PathType Container))) { $status = 400; $body = 'no such folder' }
                    else { if ($dir) { $dir = (Resolve-Path -LiteralPath $dir).ProviderPath }; [IO.File]::WriteAllText($storeFile, (ConvertTo-Json -InputObject ([ordered]@{ backupDir = $dir }) -Compress), (New-Object Text.UTF8Encoding $false)) }
                }
            }
            if ($status -eq 200) { $body = ConvertTo-Json -InputObject ([ordered]@{ dir = (Bak-Dir); default = (Bak-Default); custom = [bool](Bak-Custom); events = $evFile }) -Compress; $ctype = 'application/json; charset=utf-8' }
        }
        elseif ($cmd -eq 'events-backup' -and $req.HttpMethod -eq 'GET') {
            # the daily copies: without ?d= a list (newest first), with ?d=YYYYMMDD that day's copy (read-only)
            $bd = Bak-Dir; $d = Get-Query $req.RawUrl 'd'; $ctype = 'application/json; charset=utf-8'
            if ($d -match '^\d{8}$') { $bf = Join-Path $bd "events-$d.json"; if (Test-Path $bf) { $body = [IO.File]::ReadAllText($bf, [Text.Encoding]::UTF8) } else { $status = 404; $body = 'not found' } }
            else { $list = @(); if (Test-Path $bd) { foreach ($f in (Get-ChildItem $bd -Filter 'events-*.json' | Sort-Object Name -Descending)) { $list += $f.BaseName.Substring(7) } }
                   $body = ConvertTo-Json -InputObject @($list) -Compress; if (-not $list.Count) { $body = '[]' } }
        }
        elseif (($cmd -eq 'events-put' -or $cmd -eq 'events-del') -and $req.HttpMethod -eq 'POST') {
            # events-put: add or update events (by id) / events-del: remove events by id
            $txt = Read-Body $req (4MB); $arr = $null; if ($txt) { try { $arr = @($txt | ConvertFrom-Json) } catch { } }
            if ($null -eq $arr) { $status = 400; $body = 'bad json' }
            else {
                $map = [ordered]@{}; foreach ($e in (Ev-Load)) { $c = Ev-Clean $e; if ($c) { $map[$c.id] = $c } }
                if ($cmd -eq 'events-put') { foreach ($e in $arr) { $c = Ev-Clean $e; if ($c) { $map[$c.id] = $c } } }
                else { foreach ($id in $arr) { $k = [string]$id; if ($map.Contains($k)) { $map.Remove($k) } } }
                if ($map.Count -gt 5000) { $status = 413; $body = 'too many events' }
                else { Ev-Save @($map.Values); $body = '{"rev":' + (Get-ConfigRev $evFile) + ',"count":' + $map.Count + '}'; $ctype = 'application/json' }
            }
        }
        elseif ($cmd -eq 'fonts') {
            # names of the fonts installed on this PC, for the editor's font-name suggestions (read-only)
            if (-not $fromEditor) { $status = 403; $body = 'forbidden' }
            else {
                if (-not $script:fontJson) {
                    try { Add-Type -AssemblyName System.Drawing; $fc = New-Object System.Drawing.Text.InstalledFontCollection
                          $script:fontJson = ConvertTo-Json -InputObject @($fc.Families | ForEach-Object { $_.Name } | Sort-Object -Unique) -Compress; $fc.Dispose() } catch { $script:fontJson = '[]' }
                }
                $body = $script:fontJson; $ctype = 'application/json; charset=utf-8'
            }
        }
        elseif ($cmd -eq 'screens') {
            if (-not $fromEditor) { $status = 403; $body = 'forbidden' } else { $body = Insts-Json; $ctype = 'application/json; charset=utf-8' }
        }
        elseif ($cmd -eq 'config' -and $req.HttpMethod -eq 'POST') {
            if (-not $fromEditor -or $req.ContentLength64 -gt 1MB) { $status = 403; $body = 'forbidden' }
            else {
                # read at most 1 MB even when the length is unknown (chunked)
                $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8); $buf = New-Object char[] (1MB + 1); $n = 0
                while ($n -lt $buf.Length) { $k = $sr.Read($buf, $n, $buf.Length - $n); if ($k -le 0) { break }; $n += $k }
                $sr.Close(); $txt = New-Object string ($buf, 0, $n)
                $parsed = $null; try { $parsed = $txt | ConvertFrom-Json } catch { }
                if ($n -gt 1MB) { $status = 413; $body = 'too large' }
                elseif ($null -eq $parsed -or -not $txt.TrimStart().StartsWith('{')) { $status = 400; $body = 'bad json' }
                else { $f = Cfg-Write (Get-Inst $req.RawUrl); [IO.File]::WriteAllText($f, $txt, (New-Object Text.UTF8Encoding $false)); $body = '{"rev":' + (Get-ConfigRev $f) + '}'; $ctype = 'application/json' }
            }
        }
        elseif ($cmd -eq 'pick') {
            if (-not $fromEditor) { $status = 403; $body = 'forbidden' }
            else { $p = Pick (Get-Query $req.RawUrl 'kind'); $body = (@{ path = $p } | ConvertTo-Json -Compress); $ctype = 'application/json; charset=utf-8' }
        }
        elseif ($keys.ContainsKey($cmd)) { [UwwSys]::Tap([byte]$keys[$cmd]) }
        elseif ($cmd -eq 'vol') {
            $s = Get-Query $req.RawUrl 'set'
            if ($s -ne '') { [UwwVol]::Set([float]::Parse($s, [Globalization.CultureInfo]::InvariantCulture)) }
            $body = VolJson; $ctype = 'application/json; charset=utf-8'
        }
        elseif ($cmd -eq 'mute') { [UwwVol]::ToggleMute(); $body = VolJson; $ctype = 'application/json; charset=utf-8' }
        elseif ($cmd -eq 'open') {
            $r = Resolve-Target (Get-Query $req.RawUrl 't')
            if ($r) { if ($r.kind -eq 'url') { Start-Process -FilePath $r.path } else { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $r.path + '"') } }
            else { $status = 400; $body = 'invalid target' }
        }
        elseif ($cmd -eq 'sys') { $body = Get-Sys ((Get-Query $req.RawUrl 'top') -eq '1'); $ctype = 'application/json; charset=utf-8' }
        elseif ($cmd -eq 'quit') { $listener.Stop() }
        else { $status = 404; $body = 'not found' }

        if ($status -ge 400) { Log "$($req.HttpMethod) /$cmd origin=[$origin] -> $status" }
        elseif ($trusted -and -not $seen.ContainsKey($origin)) { $seen[$origin] = 1; Log "accepted origin=[$origin] /$cmd" }
        $res.StatusCode = $status; $res.ContentType = $ctype
        $buf = [System.Text.Encoding]::UTF8.GetBytes($body)
        if ($buf.Length) { $res.OutputStream.Write($buf, 0, $buf.Length) }
        $res.Close()
    } catch { Log "error: $_"; try { $res.StatusCode = 500; $res.Close() } catch { } }
}
