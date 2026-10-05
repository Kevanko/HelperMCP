# HelperMCP agent for Windows 10/11 (PowerShell 5.1+). Runs in memory, installs nothing.
#   [Net.ServicePointManager]::SecurityProtocol=3072; irm RELAY/h | iex
$prevEAP = $ErrorActionPreference; $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Stop'  # restored at the end: iex runs in the user's session  # restored at the end: iex runs in the user's session
$RELAY = if ($env:HELPER_RELAY) { $env:HELPER_RELAY } else { '__RELAY__' }
$ru = (Get-Culture).TwoLetterISOLanguageName -eq 'ru'
function T($r, $e) { if ($ru) { $r } else { $e } }
$AskTools = 'run', 'write_file', 'click', 'type_text', 'press_key', 'mcp_start', 'mcp_call'
$NodeVersion = 'v22.11.0'
$script:NodeDir = $null; $script:NodeBin = $null
$Children = @{}   # name -> other MCP servers running on this PC
$MaxOut = 100000

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace H -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr e);
'@
[void][H.U]::SetProcessDPIAware()   # real pixels, not scaled ones

function Api($path, $data, $token, $timeout = 40) {
    $h = @{}
    if ($token) { $h.Authorization = "Bearer $token" }
    if ($null -ne $data) {
        $b = [Text.Encoding]::UTF8.GetBytes(($data | ConvertTo-Json -Depth 6 -Compress))
        Invoke-WebRequest -Uri "$RELAY$path" -Method Post -Headers $h -Body $b -ContentType 'application/json; charset=utf-8' -TimeoutSec $timeout -UseBasicParsing
    } else {
        Invoke-WebRequest -Uri "$RELAY$path" -Headers $h -TimeoutSec $timeout -UseBasicParsing
    }
}
function Clip($s) { if ($s.Length -gt $MaxOut) { $s.Substring(0, $MaxOut) + "`n...[truncated]" } else { $s } }

$Screen = [Windows.Forms.SystemInformation]::VirtualScreen
$Scale = 1.0

function Do-Screenshot($a) {
    $s = [Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object Drawing.Bitmap $s.Width, $s.Height
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($s.Left, $s.Top, 0, 0, $bmp.Size)
    $g.Dispose()
    $w = [Math]::Min(1280, $s.Width)
    $script:Scale = $s.Width / $w
    $out = New-Object Drawing.Bitmap $w, ([int]($s.Height / $script:Scale))
    $g = [Drawing.Graphics]::FromImage($out)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.DrawImage($bmp, 0, 0, $out.Width, $out.Height)
    $g.Dispose(); $bmp.Dispose()
    $enc = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
    $p = New-Object Drawing.Imaging.EncoderParameters 1
    $p.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), 70L
    $ms = New-Object IO.MemoryStream
    $out.Save($ms, $enc, $p); $out.Dispose()
    @{ image = [Convert]::ToBase64String($ms.ToArray()); mime = 'image/jpeg' }
}

function Do-Click($a) {
    $x = [int]($a.x * $Scale) + $Screen.Left; $y = [int]($a.y * $Scale) + $Screen.Top
    [void][H.U]::SetCursorPos($x, $y)
    $btn = if ($a.button) { $a.button } else { 'left' }
    $down, $up = switch ($btn) { 'right' { 8, 16 } 'middle' { 32, 64 } default { 2, 4 } }
    $n = if ($a.double) { 2 } else { 1 }
    1..$n | ForEach-Object {
        [H.U]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero); [H.U]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 40
    }
    @{ text = 'ok' }
}

function Do-TypeText($a) {
    # SendKeys treats + ^ % ~ ( ) { } [ ] specially: wrap each in braces
    $esc = [regex]::Replace($a.text, '[+^%~(){}\[\]]', '{$0}')
    $esc = $esc -replace "`r?`n", '{ENTER}'
    [Windows.Forms.SendKeys]::SendWait($esc)
    @{ text = 'ok' }
}

$Vk = @{ ctrl = 0x11; control = 0x11; alt = 0x12; shift = 0x10; win = 0x5B; windows = 0x5B; enter = 0x0D; return = 0x0D
    esc = 0x1B; escape = 0x1B; tab = 0x09; space = 0x20; backspace = 0x08; delete = 0x2E; del = 0x2E; home = 0x24; end = 0x23
    pageup = 0x21; pagedown = 0x22; left = 0x25; up = 0x26; right = 0x27; down = 0x28 }
