$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source = [IO.File]::ReadAllText((Join-Path $root 'agent/network.cs')).Replace('__BUILD__', 'Test')
Add-Type -TypeDefinition $source
function Assert($condition, $message) { if (-not $condition) { throw $message } }

# Loopback fixtures exercise actual sockets without depending on public websites.
Add-Type -TypeDefinition @'
using System; using System.Net; using System.Net.Sockets; using System.Net.Security;
using System.Threading; using System.Text; using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
public class NetFixture : IDisposable {
  TcpListener listener; public int Port; string mode; Thread thread;
  public volatile bool Healthy = true, ValidHealth = true; public X509Certificate2 Certificate;
  public NetFixture(string mode) : this(mode, 0) { }
  public NetFixture(string mode, int port) {
    if (mode == "relay") using (var rsa = RSA.Create(2048)) {
      var request = new CertificateRequest("CN=localhost", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
      using (var cert = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1))) Certificate = new X509Certificate2(cert.Export(X509ContentType.Pfx));
    }
    this.mode = mode; listener = new TcpListener(IPAddress.Loopback, port); listener.Start();
    Port = ((IPEndPoint)listener.LocalEndpoint).Port;
    thread = new Thread(Run) { IsBackground = true }; thread.Start();
  }
  void Run() {
    while (true) {
      TcpClient c; try { c = listener.AcceptTcpClient(); } catch { return; }
      ThreadPool.QueueUserWorkItem(_ => { using(c) { try {
        if (mode == "stall") { Thread.Sleep(2000); return; }
        if (mode == "upload-stall") { Thread.Sleep(20000); return; }
        if (mode == "close") return;
        if (mode == "relay") {
          using (var tls = new SslStream(c.GetStream())) {
            tls.AuthenticateAsServer(Certificate, false, System.Security.Authentication.SslProtocols.Tls12, false); tls.ReadTimeout = 2000; var req = new byte[8192]; tls.Read(req, 0, req.Length);
            var response = Encoding.ASCII.GetBytes("HTTP/1.1 " + (Healthy ? "200 OK" : "503 Unavailable") + "\r\nContent-Length: 2\r\nConnection: close\r\n\r\n" + (ValidHealth ? "ok" : "NO")); tls.Write(response, 0, response.Length);
          }
          return;
        }
        if (mode == "tls") {
          using (var rsa = RSA.Create(2048)) {
            var req = new CertificateRequest("CN=localhost", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            using (var cert = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1)))
            using (var stream = new SslStream(c.GetStream())) stream.AuthenticateAsServer(cert);
          }
          return;
        }
        var s = c.GetStream(); s.ReadTimeout = 1000; var b = new byte[4096];int received=s.Read(b, 0, b.Length);
        if(mode=="api"){
          string headers=Encoding.ASCII.GetString(b,0,received);int end=headers.IndexOf("\r\n\r\n");
          while(end<0){int read=s.Read(b,received,b.Length-received);if(read==0)throw new Exception("Incomplete request");received+=read;headers=Encoding.ASCII.GetString(b,0,received);end=headers.IndexOf("\r\n\r\n");}
          var length=System.Text.RegularExpressions.Regex.Match(headers.Substring(0,end),@"(?im)^Content-Length:\s*(\d+)");
          int wanted=end+4+(length.Success?int.Parse(length.Groups[1].Value):0);
          while(received<wanted){int read=s.Read(b,0,Math.Min(b.Length,wanted-received));if(read==0)throw new Exception("Incomplete body");received+=read;}
        }
        var data = Encoding.ASCII.GetBytes(mode == "chunked" ? "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n2\r\nhe\r\n3\r\nllo\r\n0\r\n\r\n" : "HTTP/1.1 " + (mode == "deny" ? "403 Forbidden" : "200 OK") + "\r\nContent-Length: " + (mode == "truncated" ? "100" : "5") + "\r\nConnection: close\r\n\r\nhello"); s.Write(data, 0, data.Length);
      } catch { } } });
    }
  }
  public void Dispose() { listener.Stop(); }
  public static void TrustFixtures(X509Certificate2 a, X509Certificate2 b) {
    ServicePointManager.ServerCertificateValidationCallback = (sender, cert, chain, errors) => cert != null && (cert.GetCertHashString() == a.Thumbprint || cert.GetCertHashString() == b.Thumbprint);
  }
}
'@
$path = [NTest.Network]::Paths(0, $false)[0]
$target = New-Object 'NTest.Network+Target' -Property @{ host = '127.0.0.1'; port = 1; http = $true }
Assert ([NTest.Network]::Fake('198.18.0.2')) 'fake-IP detection'
Assert ([NTest.Network]::Fake('198.19.255.1')) 'whole /15 must be detected'
Assert (-not [NTest.Network]::Fake('198.20.0.2')) 'real IP misclassified'
try { [NTest.Network]::Paths(2147483647, $false); throw 'missing adapter silently fell back' } catch { Assert ($_.Exception.Message -match 'Adapter is down') 'missing adapter error' }
$fake = [NTest.Network]::Resolve($path, 'example.com', '198.18.0.2', 300)
Assert ($fake.error -and -not $fake.addresses.Count) 'fake DNS not rejected'
foreach ($mode in 'ok','deny','close','stall','tls','chunked','truncated') {
    $fixture = New-Object NetFixture $mode
    try {
        $target.port = $fixture.Port; $target.tls = $mode -eq 'tls'
        $r = [NTest.Network]::Probe($path, $target, '127.0.0.1', 400, 4096)
        if ($mode -eq 'ok') { Assert ($r.status -eq 200 -and $r.bytes -eq 5 -and -not $r.error) 'body/status not measured' }
        if ($mode -eq 'deny') {
            $r = [NTest.Network]::Check($path, $target, 1, 400, $false, '', [DateTime]::UtcNow.AddSeconds(4))
            Assert ($r.samples[0].status -eq 403 -and ($r.findings -join ' ') -match 'not working application') '403 presented as working access'
        }
        if ($mode -eq 'close') { Assert ($r.error -and $r.stage -eq 'http' -and $r.tcp_ms -ge 0) 'EOF classified as success or TCP failure' }
        if ($mode -eq 'stall') { Assert ($r.error -and $r.total_ms -lt 1800) 'socket timeout unbounded' }
        if ($mode -eq 'tls') { Assert ($r.error -and $r.stage -eq 'tls' -and $r.tcp_ms -ge 0) 'TLS certificate validation bypassed' }
        if ($mode -eq 'chunked') { Assert ($r.bytes -eq 5 -and -not $r.error) 'chunk framing counted as payload' }
        if ($mode -eq 'truncated') { Assert ($r.error -and $r.stage -eq 'body') 'truncated body presented as success' }
        Write-Output "network fixture $mode PASS"
    } finally { $fixture.Dispose() }
}

