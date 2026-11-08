param([string]$Self, [string]$Mode)
# ───────────────────────────────────────────────────────────────
#  万能ウィジェット壁紙 操作ヘルパー  セットアップ
#  ・入れる場所: %LOCALAPPDATA%\UniversalWidgetWallpaper\helper（管理者権限は不要）
#  ・入れるもの: media-helper.ps1 / editor.html / calendar.html / monitor.html / start-helper.vbs
#  ・スタートメニューに「万能ウィジェット壁紙」フォルダを作ります
#  ・自動起動はユーザーが［はい］を選んだときだけ登録します
#  ・このファイルを開いたまま中身を確認できます（すべてテキスト）
# ───────────────────────────────────────────────────────────────
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$app = '万能ウィジェット壁紙'
$base = Join-Path $env:LOCALAPPDATA 'UniversalWidgetWallpaper'
$dir = Join-Path $base 'helper'
$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'UniversalWidgetHelper.lnk'
$menu = Join-Path ([Environment]::GetFolderPath('Programs')) '万能ウィジェット壁紙'
$utf8 = New-Object Text.UTF8Encoding $false

$payload = @{
__PAYLOAD__
}

# developer check: extract the files only (no dialogs, no shortcuts) into the folder given in UWW_SETUP_TEST
if ($env:UWW_SETUP_TEST) {
    if (-not (Test-Path $env:UWW_SETUP_TEST)) { $null = New-Item -ItemType Directory -Path $env:UWW_SETUP_TEST }
    foreach ($name in $payload.Keys) { [IO.File]::WriteAllBytes((Join-Path $env:UWW_SETUP_TEST $name), [Convert]::FromBase64String($payload[$name])) }
    return
}

