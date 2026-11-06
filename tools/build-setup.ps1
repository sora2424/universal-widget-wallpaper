param([string]$HelperDir, [string]$OutFile)
$ErrorActionPreference = 'Stop'
$files = @('media-helper.ps1', 'editor.html', 'calendar.html', 'monitor.html', 'start-helper.vbs')
$lines = foreach ($f in $files) { "  '$f' = '" + [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $HelperDir $f))) + "'" }
$tpl = [IO.File]::ReadAllText((Join-Path $HelperDir 'setup-template.ps1'), [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
$body = $tpl.Replace('__PAYLOAD__', ($lines -join "`r`n"))
$head = @(
  '@echo off',
  'rem Universal Widget Wallpaper helper setup. Everything below the marker is a readable PowerShell script.',
  'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$p=''%~f0'';$t=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8);$i=$t.LastIndexOf(''#=UWW-PAYLOAD=#'');& ([ScriptBlock]::Create($t.Substring($i+15))) -Self $p -Mode ''%~1''"',
  'exit /b',
  '#=UWW-PAYLOAD=#'
) -join "`r`n"
$all = ($head + "`r`n" + $body) -replace "(?<!`r)`n", "`r`n"
[IO.File]::WriteAllText($OutFile, $all, (New-Object Text.UTF8Encoding $false))
$h = (Get-FileHash $OutFile -Algorithm SHA256).Hash
"built: $OutFile  ({0:N0} KB)  SHA256 $h" -f ((Get-Item $OutFile).Length/1KB)
