# A selected local Mihomo export is copied into a private, short-lived config.
# This never edits the client's export, starts a TUN, or changes system proxy/DNS.
function Profile-Request($uri, $port, $password, $timeout) {
    $clock = [Diagnostics.Stopwatch]::StartNew(); $response = $null; $stream = $null
    $row = @{ host=$uri.DnsSafeHost; port=$uri.Port; status=$null; bytes=0; elapsed_ms=0; error=$null; capped=$false; through_owned_proxy=$false }
    $request = [Net.HttpWebRequest]::Create($uri)
    $proxy = New-Object Net.WebProxy ('http://127.0.0.1:'+$port),$false
    $proxy.Credentials = New-Object Net.NetworkCredential 'helper-probe',$password
    $request.Proxy=$proxy; $request.KeepAlive=$false; $request.AllowAutoRedirect=$false
    $request.ServerCertificateValidationCallback=[P__BUILD__.ProfileProcess]::StrictCertificate
    $request.Timeout=$timeout; $request.ReadWriteTimeout=$timeout; $request.UserAgent='HelperMCP-profile-check'
    try {
        $async = $request.BeginGetResponse($null,$null)
        while (-not $async.IsCompleted) {
            if ($clock.ElapsedMilliseconds -ge $timeout) { $request.Abort(); throw 'deadline' }
            Pump-Light; Start-Sleep -Milliseconds 50
        }
        try { $response=$request.EndGetResponse($async) }
        catch [Net.WebException] { if ($_.Exception.Response) { $response=$_.Exception.Response } else { throw } }
        $address=$request.ServicePoint.Address
        $row.through_owned_proxy=$address.IsLoopback -and $address.Port -eq $port
        if (-not $row.through_owned_proxy) { throw 'proxy bypassed' }
        $row.status=[int]$response.StatusCode; $stream=$response.GetResponseStream(); $buffer=New-Object byte[] 8192
        while ($row.bytes -lt 65536) {
            $left=$timeout-$clock.ElapsedMilliseconds
            if ($left -le 0) { $request.Abort(); throw 'body deadline' }
            if ($stream.CanTimeout) { $stream.ReadTimeout=[int]$left }
            $read=$stream.Read($buffer,0,[Math]::Min($buffer.Length,65536-$row.bytes))
            if ($read -eq 0) { break }; $row.bytes += $read
        }
        $row.capped=$row.bytes -ge 65536
    } catch { $row.error=if($row.through_owned_proxy){'profile_request_or_body_failed'}else{'profile_request_failed_or_proxy_bypassed'} }
    finally { if($stream){$stream.Dispose()};if($response){$response.Dispose()};$request.Abort();$row.elapsed_ms=$clock.ElapsedMilliseconds }
    $row
}

