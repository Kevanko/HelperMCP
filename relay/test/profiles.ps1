$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$vendor = Join-Path $root 'agent/vendor/yamldotnet'
$dll = Join-Path $vendor 'YamlDotNet.dll'
$manifest = Get-Content -LiteralPath (Join-Path $vendor 'manifest.json') -Raw | ConvertFrom-Json
$sha = [Security.Cryptography.SHA256]::Create()
try { $actual = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($dll))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
if ($actual -ne $manifest.dll_sha256) { throw 'Vendored YAML dependency hash mismatch' }
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll))
Add-Type -ReferencedAssemblies $dll -TypeDefinition ([IO.File]::ReadAllText((Join-Path $root 'agent/profiles.cs')).Replace('__BUILD__','Test'))
function Assert($value,$message) { if (-not $value) { throw $message } }
function Parse($text) { [PTest.Profiles]::Yaml($text) }

$yaml = @'
defaults: &defaults {type: vless, port: 443, uuid: SECRET_UUID}
extra: &extra {port: 8443, password: SECRET_PASSWORD}
proxies:
  - <<: [*defaults, *extra]
    name: SECRET_LABEL
    server: 'first.example.com'
    port: 2053
    tls: {servername: sni.example.com}
  - {name: second, server: second.example.com, port: 8443, type: hysteria2, password: SECRET_PASSWORD}
  - &third
    <<: *defaults
    server: third.example.com
  - *third
proxy-providers:
  remote: {url: 'https://secret.example/sub?token=SECRET_PROVIDER'}
'@
$rows = @(Parse $yaml)
Assert ($rows.Count -eq 4) 'YAML map, alias or sequence missing'
Assert ($rows[0].host -eq 'first.example.com' -and $rows[0].port -eq 2053 -and $rows[0].protocol -eq 'vless') 'explicit fields did not override merge'
Assert ($rows[1].host -eq 'second.example.com' -and $rows[1].port -eq 8443) 'inline map mixed endpoint fields'
Assert ($rows[2].port -eq 443 -and $rows[3].host -eq 'third.example.com') 'alias or merge failed'
Assert (($rows | ConvertTo-Json -Compress) -notmatch 'SECRET|sni.example|secret.example') 'credential or provider disclosure'
Assert ((Parse 'proxies: [{<<: [{port: 443}, {port: 8443}], server: a.example, type: vless}]')[0].port -eq 443) 'merge sequence precedence changed'
$xray = @(Parse "outbounds:`n- protocol: vless`n  settings:`n    vnext:`n    - address: xray.example`n      port: 443`n      users: [{id: SECRET_UUID}]")
Assert ($xray.Count -eq 1 -and $xray[0].host -eq 'xray.example') 'nested Xray endpoint missing'
$tagged = @(Parse 'proxies: [{type: !!str vless, server: a.example, port: !!int 443, password: !untrusted SECRET}]')
Assert ($tagged.Count -eq 1) 'data-only tagged scalars failed'

$invalid = @(
  'proxies: [{server: SECRET_UNCLOSED',
  "---`nproxies: []`n---`nproxies: []",
  'proxies: [{? [a,b]: SECRET, server: x.example, port: 443}]',
  'proxies: [{server: x.example, server: y.example, port: 443}]',
  'proxies: [{<<: &loop {<<: *loop}, server: x.example, port: 443}]',
  ('proxies: ' + ('[' * 60) + 'SECRET' + (']' * 60))
)
foreach ($text in $invalid) {
  $rejected = $false
  try { Parse $text | Out-Null } catch { $rejected = $true; Assert ($_.Exception.Message -notmatch 'SECRET|x.example|y.example') 'parser exception leaked input' }
  Assert $rejected 'invalid/complex/recursive YAML accepted'
}
# Repeated merge aliases form a DAG with exponentially many paths, not a cycle.
$dag = 'a0: &a0 {password: SECRET}' + "`n"
1..20 | ForEach-Object { $dag += ('a{0}: &a{0} {{<<: [*a{1}, *a{1}]}}' -f $_,($_-1)) + "`n" }
$dag += 'proxies: [{<<: *a20, server: a.example, port: 443}]'
$clock = [Diagnostics.Stopwatch]::StartNew(); $rejected = $false
try { Parse $dag | Out-Null } catch { $rejected = $true }
Assert ($rejected -and $clock.ElapsedMilliseconds -lt 3000) 'merge amplification was unbounded'
Write-Output 'YAML real parser: nested/inline maps, anchors, merge precedence, data-only tags, duplicate/complex keys, nesting/cycle/amplification limits and secret redaction PASS'

