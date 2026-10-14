Option Explicit

Dim shell, files, folder, scriptPath, statusPath, wmi
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
folder = files.GetParentFolderName(WScript.ScriptFullName)
scriptPath = files.BuildPath(folder, "generate_sky_dds.py")
statusPath = files.BuildPath(folder, "generate_sky_dds.status")

If WScript.Arguments.Count > 0 Then
    Select Case LCase(WScript.Arguments(0))
        Case "--watch"
            WatchGenerator
            WScript.Quit 0
        Case "--syntax-check"
            WScript.Quit 0
    End Select
End If

' The game waits only for this tiny launcher. A detached watcher owns Python and
' stops it if PAYDAY2.exe exits, so Alt+F4 cannot leave a background bake running.
On Error Resume Next
Set wmi = GetObject("winmgmts:\\.\root\cimv2")
If Err.Number <> 0 Then
    WriteStatus "ERROR Could not monitor PAYDAY 2 process: " & Err.Description
    WScript.Quit 1
End If
Err.Clear
If GeneratorRunning() Or WatcherRunning() Then WScript.Quit 0
If files.FileExists(statusPath) Then files.DeleteFile statusPath, True
Err.Clear
Dim watchCommand
watchCommand = Chr(34) & WScript.FullName & Chr(34) & " " & Chr(34) & WScript.ScriptFullName & Chr(34) & " --watch"
shell.Run watchCommand, 0, False
If Err.Number <> 0 Then WriteStatus "ERROR Could not start generator watcher: " & Err.Description
On Error GoTo 0

Sub WatchGenerator()
    Dim launchError, startTime, seenGame, gameState, result, doneTime

    On Error Resume Next
    Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    If Err.Number <> 0 Then
        WriteStatus "ERROR Could not monitor PAYDAY 2 process: " & Err.Description
        Exit Sub
    End If

    Err.Clear
    shell.Run "pyw.exe " & Chr(34) & scriptPath & Chr(34), 0, False
    launchError = Err.Number
    If launchError <> 0 Then
        WriteStatus "ERROR Could not start pyw.exe: " & Err.Description
        On Error GoTo 0
        Exit Sub
    End If
    On Error GoTo 0

    startTime = Now
    seenGame = False
    Do
        WScript.Sleep 1000

        result = ReadStatus()
        If Len(result) > 0 Then
            If Left(result, 4) = "DONE" Then
                ' Normally Python exits immediately after writing DONE. Clean up
                ' a lingering interpreter after a short grace period.
                doneTime = Now
                Do While GeneratorRunning() And DateDiff("s", doneTime, Now) < 10
                    If PaydayState() = 0 Then Exit Do
                    WScript.Sleep 500
                Loop
                If GeneratorRunning() Then StopGenerator
                Exit Do
            ElseIf Left(result, 5) = "ERROR" Or Left(result, 9) = "CANCELLED" Then
                Exit Do
            End If
        End If

        gameState = PaydayState()
        If gameState = 1 Then
            seenGame = True
        ElseIf gameState = 0 And (seenGame Or DateDiff("s", startTime, Now) >= 30) Then
            StopGenerator
            WriteStatus "CANCELLED PAYDAY 2 closed; rerun DDS generation to complete any partial outputs."
            Exit Do
        End If

        If Not GeneratorRunning() And DateDiff("s", startTime, Now) >= 15 Then
            WriteStatus "ERROR Python generator exited before writing a completion status."
            Exit Do
        End If
    Loop
End Sub

Function PaydayState()
    Dim processes
    On Error Resume Next
    Err.Clear
    Set processes = wmi.ExecQuery("SELECT ProcessId FROM Win32_Process WHERE Name='PAYDAY2.exe'")
    If Err.Number <> 0 Then
        Err.Clear
        PaydayState = -1
    ElseIf processes.Count > 0 Then
        PaydayState = 1
    Else
        PaydayState = 0
    End If
    On Error GoTo 0
End Function

Function GeneratorRunning()
    Dim processes, process, commandLine
    On Error Resume Next
    Err.Clear
    Set processes = wmi.ExecQuery("SELECT Name, CommandLine FROM Win32_Process WHERE Name='pythonw.exe' OR Name='pyw.exe'")
    If Err.Number <> 0 Then
        Err.Clear
        GeneratorRunning = True
    Else
        GeneratorRunning = False
        For Each process In processes
            commandLine = ""
            If Not IsNull(process.CommandLine) Then commandLine = LCase(CStr(process.CommandLine))
            If InStr(commandLine, LCase(scriptPath)) > 0 Then GeneratorRunning = True
        Next
    End If
    On Error GoTo 0
End Function

Function WatcherRunning()
    Dim processes, process, commandLine
    On Error Resume Next
    Err.Clear
    Set processes = wmi.ExecQuery("SELECT Name, CommandLine FROM Win32_Process WHERE Name='wscript.exe'")
    If Err.Number <> 0 Then
        Err.Clear
        WatcherRunning = True
    Else
        WatcherRunning = False
        For Each process In processes
            commandLine = ""
            If Not IsNull(process.CommandLine) Then commandLine = LCase(CStr(process.CommandLine))
            If InStr(commandLine, LCase(scriptPath)) > 0 And InStr(commandLine, "--watch") > 0 Then WatcherRunning = True
        Next
    End If
    On Error GoTo 0
End Function

Sub StopGenerator()
    Dim processes, process, commandLine
    On Error Resume Next
    Set processes = wmi.ExecQuery("SELECT Name, CommandLine FROM Win32_Process WHERE Name='pythonw.exe' OR Name='pyw.exe'")
    For Each process In processes
        commandLine = ""
        If Not IsNull(process.CommandLine) Then commandLine = LCase(CStr(process.CommandLine))
        If InStr(commandLine, LCase(scriptPath)) > 0 Then process.Terminate
    Next
    On Error GoTo 0
End Sub

Function ReadStatus()
    Dim statusFile
    ReadStatus = ""
    On Error Resume Next
    If files.FileExists(statusPath) Then
        Set statusFile = files.OpenTextFile(statusPath, 1, False)
        ReadStatus = Trim(statusFile.ReadAll)
        statusFile.Close
    End If
    On Error GoTo 0
End Function

Sub WriteStatus(message)
    Dim statusFile
    On Error Resume Next
    Set statusFile = files.CreateTextFile(statusPath, True)
    statusFile.Write message
    statusFile.Close
    On Error GoTo 0
End Sub