1..12 | ForEach-Object { $Vk["f$_"] = 0x6F + $_ }
function Do-PressKey($a) {
    $codes = foreach ($k in $a.keys.ToLower().Split('+')) {
        if ($Vk.ContainsKey($k)) { [byte]$Vk[$k] }
        elseif ($k.Length -eq 1) { [byte][char]$k.ToUpper() }
        else { throw "Unknown key '$k'" }
    }
    $codes | ForEach-Object { [H.U]::keybd_event($_, 0, 0, [UIntPtr]::Zero) }
    [array]::Reverse($codes)
    $codes | ForEach-Object { [H.U]::keybd_event($_, 0, 2, [UIntPtr]::Zero) }
    @{ text = 'ok' }
}

function Do-Run($a) {
    $secs = if ($a.timeout_s) { [int]$a.timeout_s } else { 60 }
    $cmd = '[Console]::OutputEncoding=[Text.Encoding]::UTF8; $ProgressPreference="SilentlyContinue"; ' + $a.command
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($secs * 1000)) {
        $p.Kill()
        return @{ text = "[timeout after ${secs}s]" }
    }
    [void]$p.WaitForExit()
    @{ text = Clip ("[exit $($p.ExitCode)]`n" + $o.Result + $e.Result) }
}

function Do-ReadFile($a) {
    $max = if ($a.max_bytes) { [int]$a.max_bytes } else { 200000 }
    $fs = [IO.File]::Open($a.path, 'Open', 'Read', 'ReadWrite')
    try { $buf = New-Object byte[] ([Math]::Min($max, $fs.Length)); [void]$fs.Read($buf, 0, $buf.Length) } finally { $fs.Dispose() }
    @{ text = [Text.Encoding]::UTF8.GetString($buf) }
}
function Do-WriteFile($a) {
    [IO.File]::WriteAllText($a.path, $a.content, (New-Object Text.UTF8Encoding $false))
    @{ text = 'written' }
}
function Do-ListDir($a) {
    $rows = Get-ChildItem -LiteralPath $a.path -Force -ErrorAction SilentlyContinue | Select-Object -First 500 | ForEach-Object {
        '{0} {1,12} {2:yyyy-MM-dd HH:mm:ss} {3}' -f $(if ($_.PSIsContainer) { 'd' } else { '-' }), $(if ($_.PSIsContainer) { 0 } else { $_.Length }), $_.LastWriteTime, $_.Name
    }
    @{ text = ($rows -join "`n") }
}
function Do-SysInfo($a) {
    $os = Get-CimInstance Win32_OperatingSystem
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator')
    @{ text = (@{
        os = "$($os.Caption) build $($os.BuildNumber)"; host = $env:COMPUTERNAME; user = $env:USERNAME; admin = $admin
        powershell = $PSVersionTable.PSVersion.ToString(); cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
        ram_gb = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1); free_ram_gb = [Math]::Round($os.FreePhysicalMemory / 1MB, 1)
        screen = "$($Screen.Width)x$($Screen.Height)"; boot = $os.LastBootUpTime.ToString('s'); lang = (Get-Culture).Name
    } | ConvertTo-Json) }
}

# npx/node/npm missing? Download a portable Node into a temp dir (removed on exit).
function Ensure-Node($cmd) {
    if ($cmd -notmatch '^(npx|npm|node)(\.cmd|\.exe)?$' -or $script:NodeBin -or (Get-Command $cmd -ErrorAction SilentlyContinue)) { return }
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'Node.js is missing and there is no 32-bit portable build' }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $script:NodeDir = Join-Path $env:TEMP ('helpermcp-node-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory $script:NodeDir)
    Write-Host '[helper] downloading portable Node.js ...'
    $zip = Join-Path $script:NodeDir 'n.zip'
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'   # PS 5.1 progress bar makes downloads ~10x slower
    try { Invoke-WebRequest "https://nodejs.org/dist/$NodeVersion/node-$NodeVersion-win-$arch.zip" -OutFile $zip -UseBasicParsing } finally { $ProgressPreference = $pp }
    Expand-Archive $zip $script:NodeDir -Force
    Remove-Item $zip
    $script:NodeBin = (Get-ChildItem $script:NodeDir -Directory | Select-Object -First 1).FullName
}

function Quote-Arg($s) { if ($s -match '[\s"]') { '"' + ($s -replace '"', '\"') + '"' } else { $s } }

