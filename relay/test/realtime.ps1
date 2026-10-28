$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$dir=Join-Path $env:TEMP ('hm-input-'+[guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory -Path $dir)
$log=Join-Path $dir 'events.txt';$exe=Join-Path $dir 'input-fixture.exe'
$source=[IO.File]::ReadAllText((Join-Path $root 'agent/pointer.cs')).Replace('new NativeSink()','new FixtureSink()')+@'
namespace HelperPointer {
 public sealed class FixtureSink : IPointerSink,IKeyboardSink {
  string log=System.Environment.GetEnvironmentVariable("HELPER_POINTER_FIXTURE_LOG");
  public void Move(int x,int y){System.IO.File.AppendAllText(log,"move:"+x+":"+y+"\n");}
  public void Button(uint f){System.IO.File.AppendAllText(log,"button:"+f+"\n");}
  public void Key(int vk,bool ext,bool up){System.IO.File.AppendAllText(log,"key:"+vk+":"+up+"\n");}
 }
}
'@
Add-Type -TypeDefinition $source -OutputAssembly $exe -OutputType ConsoleApplication
function Assert($v,$why){if(-not $v){throw $why}}
$tcp=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$tcp.Start();$port=$tcp.LocalEndpoint.Port;$tcp.Stop()
$listener=New-Object Net.HttpListener;$listener.Prefixes.Add("http://127.0.0.1:$port/");$listener.Start()
$psi=New-Object Diagnostics.ProcessStartInfo $exe;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardInput=$true
$psi.EnvironmentVariables['HELPER_INPUT_RELAY']="http://127.0.0.1:$port";$psi.EnvironmentVariables['HELPER_INPUT_TOKEN']='fixture-only';$psi.EnvironmentVariables['HELPER_POINTER_FIXTURE_LOG']=$log
$p=[Diagnostics.Process]::Start($psi)
function Lines {if(Test-Path -LiteralPath $log){@(Get-Content -LiteralPath $log)}else{@()}}
function Wait-Count($count){$until=[DateTime]::UtcNow.AddSeconds(3);while(@(Lines).Count -lt $count -and [DateTime]::UtcNow -lt $until){Start-Sleep -Milliseconds 20};Assert (@(Lines).Count -eq $count) "Expected $count events; got $(@(Lines).Count)"}
try{
 $accept=$listener.GetContextAsync();Assert ($accept.Wait(10000)) 'input stream did not connect';$ctx=$accept.Result
 Assert ($ctx.Request.RawUrl -eq '/a/input') 'wrong endpoint';Assert ($ctx.Request.Headers['Authorization'] -eq 'Bearer fixture-only') 'missing authentication'
 $ctx.Response.ContentType='text/plain';$ctx.Response.SendChunked=$true
 $ctx.Response.Headers['x-input-clock']=[string][long]((([DateTime]::UtcNow.Ticks-621355968000000000)/10000)+3600000)
 $writer=New-Object IO.StreamWriter($ctx.Response.OutputStream);$writer.AutoFlush=$true;$writer.WriteLine('')
 $owner='a'*64;$gesture='b'*32
 function Send-Line($seq,$op,$x,$y=0,$age=0){$stamp=([DateTime]::UtcNow.Ticks-621355968000000000)/10000+3600000-$age;$writer.WriteLine(([long]$stamp).ToString()+'|'+"$owner $gesture $seq $op $x $y left v1")}
 Send-Line 1 'kdown' 162;Wait-Count 1
 Send-Line 2 'kdown' 37 1 3000;Start-Sleep -Milliseconds 100;Assert (@(Lines).Count -eq 1) 'stale command injected'
 Send-Line 3 'hover' 10 20;Wait-Count 2
 Send-Line 4 'kdown' 37 1;Wait-Count 3
 $writer.Dispose();$ctx.Response.Close();Wait-Count 5
 $events=@(Lines);Assert ($events -contains 'key:162:True') 'stream EOF left Ctrl held';Assert ($events -contains 'key:37:True') 'stream EOF left arrow held'
 $again=$listener.GetContextAsync();Assert ($again.Wait(5000)) 'worker did not reconnect';$ctx=$again.Result
 $ctx.Response.SendChunked=$true;$ctx.Response.Headers['x-input-clock']=[string][long]((([DateTime]::UtcNow.Ticks-621355968000000000)/10000)+3600000);$writer=New-Object IO.StreamWriter($ctx.Response.OutputStream);$writer.AutoFlush=$true;$writer.WriteLine('')
 Send-Line 5 'down' 10 20;Wait-Count 7
 $p.StandardInput.Close();Assert ($p.WaitForExit(3000)) 'parent EOF did not stop network worker';Wait-Count 8
 Assert ((@(Lines)|Select-Object -Last 1) -eq 'button:4') 'parent EOF left mouse held'
 Write-Output 'Persistent input: authenticated stream, stale-event drop, hover, reconnect, network EOF and parent EOF release PASS'
}finally{try{$writer.Dispose()}catch{};$listener.Stop();$listener.Close();if(-not $p.HasExited){$p.StandardInput.Close();[void]$p.WaitForExit(4000)};$p.Dispose()}