$stall = New-Object NetFixture 'stall'
try {
    $target.port = $stall.Port; $target.tls = $false
    $task = [NTest.Network]::StartBatch(@($path), @($target), 5, 3000, $false, '1.1.1.1')
    Start-Sleep -Milliseconds 150
    [NTest.Network]::CancelWork()
    Assert ($task.Wait(1000)) 'cancel did not interrupt diagnostic sockets'
    Write-Output 'network cancellation PASS'
} finally { $stall.Dispose() }

# Compile the exact embedded PowerShell payload, without starting the desktop agent.
$ps = [IO.File]::ReadAllText((Join-Path $root 'agent/network.ps1')).Replace('__BUILD__','Test')
$ps = $ps.Replace('__NETWORK_CS__', $source).Replace('__RKN_RUNNER_B64__', [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root 'agent/rkn_runner.py'))))
$ps = $ps.Replace('__NETWORK_PROFILE_PS__', [IO.File]::ReadAllText((Join-Path $root 'agent/network-profile.ps1')))
$errors = $null
[Management.Automation.Language.Parser]::ParseInput($ps, [ref]$null, [ref]$errors) | Out-Null
Assert (-not $errors) ($errors | Out-String)
Invoke-Expression $ps
$t = @(Network-Targets @{ urls = @('https://example.com/test') })
Assert ($t.Count -eq 1 -and $t[0].path -eq '/test' -and $t[0].tls) 'URL target conversion'
try { Network-Targets @{ urls = @('https://example.com/sub?token=secret') }; throw 'URL secret accepted' } catch { Assert ($_.Exception.Message -match 'without credentials') 'URL validation' }
Write-Output 'network payload and validation PASS'