$selected=[PTest.Profiles]::MihomoEndpoint($yaml,0)
Assert ($selected.host -eq 'first.example.com' -and $selected.port -eq 2053) 'Mihomo selection changed endpoint identity'
$isolated=[PTest.Profiles]::MihomoConfig($yaml,0,12345,'Ethernet','192.0.2.10','local-password')
$document=New-Object YamlDotNet.RepresentationModel.YamlStream
$document.Load((New-Object IO.StringReader $isolated))
$map=$document.Documents[0].RootNode
function Field($m,$k){,($m.Children[(New-Object YamlDotNet.RepresentationModel.YamlScalarNode $k)])}
Assert ((Field $map 'mixed-port').Value -eq '12345' -and (Field $map 'bind-address').Value -eq '127.0.0.1') 'diagnostic listener exposed beyond loopback'
Assert ((Field (Field $map 'tun') 'enable').Value -eq 'false' -and (Field (Field $map 'dns') 'enable').Value -eq 'false') 'isolated config enabled TUN/DNS'
$proxy=(Field $map 'proxies').Children[0]
Assert ((Field $proxy 'uuid').Value -eq 'SECRET_UUID' -and (Field $proxy 'port').Value -eq '2053' -and (Field $proxy 'server').Value -eq '192.0.2.10') 'profile auth/port not preserved'
Assert ((Field $proxy 'interface-name').Value -eq 'Ethernet' -and (Field $proxy 'name').Value -eq 'helper-profile') 'bound outbound or fixed route missing'
Assert ($isolated -notmatch 'SECRET_PROVIDER|proxy-providers|external-controller') 'unselected provider/controller copied'
foreach($type in @('vless','vmess','trojan','hysteria','hysteria2','tuic','anytls','http')){
 $pinned=[PTest.Profiles]::MihomoConfig(('proxies: [{type: '+$type+', server: original.example, port: 443}]'),0,12345,'Ethernet','192.0.2.10','local-password')
 $document.Load((New-Object IO.StringReader $pinned));$pinnedProxy=(Field $document.Documents[0].RootNode 'proxies').Children[0]
 $key=if($type -in @('vless','vmess')){'servername'}else{'sni'}
 Assert ((Field $pinnedProxy $key).Value -eq 'original.example') ('IP pinning lost default TLS SNI for '+$type)
}
$pinned=[PTest.Profiles]::MihomoConfig('proxies: [{type: trojan, server: original.example, port: 443, sni: explicit.example}]',0,12345,'Ethernet','192.0.2.10','local-password')
$document.Load((New-Object IO.StringReader $pinned));Assert ((Field (Field $document.Documents[0].RootNode 'proxies').Children[0] 'sni').Value -eq 'explicit.example') 'explicit SNI overwritten'
foreach($input in @('proxies: [{type: vless, server: a.example, port: 443, skip-cert-verify: true}]','proxies: [{type: vless, server: a.example, port: 443, dialer-proxy: other}]')){
 $rejected=$false;try{[PTest.Profiles]::MihomoConfig($input,0,12345,'','',$null)|Out-Null}catch{$rejected=$true};Assert $rejected 'insecure or chained profile silently changed'
}
$owner=[PTest.ProfileProcess]::Start($env:ComSpec,'/c ping -n 30 127.0.0.1','C:\Windows',250)
try{Assert ($owner.Process.WaitForExit(2500)) 'owned diagnostic process outlived its deadline'}finally{$owner.Dispose()}
Write-Output 'Isolated Mihomo config preserves auth, disables global effects, rejects insecure/chained profiles; actual Windows Job deadline PASS'
