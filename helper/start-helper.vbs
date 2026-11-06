' Starts the media helper without a window (double-click), and starts it again if it ever stops.
' Only one copy of this script keeps watching; a second copy just makes sure the helper is running and ends.
Option Explicit
On Error Resume Next
Dim fso, sh, dir, ps1, cmd, wmi, procs, p, n, i
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = dir & "\media-helper.ps1"
cmd = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & ps1 & """"

Function HelperAlive()
    Dim x
    HelperAlive = False
    On Error Resume Next
    Set x = CreateObject("MSXML2.ServerXMLHTTP.6.0")
    x.setTimeouts 3000, 3000, 5000, 5000
    x.open "GET", "http://localhost:39217/ping", False
    x.send
    If Err.Number = 0 Then
        If x.status = 200 Then HelperAlive = True
    End If
    Err.Clear
End Function

Sub StartHelper()
    If fso.FileExists(ps1) Then sh.Run cmd, 0, False
End Sub

' is another copy of this script already watching?
n = 0
Set wmi = GetObject("winmgmts:\\.\root\cimv2")
Set procs = wmi.ExecQuery("SELECT CommandLine FROM Win32_Process WHERE Name='wscript.exe'")
For Each p In procs
    If InStr(1, p.CommandLine, "start-helper.vbs", vbTextCompare) > 0 Then n = n + 1
Next
If Err.Number <> 0 Then n = 1: Err.Clear

If Not HelperAlive() Then StartHelper
If n > 1 Then WScript.Quit

' watch: check every 30 seconds and start the helper again when it is not answering
Do
    WScript.Sleep 30000
    If Not fso.FileExists(ps1) Then WScript.Quit
    If Not HelperAlive() Then
        ' answer may be slow while a file picker is open; ask once more before starting
        WScript.Sleep 5000
        If Not HelperAlive() Then StartHelper
    End If
Loop