# Compile the original route transport, then fail only our TLS relay fixture.
$agentSource = [IO.File]::ReadAllText((Join-Path $root 'agent/agent.ps1'))
$match = [regex]::Match($agentSource, '(?s)Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -TypeDefinition @"\r?\n.*?\r?\n"@')
Assert $match.Success 'route C# source not found'
$module = [IO.File]::ReadAllText((Join-Path $root 'agent/network.cs'))
Invoke-Expression ($match.Value.Replace('__NETWORK_SHARED_CS__', $module).Replace('__VIDEO_SHARED_CS__',[IO.File]::ReadAllText((Join-Path $root 'agent/video.cs'))).Replace('__BUILD__','RouteQa'))
$uploadStall=New-Object NetFixture 'upload-stall'
$request=[Net.HttpWebRequest]::Create('https://127.0.0.1:'+$uploadStall.Port+'/a/stream')
$request.Method='POST';$request.SendChunked=$true;$request.AllowWriteStreamBuffering=$false;$request.Timeout=-1
$request.ServicePoint.Expect100Continue=$false
$timer=[Diagnostics.Stopwatch]::StartNew();$timedOut=$false
try {
    $open=[FRouteQa.Live].GetMethod('OpenUpload',[Reflection.BindingFlags]'NonPublic,Static')
    try { $stream=$open.Invoke($null,@($request));$stream.Dispose() }
    catch { $timedOut=$_.Exception.GetBaseException() -is [TimeoutException] }
    Assert $timedOut 'dead TLS upload handshake did not stop at the connection deadline'
    Assert ($timer.Elapsed.TotalSeconds -ge 14 -and $timer.Elapsed.TotalSeconds -lt 19) 'upload handshake deadline outside expected bounds'
    Write-Output 'Video upload connection deadline remains bounded without an overall stream lifetime limit PASS'
} finally { $request.Abort();$uploadStall.Dispose() }
$apiFixture=New-Object NetFixture 'api'
try{
 $url='http://127.0.0.1:'+$apiFixture.Port+'/api'
 $reply=[FRouteQa.RelayApi]::Request($url,$null,$null,'fixture',3)
 Assert ($reply.StatusCode -eq 200 -and $reply.Content -eq 'hello') 'native relay GET'
 $reply=[FRouteQa.RelayApi]::Request($url,[Text.Encoding]::UTF8.GetBytes('{"input":"test"}'),$null,'fixture',3)
 Assert ($reply.StatusCode -eq 200 -and $reply.Content -eq 'hello') 'native relay POST'
 Write-Output 'Native relay API GET/POST and complete response disposal PASS'
}finally{$apiFixture.Dispose()}
$primary = New-Object NetFixture 'relay'
$backup = $null
try {
    $backup = New-Object NetFixture 'relay',9444
    [NetFixture]::TrustFixtures($primary.Certificate, $backup.Certificate)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # .NET bypasses proxies for literal loopback URLs. Use an unresolvable test
    # hostname and inject only its cached address, without touching hosts/DNS.
    $flags = [Reflection.BindingFlags]'NonPublic,Static'
    [FRouteQa.Route].GetField('lastIp', $flags).SetValue($null, '127.0.0.1')
    [FRouteQa.Route].GetField('ipUntil', $flags).SetValue($null, [DateTime]::MaxValue)
    [FRouteQa.Route]::Init("https://fixture.helper.test:$($primary.Port)", '', $null)
    Assert ([FRouteQa.Route]::Status() -notmatch 'relay port 9444') 'unexpected startup fallback'
    $primary.Healthy = $false
    [FRouteQa.Route]::Streaming = $true
    [FRouteQa.Route]::Failed()
    $until = [DateTime]::UtcNow.AddSeconds(25)
    while ([FRouteQa.Route]::Status() -notmatch 'relay port 9444' -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 100 }
    Assert ([FRouteQa.Route]::Status() -match 'relay port 9444') ('did not recover onto validated alternate TLS endpoint: ' + [FRouteQa.Route]::Status() + '; ' + ([FRouteQa.Route]::Drain() -join ' | '))
    $type = [FRouteQa.Route]; $flags = [Reflection.BindingFlags]'NonPublic,Static'
    $candidateType = $type.GetNestedType('Cand', [Reflection.BindingFlags]'NonPublic')
    $candidate = [Activator]::CreateInstance($candidateType, $true)
    $candidate.Key = 'def'; $candidate.Name = 'test primary'; $candidate.Endpoint = $primary.Port
    $oldProxy = [FRouteQa.Route]::Proxy.GetProxy([Uri]"https://fixture.helper.test:$($primary.Port)").Port
    $primary.Healthy = $true
    $probe = $type.GetMethod('Probe', $flags).Invoke($null, @($candidate, 2000))
    Assert ($probe -gt 0) 'primary fixture did not recover'
    $primary.ValidHealth = $false
    Assert ($type.GetMethod('Probe', $flags).Invoke($null, @($candidate, 2000)) -lt 0) 'unrelated HTTP 200 mistaken for relay health'
    $newProxy = [FRouteQa.Route]::Proxy.GetProxy([Uri]"https://fixture.helper.test:$($primary.Port)").Port
    Assert ($oldProxy -eq $newProxy -and [FRouteQa.Route]::Status() -match 'relay port 9444') 'a diagnostic probe changed the active relay endpoint'
    [FRouteQa.Route]::Stop()
    Assert ([FRouteQa.Route]::Status() -eq 'normal connection (route layer off)') 'route did not stop'
    $closed = New-Object Net.Sockets.TcpClient
    try {
        $attempt = $closed.BeginConnect('127.0.0.1', $newProxy, $null, $null)
        [void]$attempt.AsyncWaitHandle.WaitOne(500)
        Assert (-not $closed.Connected) 'ended session still accepts transport connections'
    } finally { $closed.Close() }
    # The outage recovery function must request only a transport retry, for every old cause.
    $errors = $null; $ast = [Management.Automation.Language.Parser]::ParseInput($agentSource, [ref]$null, [ref]$errors)
    $heal = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Heal-Net' }, $true)
    Invoke-Expression ($heal.Extent.Text.Replace('__BUILD__','RouteQa'))
    function Restart-NetAdapter { throw 'physical adapter reset attempted' }
    function ipconfig { throw 'shared DNS cache mutation attempted' }
    foreach ($cause in 'dns','no_link','lan_down','isp_down','relay_unreachable_vpn') { Heal-Net @{ class = $cause } | Out-Null }
    Write-Output 'route TLS fallback, non-mutating probes, stopped listener, recovery without adapter/DNS reset PASS'
} finally {
    $primary.Dispose(); if ($backup) { $backup.Dispose() }
    [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
}

# DPAPI keeps compatibility with old saved sessions, independently of auto-loading
# the PowerShell Security module inside the desktop agent.
& {
    function Get-CimInstance { throw 'Startup must not wait for WMI' }
    function Get-DeviceId { 'fixture-device' }
    function Api($path, $data, $token, $timeout) {
        Assert ($path -eq '/a/register' -and $data.os -and $data.resume -eq 'TEST-TEST') 'registration metadata or resume missing'
        @{ Content = '{"code":"TEST-TEST","resumed":true}' }
    }
    foreach ($name in 'Static-Sys','Uptime-TS','Get-BootTime','Register-Agent') {
        $fn = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        Invoke-Expression ($fn.Extent.Text.Replace('__BUILD__','RouteQa'))
    }
    $up = Uptime-TS
    Assert ($up.TotalSeconds -gt 0) 'native uptime unavailable in Windows PowerShell'
    $boot = Get-BootTime
    Assert ([Math]::Abs(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $boot) - $up.TotalSeconds) -lt 3) 'boot time and uptime disagree'
    Assert ((Register-Agent 'auto' 'TEST-TEST' 'fixture-token' 'restarted').resumed) 'registration required WMI'
    Write-Output 'Startup registration, boot time and PS5 uptime work without WMI PASS'
}