# step-by-step record (helps when something goes wrong): %TEMP%\uww-setup.log
$setupLog = Join-Path $env:TEMP 'uww-setup.log'
function L([string]$s) { try { Add-Content -LiteralPath $setupLog -Value ("{0:HH:mm:ss} {1}" -f (Get-Date), $s) -Encoding UTF8 } catch { } }
L "---- setup started (mode=[$Mode]) from $Self"
function Msg([string]$text, [string]$buttons = 'OK', [string]$icon = 'Information') {
    $o = New-Object System.Windows.Forms.Form; $o.TopMost = $true; $o.ShowInTaskbar = $true; $o.Opacity = 0; $o.StartPosition = 'CenterScreen'; $o.Text = "$app セットアップ"; $o.Show(); $o.Activate()
    $r = [System.Windows.Forms.MessageBox]::Show($o, $text, "$app セットアップ", $buttons, $icon); $o.Close()
    L ("dialog [" + ($text -split "`r?`n")[0] + "] -> " + $r); return [string]$r
}
function Steam-Libraries {
    $libs = @(); $sp = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if ($sp) {
        $sp = $sp -replace '/', '\'; $libs += $sp
        $vdf = Join-Path $sp 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) { foreach ($m in (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"')) { $libs += ($m.Matches[0].Groups[1].Value -replace '\\\\', '\') } }
    }
    return @($libs | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)
}
function Find-Wallpapers {
    # folders of this wallpaper: your own copies (myprojects) and Workshop subscriptions
    $found = @()
    foreach ($lib in (Steam-Libraries)) {
        foreach ($b in @((Join-Path $lib 'steamapps\common\wallpaper_engine\projects\myprojects'), (Join-Path $lib 'steamapps\workshop\content\431960'))) {
            if (-not (Test-Path $b)) { continue }
            foreach ($d in (Get-ChildItem $b -Directory -ErrorAction SilentlyContinue)) {
                $idx = Join-Path $d.FullName 'index.html'; if (-not (Test-Path $idx)) { continue }
                try { $fs = [IO.File]::OpenRead($idx); $buf = New-Object byte[] 4096; $n = $fs.Read($buf, 0, 4096); $fs.Close()
                      if ([Text.Encoding]::UTF8.GetString($buf, 0, $n) -match 'name="universal-widget-wallpaper"') { $found += $d.FullName } } catch { }
            }
        }
    }
    return $found
}
function Connect-Wallpapers {
    # ask about every wallpaper copy in ONE question here, so the helper has nothing left to ask when it starts
    $trust = Join-Path $env:APPDATA 'UniversalWidgetWallpaper\connected-wallpapers.json'
    $ok = @(); $no = @()
    if (Test-Path $trust) { try { $j = [IO.File]::ReadAllText($trust, [Text.Encoding]::UTF8) | ConvertFrom-Json; $ok = @($j.approved | Where-Object { $_ }) } catch { } }
    # the official Workshop items are connected without asking (the list is read from the helper being installed)
    $official = @(); $hs = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload['media-helper.ps1']))
    if ($hs -match '\$OfficialWorkshopIds = @\(([^)]*)\)') { $official = @([regex]::Matches($Matches[1], '\d+') | ForEach-Object { $_.Value }) }
    $ask = @()
    foreach ($p in @(Find-Wallpapers)) {
        if (-not $p -or $ok -contains $p) { continue }
        $isOfficial = $false; foreach ($id in $official) { if ($p -like "*\workshop\content\431960\$id") { $isOfficial = $true } }
        if ($isOfficial) { $ok += $p } else { $ask += $p }
    }
    L ("wallpapers: connected=" + $ok.Count + " to ask=" + $ask.Count)
    if ($ask.Count) {
        $names = ($ask | ForEach-Object { '  ・' + $_ }) -join "`r`n"
        $r = Msg ("この PC で「万能ウィジェット壁紙」のコピーが見つかりました（" + $ask.Count + " 個）。`r`n`r`n" + $names + "`r`n`r`n" +
                  "ヘルパーと接続しますか？`r`n接続すると、これらの壁紙から 再生・音量・フォルダを開く・PCの状態・設定エディタ が使えます。`r`n" +
                  "自分で入れた壁紙なら［はい］を押してください。") 'YesNo' 'Question'
        if ($r -eq 'Yes') { $ok += $ask } else { $no += $ask }
    }
    $dirT = Split-Path $trust; if (-not (Test-Path $dirT)) { $null = New-Item -ItemType Directory -Path $dirT }
    [IO.File]::WriteAllText($trust, (@{ approved = @($ok); declined = @($no) } | ConvertTo-Json -Compress), $utf8)
    return @($ok | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'index.html')) }).Count
}
function Stop-Helper {
    # the small watcher script that starts the helper again (so it does not bring it back while we update or remove it)
    Get-CimInstance Win32_Process -Filter "Name='wscript.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*start-helper.vbs*' } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
    $tf = Join-Path $dir 'token.js'
    if (Test-Path $tf) {
        $tk = ((Get-Content -Raw $tf) -replace "(?s).*'(.*)'.*", '$1')
        try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 -Headers @{ Origin = 'null'; 'X-Uww-Token' = $tk } http://localhost:39217/quit | Out-Null } catch { }
    }
    # older versions that lived inside the wallpaper folder
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*media-helper.ps1*' } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
    Start-Sleep -Milliseconds 800
}
function Shortcut([string]$lnk, [string]$target, [string]$arguments, [string]$desc, [string]$icon) {
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk); $s.TargetPath = $target
    if ($arguments) { $s.Arguments = $arguments }; if ($desc) { $s.Description = $desc }; if ($icon) { $s.IconLocation = $icon }; $s.Save()
}
function Remove-Tokens([string]$cfg) {
    # the helper put a small "helper\token.js" (the old pass-phrase) into each connected wallpaper folder; remove only that file
    $list = Join-Path $cfg 'connected-wallpapers.json'; if (-not (Test-Path $list)) { return }
    try { $j = Get-Content $list -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
    foreach ($w in @($j.approved)) {
        if (-not $w -or -not (Test-Path -LiteralPath $w -PathType Container)) { continue }
        $hd = Join-Path $w 'helper'; $tf = Join-Path $hd 'token.js'
        if (Test-Path -LiteralPath $tf -PathType Leaf) {
            $t = ''; try { $t = [IO.File]::ReadAllText($tf).Trim() } catch { }
            if ($t -match "^window\.UWW_TOKEN='[0-9a-f]*';$") { Remove-Item -LiteralPath $tf -Force -ErrorAction SilentlyContinue; L "removed $tf" }
        }
        if ((Test-Path -LiteralPath $hd -PathType Container) -and -not (Get-ChildItem -LiteralPath $hd -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $hd -Force -ErrorAction SilentlyContinue }
    }
}
function Uninstall {
    Stop-Helper
    foreach ($p in @($startup, $menu, $base)) { if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } }
    $cfg = Join-Path $env:APPDATA 'UniversalWidgetWallpaper'
    Remove-Tokens $cfg
    if ((Test-Path $cfg) -and (Msg "ヘルパーを削除しました。`r`n`r`nエディタで作った設定と、カレンダーの予定（バックアップも）を消しますか？`r`n（［いいえ］なら残ります。また入れたときに続きから使えます）`r`n`r`n予定を残しておきたいときは［いいえ］を選んでください。`r`n場所: $env:APPDATA\UniversalWidgetWallpaper" 'YesNo' 'Question') -eq 'Yes') {
        Remove-Item $cfg -Recurse -Force -ErrorAction SilentlyContinue
    }
    Msg "アンインストールが終わりました。壁紙はそのまま使えます。" | Out-Null
}

if ($Mode -eq 'uninstall') {
    if ((Msg "万能ウィジェット壁紙 の操作ヘルパーをアンインストールしますか？" 'YesNo' 'Question') -eq 'Yes') { Uninstall }
    return
}

# version numbers: the one already installed (older helpers have none) and the one in this setup
function Helper-Version([string]$text) { if ($text -match "\`$HelperVersion = '([\d.]+)'") { return $Matches[1] } return '' }
$newVer = Helper-Version ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload['media-helper.ps1'])))
if (Test-Path (Join-Path $dir 'media-helper.ps1')) {
    $oldVer = Helper-Version ([IO.File]::ReadAllText((Join-Path $dir 'media-helper.ps1'), [Text.Encoding]::UTF8))
    $oldTxt = $(if ($oldVer) { "v$oldVer" } else { 'v1.3 以前' }); $newTxt = $(if ($newVer) { "v$newVer" } else { '?' })
    $verLine = "入っている版: $oldTxt　→　このファイルの版: $newTxt"
    if ($oldVer -and $newVer -and ([version]$oldVer -gt [version]$newVer)) { $verLine += "`r`n（入っている版のほうが新しいです。入れ直すと古い版に戻ります）" }
    $r = Msg "操作ヘルパーはすでに入っています。`r`n$verLine`r`n`r`n［はい］　　このファイルの版に入れ直す（設定と予定はそのまま）`r`n［いいえ］　アンインストールする`r`n［キャンセル］何もしない" 'YesNoCancel' 'Question'
    if ($r -eq 'No') { Uninstall; return }
    if ($r -ne 'Yes') { return }
} else {
    $r = Msg ("万能ウィジェット壁紙 の「操作ヘルパー」をインストールします。`r`n`r`n" +
              "・入れる場所: $dir`r`n・管理者の権限はいりません`r`n・あとからスタートメニューの「アンインストール」で消せます`r`n`r`n続けますか？") 'YesNo' 'Question'
    if ($r -ne 'Yes') { return }
}

