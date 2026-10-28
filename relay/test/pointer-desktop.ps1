# Optional interactive integration test. Uses only its own temporary WinForms
# surface; never include in unattended/CI suites or run during another UI task.
$ErrorActionPreference='Stop'
if($env:HELPER_POINTER_DESKTOP_TEST -ne '1'){throw 'Explicit HELPER_POINTER_DESKTOP_TEST=1 required for the visible desktop fixture'}
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class PointerDesktopCheck {
 [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
[void][PointerDesktopCheck]::SetProcessDPIAware()
foreach($key in 1,2,4,16,17,18){if([PointerDesktopCheck]::GetAsyncKeyState($key) -band 0x8000){throw 'Desktop input is busy; fixture did not move or click'}}
$oldCursor=[Windows.Forms.Cursor]::Position;$oldForeground=[PointerDesktopCheck]::GetForegroundWindow()
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$dir=Join-Path $env:TEMP ('hm-pointer-desktop-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $dir)
$ready=Join-Path $dir 'ready.json';$events=Join-Path $dir 'events.json';$stop=Join-Path $dir 'stop'
$hostFile=Join-Path $dir 'surface.ps1'
$hostCode=@'
param($Dir)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$form=New-Object Windows.Forms.Form
$form.Text='Helper pointer integration fixture';$form.TopMost=$true;$form.Width=500;$form.Height=300
$form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedToolWindow'
$panel=New-Object Windows.Forms.Panel;$panel.Dock='Fill';$panel.BackColor=[Drawing.Color]::FromArgb(15,45,30)
$form.Controls.Add($panel)
$script:rows=New-Object Collections.ArrayList
function Record($kind,$event){
 [void]$script:rows.Add(@{kind=$kind;x=$event.X;y=$event.Y;button=[string]$event.Button})
 [IO.File]::WriteAllText((Join-Path $Dir 'events.json'),(@($script:rows)|ConvertTo-Json -Compress))
}
$panel.Add_MouseDown({Record 'down' $_});$panel.Add_MouseUp({Record 'up' $_})
$panel.Add_MouseMove({if($_.Button -eq [Windows.Forms.MouseButtons]::Left){Record 'held-move' $_}})
$form.Add_Shown({
 $p=$panel.PointToScreen([Drawing.Point]::Empty)
 [IO.File]::WriteAllText((Join-Path $Dir 'ready.json'),(@{x=$p.X;y=$p.Y;width=$panel.Width;height=$panel.Height;handle=$form.Handle.ToInt64()}|ConvertTo-Json -Compress))
})
$timer=New-Object Windows.Forms.Timer;$timer.Interval=100
$timer.Add_Tick({if(Test-Path -LiteralPath (Join-Path $Dir 'stop')){$form.Close()}});$timer.Start()
try{[Windows.Forms.Application]::Run($form)}finally{$timer.Dispose();$form.Dispose()}
'@
[IO.File]::WriteAllText($hostFile,$hostCode,(New-Object Text.UTF8Encoding $true))
$payload="& '$($hostFile.Replace("'","''"))' '$($dir.Replace("'","''"))'"
$psi=New-Object Diagnostics.ProcessStartInfo "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$psi.Arguments='-NoProfile -STA -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
$surface=[Diagnostics.Process]::Start($psi);$bounds=$null
$script:PointerProc=$null;$script:PointerExe=$null;$StateDir=$dir;$script:Mode='auto'
function Test-Admin{$false}
function Quote-Arg($s){'"'+$s+'"'}
$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'agent/agent.ps1'),[ref]$null,[ref]$errors)
if($errors){throw 'Agent parser failed'}
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Do-ViewerPointer'},$true)
$bytes=[IO.File]::ReadAllBytes((Join-Path $root 'agent/pointer.cs'))
Invoke-Expression $fn.Extent.Text.Replace('__POINTER_CS_B64__',[Convert]::ToBase64String($bytes))
try{
 $until=[DateTime]::UtcNow.AddSeconds(10)
 while(-not $bounds -and [DateTime]::UtcNow -lt $until){try{$bounds=Get-Content -LiteralPath $ready -Raw|ConvertFrom-Json}catch{Start-Sleep -Milliseconds 50}}
 if(-not $bounds){throw 'Own fixture surface was not ready'}
 $a=@{owner='a'*64;gesture='b'*32;seq=1;op='down';x=([int]$bounds.x+40);y=([int]$bounds.y+80);button='left'}
 if((Do-ViewerPointer $a).text -ne 'held'){throw 'Native down failed'}
 Start-Sleep -Milliseconds 100
 foreach($offset in 100,180,260){$a.op='move';$a.seq++;$a.x=[int]$bounds.x+$offset;[void](Do-ViewerPointer $a);Start-Sleep -Milliseconds 80}
 # No keep/up: verify actual native lease expiry in the own fixture window.
 Start-Sleep -Milliseconds 3350
 $rows=Get-Content -LiteralPath $events -Raw|ConvertFrom-Json
 $down=@($rows|Where-Object{$_.kind -eq 'down'}).Count
 $moving=@($rows|Where-Object{$_.kind -eq 'held-move'}).Count
 $up=@($rows|Where-Object{$_.kind -eq 'up'}).Count
 if($down -ne 1 -or $moving -lt 2 -or $up -ne 1){throw 'Own surface did not receive native down/held moves/timeout up'}
 if([PointerDesktopCheck]::GetAsyncKeyState(1) -band 0x8000){throw 'Native button still held after expiry'}
 Write-Output ("REAL Windows desktop pointer PASS: down=$down heldMoves=$moving timeoutUp=$up; fixture=$dir")
}finally{
 if($script:PointerProc){try{$script:PointerProc.StandardInput.Close();[void]$script:PointerProc.WaitForExit(4000)}catch{};$script:PointerProc.Dispose()}
 $fg=[PointerDesktopCheck]::GetForegroundWindow();$cursor=[Windows.Forms.Cursor]::Position
 if($bounds -and $cursor.X -ge $bounds.x -and $cursor.X -lt $bounds.x+$bounds.width -and $cursor.Y -ge $bounds.y -and $cursor.Y -lt $bounds.y+$bounds.height){[Windows.Forms.Cursor]::Position=$oldCursor}
 [IO.File]::WriteAllText($stop,'stop');if(-not $surface.WaitForExit(3000)){$surface.Kill()};$surface.Dispose()
 if($bounds -and $fg.ToInt64() -eq $bounds.handle){[void][PointerDesktopCheck]::SetForegroundWindow($oldForeground)}
}