$testState = Join-Path $env:TEMP ('hm-dpapi-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testState)
$StateDir = $testState; $SessionFile = Join-Path $testState 'session.json'; $RELAY = 'https://fixture.helper.test'
$previousTokenFile = $env:HELPER_TOKEN_FILE; $env:HELPER_TOKEN_FILE = $null
function Write-AgentLog($message) { throw $message }
function Get-BootTime { 0 }
try {
    foreach ($name in 'Save-Session','Load-Session') {
        $fn = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        Invoke-Expression $fn.Extent.Text
    }
    $token = 'fixture-only-token-1234'
    Save-Session 'TEST-TEST' $token 'auto'
    $saved = Get-Content -LiteralPath $SessionFile -Raw | ConvertFrom-Json
    Assert ($saved.token -and $saved.token -notmatch $token) 'saved token is not protected'
    Import-Module -Name (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Security/Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
    $secure = ConvertTo-SecureString $saved.token
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { Assert ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) -eq $token) 'new DPAPI state unreadable by legacy loader' }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr); $secure.Dispose() }
    $saved.token = ConvertFrom-SecureString (ConvertTo-SecureString $token -AsPlainText -Force)
    $saved | ConvertTo-Json | Set-Content -LiteralPath $SessionFile -Encoding UTF8
    Assert ((Load-Session).token -eq $token) 'legacy DPAPI state unreadable by new loader'
    Write-Output 'DPAPI legacy/new saved session compatibility PASS'
} finally { $env:HELPER_TOKEN_FILE = $previousTokenFile; Remove-Item -LiteralPath $testState -Recurse -Force }