function Child-Rpc($c, $method, $params, $timeoutSec = 60, [switch]$Notify) {
    $msg = [ordered]@{ jsonrpc = '2.0'; method = $method }
    if ($null -ne $params) { $msg.params = $params }
    if (-not $Notify) { $c.n++; $msg.id = $c.n }
    $json = $msg | ConvertTo-Json -Depth 20 -Compress
    if ($env:HELPER_DEBUG) { Write-Host "[debug] > $json" }
    $c.w.WriteLine($json); $c.w.Flush()
    if ($Notify) { return }
    $end = [DateTime]::UtcNow.AddSeconds($timeoutSec)
    while ($true) {
        if (-not $c.read) { $c.read = $c.p.StandardOutput.ReadLineAsync() }
        $left = [int]($end - [DateTime]::UtcNow).TotalMilliseconds
        if ($left -lt 0 -or -not $c.read.Wait($left)) {
            $why = if ($c.p.HasExited) { "exited with code $($c.p.ExitCode): " + $c.err.Result } else { 'still running, no reply' }
            throw "MCP server timed out on $method ($why)"
        }
        $line = $c.read.Result; $c.read = $null
        if ($env:HELPER_DEBUG) { Write-Host "[debug] < $line" }
        if ($null -eq $line) { [void]$c.p.WaitForExit(2000); throw ('MCP server exited: ' + $(if ($c.p.HasExited) { $c.err.Result } else { '' })) }
        try { $m = $line | ConvertFrom-Json } catch { continue }
        if ($m.id -eq $c.n -and -not $m.method) {
            if ($m.error) { throw $m.error.message }
            return $m.result
        }
    }
}

