$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$dir=Join-Path $env:TEMP ('hm-pointer-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $dir)
$exe=Join-Path $dir 'pointer-fixture.exe';$log=Join-Path $dir 'events.txt'
$source=[IO.File]::ReadAllText((Join-Path $root 'agent/pointer.cs'))
# Replace only the native sink factory. The real worker, protocol, timer and
# process lifetime run unchanged; no user32 call can reach the working desktop.
if(($source.Split(@('Run(new NativeSink());'),[StringSplitOptions]::None)).Count -ne 2){throw 'Unexpected pointer factory'}
$source=$source.Replace('Run(new NativeSink());','Run(new FixtureSink());')+@'
namespace HelperPointer {
 public sealed class FixtureSink : IPointerSink,IKeyboardSink {
  string log=System.Environment.GetEnvironmentVariable("HELPER_POINTER_FIXTURE_LOG");
  public void Move(int x,int y){System.IO.File.AppendAllText(log,"move:"+x+":"+y+"\n");}
  public void Button(uint f){System.IO.File.AppendAllText(log,"button:"+f+"\n");}
  public void Key(int vk,bool extended,bool up){System.IO.File.AppendAllText(log,"key:"+vk+":"+up+"\n");}
 }
}
'@
Add-Type -TypeDefinition $source -OutputAssembly $exe -OutputType ConsoleApplication
function Assert($v,$message){if(-not $v){throw $message}}
function Start-Worker {
    $psi=New-Object Diagnostics.ProcessStartInfo $exe
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true
    $psi.EnvironmentVariables['HELPER_POINTER_FIXTURE_LOG']=$log
    [Diagnostics.Process]::Start($psi)
}
$owner='a'*64;$gesture='b'*32
function Send($p,$seq,$op,$who=$owner){
    $p.StandardInput.WriteLine("$who $gesture $seq $op 10 20 left v1");$p.StandardInput.Flush()
    $r=$p.StandardOutput.ReadLineAsync();Assert ($r.Wait(2000)) 'pointer response timeout';$r.Result
}
function Buttons{if(Test-Path -LiteralPath $log){@(Get-Content -LiteralPath $log | Where-Object{$_ -like 'button:*'})}else{@()}}
$p=Start-Worker
try{
    Assert ((Send $p 1 'down') -eq 'OK held') 'down failed'
    Assert ((Send $p 1 'down') -eq 'OK duplicate') 'duplicate down not ignored'
    Assert ((@(Buttons) -join ',') -eq 'button:2') 'duplicate down injected again'
    Start-Sleep -Milliseconds 3350
    Assert ((@(Buttons) -join ',') -eq 'button:2,button:4') 'independent timer did not release idle pointer'
    Assert ((Send $p 2 'move') -like 'ERR *expired*') 'expired move renewed a held gesture'
    Assert ((Send $p 3 'down') -eq 'OK held') 'second down failed'
    Assert ((Send $p 1 'release' ('c'*64)) -eq 'OK released') 'other owner release failed'
    Assert (@(Buttons).Count -eq 3) 'other owner released current pointer'
    Start-Sleep -Milliseconds 1800
    Assert ((Send $p 4 'keep') -eq 'OK held') 'keep failed'
    Start-Sleep -Milliseconds 1800
    Assert (@(Buttons).Count -eq 3) 'timer ignored valid keepalive'
    Assert ((Send $p 5 'up') -eq 'OK released') 'up failed'
    Assert ((Send $p 10 'cancel') -eq 'OK released') 'cancel failed'
    Assert ((Send $p 9 'down') -eq 'OK duplicate') 'late down after cancellation was re-injected'
    Assert ((Send $p 11 'down') -eq 'OK held') 'EOF down failed'
    $p.StandardInput.Close();Assert ($p.WaitForExit(2000)) 'worker did not exit on EOF'
    Assert ((@(Buttons) -join ',') -eq 'button:2,button:4,button:2,button:4,button:2,button:4') 'EOF did not release held button'
    Write-Output 'Pointer worker: real timer expiry, keepalive, owner isolation, stale sequence and EOF release PASS'
}finally{if(-not $p.HasExited){$p.StandardInput.Close();[void]$p.WaitForExit(4000)};$p.Dispose()}
$p=Start-Worker
try{
 Assert ((Send $p 1 'kdown') -eq 'OK held') 'worker keyboard down failed'
 $p.StandardInput.Close();Assert ($p.WaitForExit(2000)) 'keyboard EOF exit failed'
 $keys=@(Get-Content -LiteralPath $log|Where-Object{$_ -like 'key:*'})
 Assert (($keys -join ',') -eq 'key:10:False,key:10:True') 'EOF left keyboard held'
 Write-Output 'Native keyboard worker protocol and EOF release PASS'
}finally{if(-not $p.HasExited){$p.StandardInput.Close();[void]$p.WaitForExit(4000)};$p.Dispose()}

# A real parent dies without disposing its child; the independent worker must
# observe the closed pipe and release. Only this fixture's processes are used.
$pidFile=Join-Path $dir 'worker.pid'
$payload=@"
`$psi=New-Object Diagnostics.ProcessStartInfo '$($exe.Replace("'","''"))'
`$psi.UseShellExecute=`$false;`$psi.CreateNoWindow=`$true;`$psi.RedirectStandardInput=`$true;`$psi.RedirectStandardOutput=`$true
`$psi.EnvironmentVariables['HELPER_POINTER_FIXTURE_LOG']='$($log.Replace("'","''"))'
`$child=[Diagnostics.Process]::Start(`$psi)
`$child.StandardInput.WriteLine('$owner $gesture 1 down 10 20 right v1');`$child.StandardInput.Flush()
`$null=`$child.StandardOutput.ReadLine()
[IO.File]::WriteAllText('$($pidFile.Replace("'","''"))',[string]`$child.Id)
Start-Sleep -Seconds 60
"@
$psi=New-Object Diagnostics.ProcessStartInfo "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$psi.Arguments='-NoProfile -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
$parent=[Diagnostics.Process]::Start($psi)
try{
    $until=[DateTime]::UtcNow.AddSeconds(10)
    while(-not (Test-Path -LiteralPath $pidFile) -and [DateTime]::UtcNow -lt $until){Start-Sleep -Milliseconds 50}
    Assert (Test-Path -LiteralPath $pidFile) 'fixture parent never started worker'
    $workerPid=[int][IO.File]::ReadAllText($pidFile)
    $parent.Kill();[void]$parent.WaitForExit(2000)
    $until=[DateTime]::UtcNow.AddSeconds(4)
    while((@(Buttons) | Select-Object -Last 1) -ne 'button:16' -and [DateTime]::UtcNow -lt $until){Start-Sleep -Milliseconds 50}
    Assert ((@(Buttons) | Select-Object -Last 1) -eq 'button:16') 'parent death left button held'
    $worker=Get-Process -Id $workerPid -ErrorAction SilentlyContinue
    if($worker){try{Assert ($worker.WaitForExit(2000)) 'orphan pointer worker did not exit'}finally{$worker.Dispose()}}
    Write-Output 'Pointer worker survives abrupt parent exit and releases held button PASS'
}finally{if(-not $parent.HasExited){$parent.Kill()};$parent.Dispose()}