# Updating the restart copy must preserve a working script on a bad download,
# and keep non-ASCII strings readable by Windows PowerShell 5.1 after saving.
& {
    $StateDir = Join-Path $env:TEMP ('hm-autostart-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $StateDir)
    $SessionFile = Join-Path $StateDir 'session.json'; $RELAY = 'https://fixture.helper.test'
    $previousNoAutostart = $env:HELPER_NO_AUTOSTART; $env:HELPER_NO_AUTOSTART = $null
    function Test-Admin { $false }
    function Get-ScheduledTask { @{ TaskName = 'fixture-existing-task' } }
    function Write-AgentLog($message) { }
    function Invoke-WebRequest { @{ Content = $script:copyFixture } }
    $fn = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-Autostart' }, $true)
    Invoke-Expression $fn.Extent.Text
    $file = Join-Path $StateDir 'agent.ps1'
    try {
        [IO.File]::WriteAllText($file, '# working previous copy')
        $script:copyFixture = 'function Broken {'
        Install-Autostart
        Assert ([IO.File]::ReadAllText($file) -eq '# working previous copy') 'bad download replaced the restart copy'
        $script:copyFixture = "Write-Output '" + [char]0x416 + "'"
        Install-Autostart
        $bytes = [IO.File]::ReadAllBytes($file)
        Assert ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'restart copy lacks UTF-8 BOM'
        Assert ([IO.File]::ReadAllText($file) -eq $script:copyFixture) 'restart copy content changed'
        Assert (@(Get-ChildItem -LiteralPath $StateDir -Filter '*.pending').Count -eq 0) 'pending restart copy leaked'
        Write-Output 'Autostart update preserves previous valid copy and UTF-8 BOM PASS'
    } finally {
        $env:HELPER_NO_AUTOSTART = $previousNoAutostart
        Remove-Item -LiteralPath $StateDir -Recurse -Force
    }
}