function Do-McpStart($a) {
    if ($Children.ContainsKey($a.name)) { throw "'$($a.name)' is already running" }
    Ensure-Node $a.command
    $exe = $a.command
    if ($script:NodeBin -and (Test-Path (Join-Path $script:NodeBin "$exe.cmd"))) { $exe = Join-Path $script:NodeBin "$exe.cmd" }
    elseif ($script:NodeBin -and (Test-Path (Join-Path $script:NodeBin "$exe.exe"))) { $exe = Join-Path $script:NodeBin "$exe.exe" }
    else {   # full path incl. extension; Get-Command would return npx.ps1, which CreateProcess can't run
        $found = foreach ($e in '.exe', '.cmd', '.bat', '') { $g = Get-Command ($exe + $e) -CommandType Application -ErrorAction SilentlyContinue; if ($g) { $g.Source; break } }
        if (-not $found) { throw "Command '$exe' not found" }
        $exe = @($found)[0]
    }
    $psi = New-Object Diagnostics.ProcessStartInfo $exe
    $psi.Arguments = (@($a.args) | Where-Object { $null -ne $_ } | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($script:NodeBin) { $psi.EnvironmentVariables['PATH'] = $script:NodeBin + ';' + $env:PATH }
    if ($a.env) { foreach ($p in $a.env.PSObject.Properties) { $psi.EnvironmentVariables[$p.Name] = [string]$p.Value } }
    if ($env:HELPER_DEBUG) { Write-Host "[debug] start $exe $($psi.Arguments)" }
    # .NET Framework builds the child's stdin writer from the console input encoding. If that is UTF-8 *with BOM*
    # (e.g. chcp 65001), a BOM is written at process start and corrupts the first JSON line. Use a BOM-less encoding.
    $oldIn = $null
    try { $oldIn = [Console]::InputEncoding; [Console]::InputEncoding = New-Object Text.UTF8Encoding $false } catch { }
    $c = @{ p = [Diagnostics.Process]::Start($psi); n = 0; read = $null; tools = @() }
    try { if ($oldIn) { [Console]::InputEncoding = $oldIn } } catch { }
    $c.err = $c.p.StandardError.ReadToEndAsync()   # drained in the background (also keeps the pipe from filling); shown if the server dies. ponytail: grows with a chatty server's stderr
    # default stdin encoding is the console codepage; MCP is UTF-8
    $c.w = New-Object IO.StreamWriter($c.p.StandardInput.BaseStream, (New-Object Text.UTF8Encoding $false))
    # setting the console encoding can fail without a console: if a BOM went out anyway, isolate it on its own (empty) line
    if ($c.p.StandardInput.Encoding.GetPreamble().Length -gt 0) { $c.w.WriteLine(''); $c.w.Flush() }
    try {
        [void](Child-Rpc $c 'initialize' @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'helpermcp'; version = '0.2' } } $(if ($env:HELPER_INIT_TIMEOUT) { [int]$env:HELPER_INIT_TIMEOUT } else { 240 }))
        Child-Rpc $c 'notifications/initialized' $null -Notify
        $c.tools = @((Child-Rpc $c 'tools/list' $null 60).tools)
    } catch { try { $c.p.Kill() } catch { }; throw }
    $Children[$a.name] = $c
    @{ text = "$($a.name): $($c.tools.Count) tools: " + (($c.tools | ForEach-Object { $_.name }) -join ', ') }
}
function Do-McpTools($a) {
    $all = @(foreach ($n in $Children.Keys) { foreach ($t in $Children[$n].tools) { $t | Add-Member -NotePropertyName server -NotePropertyValue $n -PassThru -Force } })
    @{ text = (ConvertTo-Json -InputObject $all -Depth 30 -Compress) }
}
function Do-McpCall($a) {
    $c = $Children[$a.server]
    if (-not $c) { throw "No MCP server '$($a.server)'. Start it with mcp_start." }
    $args2 = if ($a.arguments) { $a.arguments } else { @{} }
    $r = Child-Rpc $c 'tools/call' @{ name = $a.tool; arguments = $args2 } 110
    @{ content = @($r.content); isError = [bool]$r.isError }
}
function Do-McpStop($a) {
    $c = $Children[$a.name]
    if ($c) { try { $c.p.Kill() } catch { }; $Children.Remove($a.name) }
    @{ text = if ($c) { 'stopped' } else { 'not running' } }
}
function Cleanup-Children {
    foreach ($c in $Children.Values) { try { $c.p.Kill() } catch { } }
    if ($script:NodeDir) { Remove-Item $script:NodeDir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Start-Helper {
    $mode = $env:HELPER_MODE
    if ($mode -ne 'ask' -and $mode -ne 'full') {
        $ans = Read-Host (T 'Режим: [1] спрашивать про каждое действие (рекомендуется)  [2] полный доступ' 'Mode: [1] ask before every action (recommended)  [2] full access')
        $mode = if ($ans.Trim() -eq '2') { 'full' } else { 'ask' }
    }
    $osn = (Get-CimInstance Win32_OperatingSystem).Caption
    $r = (Api '/a/register' @{ os = $osn; host = $env:COMPUTERNAME; user = $env:USERNAME; mode = $mode }).Content | ConvertFrom-Json
    $token = $r.token
    Write-Host ''
    Write-Host ("  " + (T 'УДАЛЁННАЯ ПОМОЩЬ. Код сессии:' 'REMOTE HELP. Session code:') + "  " + $r.code) -ForegroundColor Yellow
    Write-Host ("  " + (T 'Назови этот код тому, кто тебе помогает. Закрой окно или Ctrl+C - доступ пропадёт.' 'Give this code to your helper. Close this window or press Ctrl+C to stop.'))
    Write-Host ''
    try {
        while ($true) {
            try { $resp = Api '/a/poll' $null $token 40 }
            catch {
                $code = [int]$_.Exception.Response.StatusCode
                if ($code -eq 401 -or $code -eq 410) { Write-Host 'session closed'; return }
                Start-Sleep 3; continue
            }
            if ($resp.StatusCode -ne 200 -or -not $resp.Content) { continue }
            $cmd = $resp.Content | ConvertFrom-Json
            $name = $cmd.tool; $a = $cmd.args
            if ($name -eq 'bye') { Write-Host 'session closed'; return }
            $short = ($cmd.args | ConvertTo-Json -Compress); if ($short.Length -gt 200) { $short = $short.Substring(0, 200) }
            Write-Host "[helper] $name $short"
            $res = @{ id = $cmd.id }
            try {
                if ($mode -eq 'ask' -and $AskTools -contains $name) {
                    $yn = Read-Host (T 'Разрешить? [y/N]' 'Allow? [y/N]')
                    if ($yn -notmatch '^(y|yes|д|да)$') { throw 'User denied this action.' }
                }
                $fn = @{ screenshot = 'Do-Screenshot'; click = 'Do-Click'; type_text = 'Do-TypeText'; press_key = 'Do-PressKey'
                    run = 'Do-Run'; read_file = 'Do-ReadFile'; write_file = 'Do-WriteFile'; list_dir = 'Do-ListDir'; sysinfo = 'Do-SysInfo'
                    mcp_start = 'Do-McpStart'; mcp_tools = 'Do-McpTools'; mcp_call = 'Do-McpCall'; mcp_stop = 'Do-McpStop' }[$name]
                if (-not $fn) { throw "Unknown tool $name" }
                $res.ok = $true; $res.data = & $fn $a
            } catch { $res.ok = $false; $res.error = $_.Exception.Message }
            try { [void](Api '/a/result' $res $token) } catch { }
        }
    } finally {
        Cleanup-Children
        try { [void](Api '/a/bye' @{} $token 5) } catch { }
    }
}
Start-Helper
$ErrorActionPreference = $prevEAP
