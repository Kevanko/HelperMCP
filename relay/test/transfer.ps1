$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'agent/agent.ps1'),[ref]$null,[ref]$errors)
if($errors){throw 'Agent parser failed'}
foreach($name in 'Full','Do-PushFile'){
 $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 Invoke-Expression $fn.Extent.Text.Replace('__BUILD__','TransferQa')
}
function Pump-Light{}
Add-Type -TypeDefinition @'
using System;using System.Net;using System.Threading;
namespace FTransferQa { public static class Fs {public static string Human(long n){return n+" bytes";}} }
public sealed class TransferFixture : IDisposable {
 readonly HttpListener listener=new HttpListener();readonly Thread thread;public string Url;
 public TransferFixture(int port){Url="http://127.0.0.1:"+port+"/";listener.Prefixes.Add(Url);listener.Start();thread=new Thread(delegate(){while(listener.IsListening){try{var c=listener.GetContext();byte[] b=System.Text.Encoding.UTF8.GetBytes("Transfer fixture: data must stay exact.");c.Response.ContentLength64=b.Length;c.Response.OutputStream.Write(b,0,b.Length);c.Response.Close();}catch{}}});thread.IsBackground=true;thread.Start();}
 public void Dispose(){listener.Stop();listener.Close();thread.Join(2000);}
}
'@
function Assert($v,$why){if(-not $v){throw $why}}
$tcp=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$tcp.Start();$port=$tcp.LocalEndpoint.Port;$tcp.Stop()
$fixture=New-Object TransferFixture($port)
$dir=Join-Path $env:TEMP ('hm-transfer-'+[guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory -Path $dir)
try{
 $dest=Join-Path $dir 'Тестовый файл.txt';[IO.File]::WriteAllText($dest,'original must survive')
 $r=Do-PushFile @{path=$dest;url=$fixture.Url;unique=$true}
 Assert ($r.path -eq (Join-Path $dir 'Тестовый файл (1).txt')) 'collision did not select new filename'
 Assert ([IO.File]::ReadAllText($dest) -eq 'original must survive') 'drop overwrote existing file'
 Assert ([IO.File]::ReadAllText($r.path) -eq 'Transfer fixture: data must stay exact.') 'copied bytes differ'
 $r2=Do-PushFile @{path=$dest;url=$fixture.Url;unique=$true}
 Assert ($r2.path -eq (Join-Path $dir 'Тестовый файл (2).txt')) 'second collision failed'
 Assert (@(Get-ChildItem -LiteralPath $dir -Force|Where-Object{$_.Extension -eq '.part'}).Count -eq 0) 'temporary data remained'
 Write-Output 'File transfer: Unicode filename, exact bytes, unique names, no overwrite and temporary cleanup PASS'
}finally{$fixture.Dispose();Remove-Item -LiteralPath $dir -Recurse -Force}
