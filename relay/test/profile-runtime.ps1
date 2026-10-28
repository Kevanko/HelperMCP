param([string]$CorePath=$env:HELPER_TEST_MIHOMO)
$ErrorActionPreference='Stop'
if(-not $CorePath){throw 'Set HELPER_TEST_MIHOMO or pass -CorePath for an already installed Mihomo; this test never downloads one'}
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$vendor=Join-Path $root 'agent/vendor/yamldotnet/YamlDotNet.dll'
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($vendor))
Add-Type -ReferencedAssemblies $vendor -TypeDefinition ([IO.File]::ReadAllText((Join-Path $root 'agent/profiles.cs')).Replace('__BUILD__','ProfileRun'))
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $root 'agent/network.cs')).Replace('__BUILD__','ProfileRun'))
function Ensure-ProfileParser { }
function Pump-Light { }
function Quote-Arg($s){'"'+$s+'"'}
function Assert($value,$message){if(-not $value){throw $message}}
$source=[IO.File]::ReadAllText((Join-Path $root 'agent/network.ps1'))
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$null,[ref]$null)
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Network-Targets'},$true)
Invoke-Expression $fn.Extent.Text.Replace('__BUILD__','ProfileRun')
Invoke-Expression ([IO.File]::ReadAllText((Join-Path $root 'agent/network-profile.ps1')).Replace('__BUILD__','ProfileRun'))
Add-Type -TypeDefinition @'
using System;using System.Net;using System.Net.Sockets;using System.Text;using System.Threading;using System.IO;using System.Net.Security;using System.Security.Cryptography;using System.Security.Cryptography.X509Certificates;
public sealed class VlessFixture : IDisposable {
 TcpListener listener; public int Port, Accepted, Denied, Requests; public volatile int HttpStatus=200;
 X509Certificate2 certificate;
 byte[] expected=new byte[]{0x11,0x11,0x11,0x11,0x22,0x22,0x33,0x33,0x44,0x44,0x55,0x55,0x55,0x55,0x55,0x55};
 public VlessFixture(){using(var rsa=RSA.Create(2048)){var req=new CertificateRequest("CN=fixture.target.invalid",rsa,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);using(var cert=req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1),DateTimeOffset.UtcNow.AddDays(1)))certificate=new X509Certificate2(cert.Export(X509ContentType.Pfx));}listener=new TcpListener(IPAddress.Loopback,0);listener.Start();Port=((IPEndPoint)listener.LocalEndpoint).Port;new Thread(Run){IsBackground=true}.Start();}
 static byte[] Read(NetworkStream stream,int n){var b=new byte[n];int off=0;while(off<n){int got=stream.Read(b,off,n-off);if(got==0)throw new Exception("EOF");off+=got;}return b;}
 void Run(){while(true){TcpClient c;try{c=listener.AcceptTcpClient();}catch{return;}ThreadPool.QueueUserWorkItem(_=>{using(c){try{
  c.ReceiveTimeout=5000;c.SendTimeout=5000;var s=c.GetStream();var h=Read(s,18);bool valid=h[0]==0;for(int i=0;i<16;i++)valid&=h[i+1]==expected[i];
  if(!valid){Interlocked.Increment(ref Denied);return;}Interlocked.Increment(ref Accepted);Read(s,h[17]);h=Read(s,4);if(h[0]!=1)return;
  Read(s,h[3]==1?4:h[3]==3?16:Read(s,1)[0]);s.Write(new byte[]{0,0},0,2);
  Stream io=s;if(h[1]==1&&h[2]==187){var tls=new SslStream(s,false);tls.AuthenticateAsServer(certificate,false,System.Security.Authentication.SslProtocols.Tls12,false);io=tls;}
  var text=new StringBuilder();while(text.Length<8192){int ch=io.ReadByte();if(ch<0)return;text.Append((char)ch);if(text.ToString().EndsWith("\r\n\r\n"))break;}
  if(!text.ToString().StartsWith("GET /health "))return;Interlocked.Increment(ref Requests);
  var body=Encoding.ASCII.GetBytes("profile-body");var header=Encoding.ASCII.GetBytes("HTTP/1.1 "+HttpStatus+" Fixture\r\nContent-Length: "+body.Length+"\r\nConnection: close\r\n\r\n");io.Write(header,0,header.Length);io.Write(body,0,body.Length);
 }catch{}}});}}
 public void Dispose(){listener.Stop();}
}
'@
$fixture=New-Object VlessFixture
$dir=Join-Path $env:TEMP ('hm-profile-runtime-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $dir)
$file=Join-Path $dir 'export.yaml'
$coreName=[IO.Path]::GetFileNameWithoutExtension($CorePath)
$existing=@([Diagnostics.Process]::GetProcessesByName($coreName)|ForEach-Object Id)
$proxyBefore=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'|Select-Object ProxyEnable,ProxyServer,AutoConfigURL|ConvertTo-Json -Compress
$tempBefore=@(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'helper-profile-*'|ForEach-Object FullName)
try{
 $text='proxies: [{name: SECRET_LABEL, type: vless, server: 127.0.0.1, port: '+$fixture.Port+', uuid: 11111111-2222-3333-4444-555555555555, network: tcp, tls: false}]'
 [IO.File]::WriteAllText($file,$text)
 $args=@{config_path=$file;core_path=$CorePath;profile_index=0;interface_index=0;urls=@('http://fixture.target.invalid/health');profile_timeout_s=5;samples=1}
 $result=Do-ProfileCheck $args;$good=$result.text|ConvertFrom-Json
 Assert ($good.status -eq 'profile_http_verified') ('valid profile failed: '+$result.text)
 Assert ($good.results[0].status -eq 200 -and $good.results[0].bytes -eq 12 -and $good.results[0].through_owned_proxy) 'HTTP payload was not measured through the owned core'
 Assert ($fixture.Accepted -gt 0 -and $fixture.Requests -gt 0) 'VLESS fixture did not authenticate and receive a real request'
 Assert ($result.text -notmatch '11111111|SECRET_LABEL|uuid|password') 'profile credentials/label leaked'
 Assert ($good.cleanup_complete -and [IO.File]::ReadAllText($file) -eq $text) 'export changed or cleanup incomplete'
 $fixture.HttpStatus=403
 $rejected=(Do-ProfileCheck $args).text|ConvertFrom-Json
 Assert ($rejected.results[0].status -eq 403 -and $rejected.status -ne 'profile_http_verified') 'target HTTP rejection lost or classified as working'
 $fixture.HttpStatus=200
 $previous=[Net.ServicePointManager]::ServerCertificateValidationCallback
 try{
  Add-Type -TypeDefinition 'public static class UnsafeTlsFixture { public static void Set(){System.Net.ServicePointManager.ServerCertificateValidationCallback=(s,c,h,e)=>true;} }'
  [UnsafeTlsFixture]::Set();$args.urls=@('https://fixture.target.invalid/health')
  $tls=(Do-ProfileCheck $args).text|ConvertFrom-Json
  Assert ($tls.status -ne 'profile_http_verified' -and $tls.cleanup_complete) 'self-signed TLS accepted through an inherited unsafe callback'
 }finally{[Net.ServicePointManager]::ServerCertificateValidationCallback=$previous;$args.urls=@('http://fixture.target.invalid/health')}
 [IO.File]::WriteAllText($file,$text.Replace('555555555555','666666666666'))
 $result=Do-ProfileCheck $args;$bad=$result.text|ConvertFrom-Json
 Assert ($bad.status -ne 'profile_http_verified' -and $fixture.Denied -gt 0) 'wrong UUID classified as working VPN'
 Assert $bad.cleanup_complete 'failed profile left its private config/process behind'
 foreach($id in $existing){Assert (Get-Process -Id $id -ErrorAction SilentlyContinue) 'pre-existing client was stopped'}
 Assert (@([Diagnostics.Process]::GetProcessesByName($coreName)|Where-Object{$existing -notcontains $_.Id}).Count -eq 0) 'diagnostic core process leaked'
 $proxyAfter=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'|Select-Object ProxyEnable,ProxyServer,AutoConfigURL|ConvertTo-Json -Compress
 Assert ($proxyBefore -eq $proxyAfter) 'Windows proxy settings changed'
 $new=@(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'helper-profile-*'|Where-Object{$tempBefore -notcontains $_.FullName})
 Assert ($new.Count -eq 0) 'diagnostic profile directory leaked'
 Write-Output ('REAL installed Mihomo/VLESS auth: HTTP200/12bytes, HTTP403 retained, invalid TLS and wrong UUID rejected, Windows proxy/export unchanged, original client alive, owned config/processes cleaned PASS; accepted='+$fixture.Accepted+' denied='+$fixture.Denied)
}finally{$fixture.Dispose();Remove-Item -LiteralPath $dir -Recurse -Force}