try {
    L "stopping old helper"; Stop-Helper
    # clean up the previous version, which was published under an older name (paths kept only for this migration)
    $oldBase = Join-Path $env:LOCALAPPDATA 'EmoMediaWallpaper'
    $oldLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'EmoMediaHelper.lnk'
    $oldMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Emo Media Wallpaper'
    foreach ($p in @($oldLnk, $oldMenu, $oldBase)) { if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue; L "removed old $p" } }
    $oldCfg = Join-Path $env:APPDATA 'EmoMediaWallpaper\user-config.json'; $newCfgDir = Join-Path $env:APPDATA 'UniversalWidgetWallpaper'
    if ((Test-Path $oldCfg) -and -not (Test-Path (Join-Path $newCfgDir 'user-config.json'))) {
        if (-not (Test-Path $newCfgDir)) { $null = New-Item -ItemType Directory -Path $newCfgDir }
        Copy-Item $oldCfg (Join-Path $newCfgDir 'user-config.json'); L "carried over editor settings"
    }
    L "writing files to $dir"
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    foreach ($name in $payload.Keys) {
        $bytes = [Convert]::FromBase64String($payload[$name])
        [IO.File]::WriteAllBytes((Join-Path $dir $name), $bytes)       # written fresh: no "downloaded from the internet" mark
    }
    # keep a copy of this setup for uninstalling later (bytes only, so no download mark is copied)
    [IO.File]::WriteAllBytes((Join-Path $base 'setup.cmd'), [IO.File]::ReadAllBytes($Self))

    if (-not (Test-Path $menu)) { $null = New-Item -ItemType Directory -Path $menu }
    $vbs = Join-Path $dir 'start-helper.vbs'
    Shortcut (Join-Path $menu '設定エディタを開く.lnk') 'explorer.exe' 'http://localhost:39217/editor' 'ブラウザで設定エディタを開きます' "$env:SystemRoot\System32\imageres.dll,109"
    Shortcut (Join-Path $menu 'ヘルパーを起動する.lnk') 'wscript.exe' ('"' + $vbs + '"') '操作ヘルパーを起動します' "$env:SystemRoot\System32\imageres.dll,176"
    Shortcut (Join-Path $menu 'アンインストール.lnk') 'cmd.exe' ('/c ""' + (Join-Path $base 'setup.cmd') + '" uninstall"') '操作ヘルパーを削除します' "$env:SystemRoot\System32\imageres.dll,84"

    if ((Msg "パソコンを起動したときに、ヘルパーも自動で起動しますか？`r`n`r`n（おすすめ: はい　／　あとからアンインストールで消せます）" 'YesNo' 'Question') -eq 'Yes') {
        Shortcut $startup 'wscript.exe' ('"' + $vbs + '"') '万能ウィジェット壁紙 操作ヘルパー' ''
    } elseif (Test-Path $startup) { Remove-Item $startup -Force }

    # which wallpapers may use the helper: one question, asked before the helper starts (earlier "no" answers are asked again)
    $nConnected = Connect-Wallpapers

    L "files written; starting helper"
    Start-Process wscript.exe -ArgumentList ('"' + $vbs + '"')
    # the helper writes a fresh token.js the moment it starts (it may then be busy asking "connect?", so don't rely on ping)
    $began = (Get-Date).AddSeconds(-2); $tf = Join-Path $dir 'token.js'; $ok = $false
    for ($i = 0; $i -lt 30 -and -not $ok; $i++) { Start-Sleep -Milliseconds 500; $ok = (Test-Path $tf) -and ((Get-Item $tf).LastWriteTime -ge $began) }
    L "helper started: $ok"
    if ($ok) {
        $tail = $(if ($nConnected) { "・壁紙の右下にマウスを近づけると出る ⚙ ボタンから設定エディタが開けます`r`n" } else {
                  "・まだ壁紙とつながっていません。Wallpaper Engine で壁紙をサブスクライブしてから、`r`n　スタートメニューの「設定エディタを開く」→「壁紙を探してつなぐ」を押してください`r`n" })
        Msg ("インストールが終わりました！`r`n`r`n" + $tail +
             "・スタートメニューの「万能ウィジェット壁紙」から、設定エディタやアンインストールを開けます") | Out-Null
    } else {
        Msg "ファイルは入りましたが、ヘルパーの起動を確認できませんでした。`r`nスタートメニューの「万能ウィジェット壁紙」→「ヘルパーを起動する」を試してください。" 'OK' 'Warning' | Out-Null
    }
} catch {
    L ("ERROR: " + $_.Exception.Message + " @ line " + $_.InvocationInfo.ScriptLineNumber)
    Msg ("インストール中に問題が起きました。`r`n`r`n" + $_.Exception.Message + "`r`n`r`n（記録: $setupLog）") 'OK' 'Error' | Out-Null
}
L "---- setup finished"