function Do-ProfileCheck($a) {
    if (-not $a.config_path -or -not (Test-Path -LiteralPath $a.config_path -PathType Leaf) -or (Get-Item -LiteralPath $a.config_path).Length -gt 4MB) { throw 'profile needs a local Mihomo YAML/JSON export <=4 MiB' }
    $core=[string]$a.core_path
    if (-not [IO.Path]::IsPathRooted($core) -or -not (Test-Path -LiteralPath $core -PathType Leaf) -or [IO.Path]::GetFileName($core) -notmatch '^(mihomo[\w.-]*|clash-meta[\w.-]*)\.exe$') { throw 'core_path must be the absolute path of an already installed mihomo/clash-meta executable; no download is performed' }
    $index=[int]$a.interface_index; $profileIndex=[int]$a.profile_index
    if ($index -lt 0 -or $profileIndex -lt 0) { throw 'interface_index and profile_index must be >=0' }
    $timeout=if($a.profile_timeout_s){[int]$a.profile_timeout_s}else{8}
    $repeat=if($a.samples){[int]$a.samples}else{1}
    if($timeout -lt 3 -or $timeout -gt 15 -or $repeat -lt 1 -or $repeat -gt 2){throw 'profile_timeout_s:3..15; samples:1..2'}
    if(-not $a.urls -or @($a.urls).Count -gt 2){throw 'profile requires 1..2 explicit non-secret target URLs'}
    $targets=@(Network-Targets @{urls=$a.urls})
    if($targets.Count -lt 1 -or $targets.Count -gt 2){throw 'profile requires 1..2 nonempty target URLs'}
    foreach($url in $a.urls){$u=[Uri]$url;if($u.IsLoopback -or $u.DnsSafeHost -eq $env:COMPUTERNAME){throw 'Loopback/local-machine targets can bypass .NET proxy; use a remote target URL'}}
    $path=[N__BUILD__.Network]::Paths($index,$false)[0]
    Ensure-ProfileParser
    $text=[IO.File]::ReadAllText($a.config_path)
    $out=[ordered]@{mode='profile';profile_index=$profileIndex;interface_index=$index;path=$path.name;status='not_started';stage='profile';results=@();application_udp_tested=$false;cleanup_complete=$false;notes=@('An isolated existing Mihomo core tests this profile only; no client/TUN, system proxy, routes or DNS settings changed.','The outbound interface is configured explicitly; WinDivert/WFP may still intercept it.','HTTP through this protocol is not proof of Discord voice, game UDP, video or every profile in the subscription.','Core logs and credentials are omitted; a failed request does not distinguish authentication, routing and target rejection.')}
    try{$out.cpu_before_pct=[F__BUILD__.Sys]::CpuLoad(100);$out.memory=[F__BUILD__.Sys]::Mem()}catch{}
    $dir=$null;$running=$null;$validating=$null
    try {
        $endpoint=[P__BUILD__.Profiles]::MihomoEndpoint($text,$profileIndex)
        $out.protocol=$endpoint.protocol;$out.server=$endpoint.host;$out.server_port=$endpoint.port
        if([Uri]::CheckHostName($endpoint.host) -eq [UriHostNameType]::Unknown){throw 'invalid endpoint'}
        $serverIp=$null
        if($index -gt 0){
            $out.stage='server_dns';$answers=@()
            foreach($dns in (@($path.dns)+@('1.1.1.1')|Select-Object -Unique)){
                $answer=[N__BUILD__.Network]::Resolve($path,$endpoint.host,$dns,1000)
                $answers+=@($answer.addresses|Where-Object{-not [N__BUILD__.Network]::Fake($_)})
                if($answers.Count){break}
            }
            if(-not $answers.Count){$out.status='server_dns_unusable_on_selected_path';throw [OperationCanceledException]::new('Diagnostic complete')}
            $serverIp=[string]$answers[0]
        }
        $out.stage='prepare'
        $dir=Join-Path ([IO.Path]::GetTempPath()) ('helper-profile-'+[guid]::NewGuid().ToString('N'))
        $out.stage='private_directory_acl'
        $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false)
        foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')|Select-Object -Unique){$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule ((New-Object Security.Principal.SecurityIdentifier $sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))}
        [void][IO.Directory]::CreateDirectory($dir,$acl)
        $out.stage='proxy_port'
        $listener=New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback),0
        try{$listener.Start();$port=([Net.IPEndPoint]$listener.LocalEndpoint).Port}finally{$listener.Stop()}
        $password=[guid]::NewGuid().ToString('N');$adapter=if($index -gt 0){[string]$path.name}else{''}
        $out.stage='isolated_config'
        $config=[P__BUILD__.Profiles]::MihomoConfig($text,$profileIndex,$port,$adapter,$serverIp,$password)
        $file=Join-Path $dir 'config.yaml';[IO.File]::WriteAllText($file,$config,(New-Object Text.UTF8Encoding $false));$config=$null;$text=$null
        $arguments='-d '+(Quote-Arg $dir)+' -f '+(Quote-Arg $file)
        $out.stage='core_validate'
        $validating=[P__BUILD__.ProfileProcess]::Start($core,('-t '+$arguments),$dir,8000)
        while(-not $validating.Process.HasExited){Pump-Light;Start-Sleep -Milliseconds 100}
        $exit=$validating.Process.ExitCode;$validating.Dispose();$validating=$null
        if($exit -ne 0){$out.status='core_rejected_profile';throw [OperationCanceledException]::new('Diagnostic complete')}
        $out.stage='core_start'
        $startup=[Diagnostics.Stopwatch]::StartNew()
        $lifetime=20000+($timeout*1000*@($a.urls).Count*$repeat)
        $running=[P__BUILD__.ProfileProcess]::Start($core,$arguments,$dir,$lifetime)
        $until=[DateTime]::UtcNow.AddSeconds(15);$owned=$false
        while([DateTime]::UtcNow -lt $until -and -not $running.Process.HasExited){
            $owned=@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue|Where-Object{$_.OwningProcess -eq $running.Process.Id -and $_.LocalAddress -eq '127.0.0.1'}).Count -gt 0
            if($owned){break};Pump-Light;Start-Sleep -Milliseconds 100
        }
        $out.core_start_ms=$startup.ElapsedMilliseconds
        if(-not $owned){$out.status='owned_proxy_unavailable';$out.core_exited=$running.Process.HasExited;if($out.core_exited){$out.core_exit_code=$running.Process.ExitCode};throw [OperationCanceledException]::new('Diagnostic complete')}
        $out.stage='request'
        foreach($url in $a.urls){for($n=0;$n -lt $repeat;$n++){$out.results+=Profile-Request ([Uri]$url) $port $password ($timeout*1000)}}
        $success=@($out.results|Where-Object{-not $_.error -and $_.through_owned_proxy -and $_.status -ge 200 -and $_.status -lt 300 -and ($_.bytes -gt 0 -or $_.status -eq 204)}).Count
        $out.status=if($success -eq $out.results.Count){'profile_http_verified'}else{'profile_http_failed_or_target_rejected'}
        $out.stage='complete'
    }catch{if($out.status -notin @('server_dns_unusable_on_selected_path','core_rejected_profile','owned_proxy_unavailable')){$out.status='profile_test_failed';$out.failure_stage=$out.stage}}
    finally{
        if($validating){$validating.Dispose()};if($running){$running.Dispose()}
        try{$out.cpu_after_pct=[F__BUILD__.Sys]::CpuLoad(100)}catch{}
        if($dir){
            $full=[IO.Path]::GetFullPath($dir);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
            if($full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -like 'helper-profile-*'){
                try{Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop;$out.cleanup_complete=$true}catch{}
            }
        }else{$out.cleanup_complete=$true}
    }
    @{text=($out|ConvertTo-Json -Depth 8 -Compress)}
}
