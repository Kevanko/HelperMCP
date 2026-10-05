# HelperMCP agent for Windows 10/11 (PowerShell 5.1+). Runs in memory, installs nothing.
#   [Net.ServicePointManager]::SecurityProtocol=3072; irm RELAY/h | iex
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Stop'  # restored at the end: iex runs in the user's session
$RELAY = if ($env:HELPER_RELAY) { $env:HELPER_RELAY } else { '__RELAY__' }
$ru = (Get-Culture).TwoLetterISOLanguageName -eq 'ru'
function T($r, $e) { if ($ru) { $r } else { $e } }
$AskTools = 'run', 'start_process', 'fetch_file', 'write_file', 'click', 'move', 'drag', 'type_text', 'press_key', 'scroll', 'mcp_start', 'mcp_call'
$NodeVersion = 'v22.11.0'; $NodeMin = 20   # Playwright & co. need Node >= 20
$script:NodeDir = $null; $script:NodeBin = $null
$script:TmpDirs = @(); $script:OverlayProc = $null; $script:OverlayIn = $null
$script:ExtraPath = @()   # dirs of portable runtimes (node, uv) put in front of PATH for everything we start
$script:Started = @()    # processes launched with start_process (listed by sysinfo, left running on exit)
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
        if ($b.Length -gt 2048) {   # weak links: big outputs shrink a lot
            $ms = New-Object IO.MemoryStream; $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Compress)
            $gz.Write($b, 0, $b.Length); $gz.Close(); $b = $ms.ToArray(); $h['Content-Encoding'] = 'gzip'
        }
        Invoke-WebRequest -Uri "$RELAY$path" -Method Post -Headers $h -Body $b -ContentType 'application/json; charset=utf-8' -TimeoutSec $timeout -UseBasicParsing
    } else {
        Invoke-WebRequest -Uri "$RELAY$path" -Headers $h -TimeoutSec $timeout -UseBasicParsing
    }
}
function Clip($s) { if ($s.Length -gt $MaxOut) { $s.Substring(0, $MaxOut) + "`n...[truncated]" } else { $s } }

$Scale = 1.0
$script:OriginX = [Windows.Forms.SystemInformation]::VirtualScreen.Left; $script:OriginY = [Windows.Forms.SystemInformation]::VirtualScreen.Top   # real px of the screenshot's top-left

function Do-Screenshot($a) {
    $s = [Windows.Forms.SystemInformation]::VirtualScreen   # all monitors, or just one with "monitor"
    if ($null -ne $a.monitor) {
        $all = [Windows.Forms.Screen]::AllScreens
        if ([int]$a.monitor -lt 0 -or [int]$a.monitor -ge $all.Count) { throw "No monitor $($a.monitor). Monitors: 0..$($all.Count - 1)" }
        $s = $all[[int]$a.monitor].Bounds
    }
    $view = [bool]$a.view   # the live viewer's frames must not change the coordinates the AI clicks with
    if (-not $view) { $script:OriginX = $s.Left; $script:OriginY = $s.Top }
    $bmp = New-Object Drawing.Bitmap $s.Width, $s.Height
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($s.Left, $s.Top, 0, 0, $bmp.Size)
    $g.Dispose()
    $cap = if ($a.max_width) { [int]$a.max_width } elseif ($view) { 1280 } else { 1920 }
    $qual = if ($a.quality) { [long]$a.quality } elseif ($view) { 65L } else { 70L }
    $w = [Math]::Min($cap, $s.Width)
    $sc = $s.Width / $w
    if (-not $view) { $script:Scale = $sc }
    $out = New-Object Drawing.Bitmap $w, ([int]($s.Height / $sc))
    $g = [Drawing.Graphics]::FromImage($out)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.DrawImage($bmp, 0, 0, $out.Width, $out.Height)
    $g.Dispose(); $bmp.Dispose()
    $enc = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
    $p = New-Object Drawing.Imaging.EncoderParameters 1
    $p.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), $qual
    $ms = New-Object IO.MemoryStream
    $out.Save($ms, $enc, $p); $out.Dispose()
    $bytes = $ms.ToArray()
    $hash = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash($bytes)).Replace('-', '').ToLower()
    if ($a.prev -and $a.prev -eq $hash) { return @{ same = $true; h = $hash } }   # nothing changed: send nothing
    @{ jpeg = $bytes; mime = 'image/jpeg'; h = $hash }
}

# Screenshots go as the raw JPEG body (no base64 inflation), everything else as (gzipped) JSON.
function Post-Result($res, $token) {
    if ($res.ok -and $res.data -is [hashtable] -and $res.data.jpeg) {
        $meta = @{}; foreach ($k in $res.data.Keys) { if ($k -ne 'jpeg' -and $k -ne 'mime') { $meta[$k] = $res.data[$k] } }
        $h = @{ Authorization = "Bearer $token"; 'X-Result-Id' = $res.id; 'X-Result-Meta' = [Uri]::EscapeDataString(($meta | ConvertTo-Json -Compress)) }
        [void](Invoke-WebRequest -Uri "$RELAY/a/result" -Method Post -Headers $h -Body ([byte[]]$res.data.jpeg) -ContentType $res.data.mime -TimeoutSec 60 -UseBasicParsing)
    } else { [void](Api '/a/result' $res $token 60) }
}

# Move the real pointer like a hand would: eased, about 60 steps/s, speed depends on the distance (the overlay cursor follows it).
function Glide($x, $y, $dur) {
    $p0 = [Windows.Forms.Cursor]::Position; $cx = $p0.X; $cy = $p0.Y
    $dist = [Math]::Sqrt([Math]::Pow($x - $cx, 2) + [Math]::Pow($y - $cy, 2)); if ($dist -lt 2) { return }
    if (-not $dur) { $dur = [Math]::Min(0.7, 0.14 + $dist * 0.00034) }
    $n = [Math]::Max(4, [int]($dur / 0.016))
    for ($i = 1; $i -le $n; $i++) {
        $q = $i / $n; $k = if ($q -lt 0.5) { 4 * $q * $q * $q } else { 1 - [Math]::Pow(-2 * $q + 2, 3) / 2 }   # ease in-out cubic
        [void][H.U]::SetCursorPos([int]($cx + ($x - $cx) * $k), [int]($cy + ($y - $cy) * $k)); [Threading.Thread]::Sleep([int](($dur / $n) * 1000))
    }
}
function Target($a, $kx = 'x', $ky = 'y') { @(([int]($a.$kx * $Scale) + $script:OriginX), ([int]($a.$ky * $Scale) + $script:OriginY)) }
function Btn($name) { switch ($name) { 'right' { 8, 16 } 'middle' { 32, 64 } default { 2, 4 } } }

function Do-Move($a) { Overlay-Send 'active'; $t = Target $a; Glide $t[0] $t[1] $null; @{ text = 'ok' } }

function Do-Click($a) {
    $t = Target $a; $btn = if ($a.button) { $a.button } else { 'left' }; $down, $up = Btn $btn
    Overlay-Send 'active'; Glide $t[0] $t[1] $null; Start-Sleep -Milliseconds 50
    $n = if ($a.double) { 2 } else { 1 }
    1..$n | ForEach-Object {
        Overlay-Send "click $($t[0]) $($t[1]) $btn"
        [H.U]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
        [H.U]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 100
    }
    @{ text = 'ok' }
}

# Press at (x,y), glide to (x2,y2) with the button held, release (moving windows, selecting, sliders ...).
function Do-Drag($a) {
    $t1 = Target $a; $t2 = Target $a 'x2' 'y2'; $btn = if ($a.button) { $a.button } else { 'left' }; $down, $up = Btn $btn
    Overlay-Send 'active'; Glide $t1[0] $t1[1] $null; Start-Sleep -Milliseconds 60
    [H.U]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero); Overlay-Send "down $($t1[0]) $($t1[1])"; Start-Sleep -Milliseconds 120
    $d = [Math]::Sqrt([Math]::Pow($t2[0] - $t1[0], 2) + [Math]::Pow($t2[1] - $t1[1], 2))
    Glide $t2[0] $t2[1] ([Math]::Min(1.4, 0.3 + $d * 0.0007)); Start-Sleep -Milliseconds 100
    [H.U]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero); Overlay-Send "up $($t2[0]) $($t2[1])"
    @{ text = 'ok' }
}

function Do-Scroll($a) {
    Overlay-Send 'active'
    if ($null -ne $a.x -and $null -ne $a.y) { $t = Target $a; Glide $t[0] $t[1] $null }
    $n = if ($null -ne $a.amount) { [int]$a.amount } else { 3 }   # positive = down
    Overlay-Send "scroll $n"
    $one = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int](-120 * [Math]::Sign($n))), 0)
    1..[Math]::Abs($n) | ForEach-Object { [H.U]::mouse_event(0x0800, 0, 0, $one, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40 }
    @{ text = 'ok' }
}

function Do-TypeText($a) {
    Overlay-Send 'typing'
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
    Overlay-Send 'typing'
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

# A command mentions uv/uvx/npx/npm/node that is not installed? Fetch the portable one first (as if it had always been there).
function Ensure-For($text) {
    foreach ($m in [regex]::Matches([string]$text, '(?:^|[\s;&|(])(uvx|uv|npx|npm|node)(?=[\s;&|)]|$)')) {
        $w = $m.Groups[1].Value
        try { Ensure-Node $w; Ensure-Uv $w } catch { Write-Host "[helper] could not prepare ${w}: $($_.Exception.Message)" }
    }
}

function Do-Run($a) {
    Ensure-For $a.command
    $secs = if ($a.timeout_s) { [int]$a.timeout_s } else { 60 }
    $cmd = '[Console]::OutputEncoding=[Text.Encoding]::UTF8; $ProgressPreference="SilentlyContinue"; ' + $a.command
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($script:ExtraPath.Count) { $psi.EnvironmentVariables['PATH'] = ($script:ExtraPath -join ';') + ';' + $env:PATH }
    $psi.EnvironmentVariables['PYTHONUTF8'] = '1'; $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'   # Python tools crash on non-ASCII output otherwise
    if ($a.cwd) { $psi.WorkingDirectory = $a.cwd }
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds($secs)
    while (-not $p.WaitForExit(400)) {
        if ([DateTime]::UtcNow -gt $deadline) { Stop-Tree $p; return @{ text = "[timeout after ${secs}s]" } }
        Pump-Light
    }
    [void]$p.WaitForExit()
    @{ text = Clip ("[exit $($p.ExitCode)]`n" + $o.Result + $e.Result) }
}

function Do-ReadFile($a) {
    if ($a.path -match '\.(png|jpe?g|gif|bmp|webp|tiff?)$') {   # an image: return it as an image, scaled down to max_width (default 1600)
        $cap = if ($a.max_width) { [int]$a.max_width } else { 1600 }
        $img = [Drawing.Image]::FromFile((Resolve-Path -LiteralPath $a.path).Path)
        try {
            $w = [Math]::Min($cap, $img.Width); $h = [int]($img.Height * $w / $img.Width)
            $out = New-Object Drawing.Bitmap $w, $h
            $g = [Drawing.Graphics]::FromImage($out); $g.InterpolationMode = 'HighQualityBicubic'; $g.DrawImage($img, 0, 0, $w, $h); $g.Dispose()
            $enc = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
            $ep = New-Object Drawing.Imaging.EncoderParameters 1
            $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), $(if ($a.quality) { [long]$a.quality } else { 80L })
            $ms = New-Object IO.MemoryStream; $out.Save($ms, $enc, $ep); $out.Dispose()
            return @{ jpeg = $ms.ToArray(); mime = 'image/jpeg'; text = "$($img.Width)x$($img.Height) image" }
        } finally { $img.Dispose() }
    }
    $max = if ($a.max_bytes) { [int]$a.max_bytes } else { 200000 }
    $fs = [IO.File]::Open($a.path, 'Open', 'Read', 'ReadWrite')
    try { $buf = New-Object byte[] ([Math]::Min($max, $fs.Length)); [void]$fs.Read($buf, 0, $buf.Length) } finally { $fs.Dispose() }
    @{ text = [Text.Encoding]::UTF8.GetString($buf) }
}
# Upload a file to the relay and return a download link for the operator.
function Do-FetchFile($a) {
    $f = (Resolve-Path -LiteralPath $a.path).Path
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try {
        $resp = Invoke-WebRequest -Uri ("$RELAY/a/file?name=" + [Uri]::EscapeDataString((Split-Path $f -Leaf))) -Method Post -InFile $f `
            -Headers @{ Authorization = "Bearer $script:Token" } -ContentType 'application/octet-stream' -TimeoutSec 3600 -UseBasicParsing
    } finally { $ProgressPreference = $pp }
    $d = $resp.Content | ConvertFrom-Json
    @{ text = "$($d.url)  ($($d.size) bytes, link valid 24 h)" }
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
        monitors = @([Windows.Forms.Screen]::AllScreens | ForEach-Object -Begin { $i = 0 } -Process { "{0}: {1}x{2} at {3},{4}{5}" -f $i++, $_.Bounds.Width, $_.Bounds.Height, $_.Bounds.X, $_.Bounds.Y, $(if ($_.Primary) { " (primary)" } else { "" }) }); boot = $os.LastBootUpTime.ToString('s'); lang = (Get-Culture).Name; node = (& { try { (& node -v 2>$null) } catch { $null } }); uv = (& { try { (& uv --version 2>$null) } catch { $null } })
        started = @($script:Started | ForEach-Object { '{0} running={1}' -f $_.Id, (-not $_.HasExited) })
    } | ConvertTo-Json) }
}

# Launch a program detached (GUI apps like Blender/Unity, servers) and return at once; it keeps running after this call.
function Resolve-Exe($cmd) {
    if (Test-Path -LiteralPath $cmd -PathType Leaf) { return (Resolve-Path -LiteralPath $cmd).Path }
    foreach ($d in $script:ExtraPath) { foreach ($e in '.exe', '.cmd', '.bat', '') { $f = Join-Path $d ($cmd + $e); if (Test-Path -LiteralPath $f -PathType Leaf) { return $f } } }
    foreach ($e in '.exe', '.cmd', '.bat', '') { $g = Get-Command ($cmd + $e) -CommandType Application -ErrorAction SilentlyContinue; if ($g) { return @($g)[0].Source } }
    $null
}
function Do-StartProcess($a) {
    Ensure-For ([IO.Path]::GetFileNameWithoutExtension([string]$a.command))
    $exe = Resolve-Exe $a.command
    if (-not $exe) { throw "Command '$($a.command)' not found" }
    $log = Join-Path $env:TEMP ("helpermcp-start-$PID-$($script:Started.Count).log")
    $argl = (@($a.args) | Where-Object { $null -ne $_ } | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi = New-Object Diagnostics.ProcessStartInfo 'cmd.exe'   # cmd keeps a log of the output; GUI windows still open normally
    $psi.Arguments = '/d /c ""' + $exe + '" ' + $argl + ' > "' + $log + '" 2>&1"'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    if ($script:ExtraPath.Count) { $psi.EnvironmentVariables['PATH'] = ($script:ExtraPath -join ';') + ';' + $env:PATH }
    $psi.EnvironmentVariables['PYTHONUTF8'] = '1'; $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    if ($a.env) { foreach ($q in $a.env.PSObject.Properties) { $psi.EnvironmentVariables[$q.Name] = [string]$q.Value } }
    if ($a.cwd) { $psi.WorkingDirectory = $a.cwd }
    $proc = [Diagnostics.Process]::Start($psi); $script:Started += $proc
    $w = if ($null -ne $a.wait_s) { [Math]::Min([double]$a.wait_s, 30) } else { 2 }
    [void]$proc.WaitForExit([int]($w * 1000))
    $tail = if (Test-Path $log) { $t = Get-Content $log -Raw -ErrorAction SilentlyContinue; if ($t) { $t.Substring([Math]::Max(0, $t.Length - 1500)) } else { '' } } else { '' }
    if ($proc.HasExited) { @{ text = "[exited with code $($proc.ExitCode) right away]`n$tail" } } else { @{ text = "[started pid $($proc.Id), still running]`n$tail" } }
}

# uv/uvx (how most Python MCP servers are started) missing? Download the portable uv into a temp dir.
function Ensure-Uv($cmd) {
    if ($cmd -notmatch '^(uv|uvx)(\.exe)?$' -or (Resolve-Exe $cmd)) { return }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
    $dir = Join-Path $env:TEMP ('helpermcp-uv-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory $dir); $script:TmpDirs += $dir
    Write-Host '[helper] downloading portable uv ...'
    $zip = Join-Path $dir 'uv.zip'
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest "https://github.com/astral-sh/uv/releases/latest/download/uv-$arch-pc-windows-msvc.zip" -OutFile $zip -UseBasicParsing } finally { $ProgressPreference = $pp }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir); Remove-Item $zip
    $script:ExtraPath = @($dir) + $script:ExtraPath
}

function Node-Major { try { [int](((& node -v 2>$null) -as [string]).TrimStart('v').Split('.')[0]) } catch { 0 } }

# command="playwright": a real, visible browser with sound, like a normal Playwright MCP on a desktop.
function Playwright-Preset($a) {
    $exe = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    $opts = [ordered]@{ headless = $false; chromiumSandbox = $true; ignoreDefaultArgs = @('--mute-audio', '--disable-blink-features=AutomationControlled'); args = @('--autoplay-policy=no-user-gesture-required') }
    if ($exe) { $opts.executablePath = $exe }
    $dir = Join-Path $env:TEMP ('helpermcp-pw-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory $dir); $script:TmpDirs += $dir
    $cfg = Join-Path $dir 'config.json'
    [IO.File]::WriteAllText($cfg, (@{ browser = @{ browserName = 'chromium'; launchOptions = $opts } } | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
    @{ command = 'npx'; args = @('-y', '@playwright/mcp@latest', '--config', $cfg) + @($a.args | Where-Object { $null -ne $_ }) }
}

# npx/node/npm missing or older than 20? Download a portable Node into a temp dir (removed on exit).
function Ensure-Node($cmd) {
    if ($cmd -notmatch '^(npx|npm|node)(\.cmd|\.exe)?$' -or $script:NodeBin -or ($cmd -match '^node(\.exe)?$' -and (Resolve-Exe $cmd)) -or (Node-Major) -ge $NodeMin) { return }   # a plain `node script.js` runs on whatever Node is installed; npx/npm packages usually need >= 20
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'Node.js is missing and there is no 32-bit portable build' }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $script:NodeDir = Join-Path $env:TEMP ('helpermcp-node-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory $script:NodeDir)
    Write-Host '[helper] downloading portable Node.js ...'
    $zip = Join-Path $script:NodeDir 'n.zip'
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'   # PS 5.1 progress bar makes downloads ~10x slower
    try { Invoke-WebRequest "https://nodejs.org/dist/$NodeVersion/node-$NodeVersion-win-$arch.zip" -OutFile $zip -UseBasicParsing } finally { $ProgressPreference = $pp }
    Add-Type -AssemblyName System.IO.Compression.FileSystem   # Expand-Archive is painfully slow on PS 5.1 (progress bar + per-file overhead)
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $script:NodeDir)
    Remove-Item $zip
    $script:NodeBin = (Get-ChildItem $script:NodeDir -Directory | Select-Object -First 1).FullName
    $script:ExtraPath = @($script:NodeBin) + $script:ExtraPath
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
        $got = $false
        while ($left -gt 0) { if ($c.read.Wait([Math]::Min($left, 400))) { $got = $true; break }; Pump-Light; $left = [int]($end - [DateTime]::UtcNow).TotalMilliseconds }
        if (-not $got) {
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
    if ($a.command -eq 'playwright') { $pre = Playwright-Preset $a; $a = @{ name = $a.name; command = $pre.command; args = $pre.args; env = $a.env } }
    Ensure-Node $a.command; Ensure-Uv $a.command
    $exe = Resolve-Exe $a.command   # full path incl. extension (npx.cmd, uvx.exe ...); Get-Command alone would return npx.ps1
    if (-not $exe) { throw "Command '$($a.command)' not found" }
    $psi = New-Object Diagnostics.ProcessStartInfo $exe
    $psi.Arguments = (@($a.args) | Where-Object { $null -ne $_ } | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($script:ExtraPath.Count) { $psi.EnvironmentVariables['PATH'] = ($script:ExtraPath -join ';') + ';' + $env:PATH }
    $psi.EnvironmentVariables['PYTHONUTF8'] = '1'; $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    if ($a.env) { foreach ($q in $a.env.PSObject.Properties) { $psi.EnvironmentVariables[$q.Name] = [string]$q.Value } }
    if ($a.cwd) { $psi.WorkingDirectory = $a.cwd }
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
        [void](Child-Rpc $c 'initialize' @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'helpermcp'; version = '0.2' } } $(if ($env:HELPER_INIT_TIMEOUT) { [int]$env:HELPER_INIT_TIMEOUT } elseif ($a.timeout_s) { [int]$a.timeout_s } else { 240 }))
        Child-Rpc $c 'notifications/initialized' $null -Notify
        $c.tools = @((Child-Rpc $c 'tools/list' $null 60).tools)
    } catch { Stop-Tree $c.p; throw }
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
    $r = Child-Rpc $c 'tools/call' @{ name = $a.tool; arguments = $args2 } $(if ($a.timeout_s) { [int]$a.timeout_s } else { 110 })
    @{ content = @($r.content); isError = [bool]$r.isError }
}
# uvx/npx start the real server as a grandchild: kill the whole tree, not just the wrapper
function Stop-Tree($proc) {
    try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch { }
    try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
}
function Do-McpStop($a) {
    $c = $Children[$a.name]
    if ($c) { Stop-Tree $c.p; $Children.Remove($a.name) }
    @{ text = if ($c) { 'stopped' } else { 'not running' } }
}
# "Remote control" overlay: glowing screen edges that fade out + a label on top, on every monitor. Runs as its own
# process (needs a message loop), ignores the mouse, and quits when the agent's PowerShell is gone.
$OverlayScript = @'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
Add-Type -Namespace O -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i); [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v); [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][O.W]::SetProcessDPIAware()
Add-Type -TypeDefinition @"
using System; using System.Collections.Concurrent; using System.Threading;
namespace O {
  public static class Glow {
    // alpha of every pixel is a fade of its distance to the NEAREST screen edge: no strips, nothing overlaps, no seams
    public static byte[] Make(int w, int h, int s, int r, int g, int b) {
      var px = new byte[w * h * 4]; var prof = new double[s];
      for (int d = 0; d < s; d++) { double t = (d + 0.5) / s; prof[d] = t <= 0.35 ? 0.59 + (0.18 - 0.59) * t / 0.35 : 0.18 * (1 - (t - 0.35) / 0.65); }
      for (int y = 0; y < h; y++) { int dy = Math.Min(y, h - 1 - y);
        for (int x = 0; x < w; x++) { int d = Math.Min(dy, Math.Min(x, w - 1 - x)); if (d >= s) continue;
          double a = prof[d]; int i = (y * w + x) * 4; px[i] = (byte)(b * a); px[i + 1] = (byte)(g * a); px[i + 2] = (byte)(r * a); px[i + 3] = (byte)(255 * a); } }
      return px;
    }
  }
  public static class Pump {   // commands from the agent arrive on stdin, one per line
    public static ConcurrentQueue<string> Q = new ConcurrentQueue<string>();
    public static volatile bool Eof;
    public static void Start() { var t = new Thread(() => { try { string l; while ((l = Console.In.ReadLine()) != null) Q.Enqueue(l); } catch { } Eof = true; }); t.IsBackground = true; t.Start(); }
  }
}
"@
[O.Pump]::Start()
$label = $env:HM_LABEL; $lostLabel = $env:HM_LOST; $ppid = [int]$env:HM_PPID
$dpi = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero).DpiX / 96
$script:state = 'ok'
function C($r, $g, $b, $a = 255) { [Windows.Media.Color]::FromArgb($a, $r, $g, $b) }
$BLUE = C 76 141 255; $ORANGE = C 255 138 30; $VIOLET = C 168 128 255
function Brush($c) { $b = New-Object Windows.Media.SolidColorBrush $c; $b.Freeze(); $b }
function Cur() { if ($script:state -eq 'lost') { $ORANGE } else { $BLUE } }

function New-Win($x, $y, $w, $h) {
    $win = New-Object Windows.Window
    $win.WindowStyle = 'None'; $win.ResizeMode = 'NoResize'; $win.AllowsTransparency = $true; $win.Background = [Windows.Media.Brushes]::Transparent
    $win.Topmost = $true; $win.ShowInTaskbar = $false; $win.ShowActivated = $false; $win.WindowStartupLocation = 'Manual'
    $win.Left = $x; $win.Top = $y; $win.Width = $w; $win.Height = $h
    $win
}
function Click-Through($win) {   # click-through, no focus, hidden from Alt+Tab
    $h = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
    [void][O.W]::SetWindowLong($h, -20, ([O.W]::GetWindowLong($h, -20) -bor 0x20 -bor 0x80 -bor 0x08000000))
}
function New-Shown($x, $y, $w, $h) { $win = New-Win $x $y $w $h; $win.Show(); Click-Through $win; $win }

# ---- glow + label, one window per monitor
$mons = @()
foreach ($scr in [Windows.Forms.Screen]::AllScreens) {
    $b = $scr.Bounds
    $win = New-Win ($b.X / $dpi) ($b.Y / $dpi) ($b.Width / $dpi) ($b.Height / $dpi)
    $g = New-Object Windows.Controls.Grid
    $img = New-Object Windows.Controls.Image; $img.Stretch = 'None'; $img.HorizontalAlignment = 'Left'; $img.VerticalAlignment = 'Top'
    [void]$g.Children.Add($img)
    $pill = New-Object Windows.Controls.Border
    $pill.CornerRadius = New-Object Windows.CornerRadius 17; $pill.Padding = New-Object Windows.Thickness 14, 6, 18, 6
    $pill.Margin = New-Object Windows.Thickness 0, 12, 0, 0; $pill.HorizontalAlignment = 'Center'; $pill.VerticalAlignment = 'Top'
    $pill.Background = New-Object Windows.Media.SolidColorBrush (C 15 23 36 224); $pill.BorderThickness = New-Object Windows.Thickness 1.5
    $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
    $dot = New-Object Windows.Shapes.Ellipse; $dot.Width = 9; $dot.Height = 9; $dot.VerticalAlignment = 'Center'
    $tb = New-Object Windows.Controls.TextBlock; $tb.Foreground = [Windows.Media.Brushes]::White; $tb.FontSize = 14
    $tb.FontWeight = 'SemiBold'; $tb.FontFamily = New-Object Windows.Media.FontFamily 'Segoe UI'; $tb.Margin = New-Object Windows.Thickness 9, 0, 0, 0
    [void]$sp.Children.Add($dot); [void]$sp.Children.Add($tb); $pill.Child = $sp; [void]$g.Children.Add($pill)
    $win.Content = $g
    $m = @{ win = $win; img = $img; pill = $pill; dot = $dot; tb = $tb; w = $b.Width; h = $b.Height; cache = @{} }
    $win.Show(); Click-Through $win; $mons += $m
}
function Apply-State {
    $c = Cur; $key = $script:state
    foreach ($m in $mons) {
        if (-not $m.cache.ContainsKey($key)) {
            $px = [O.Glow]::Make($m.w, $m.h, [int](70 * $dpi), $c.R, $c.G, $c.B)
            $bs = [Windows.Media.Imaging.BitmapSource]::Create($m.w, $m.h, 96 * $dpi, 96 * $dpi, [Windows.Media.PixelFormats]::Pbgra32, $null, $px, $m.w * 4); $bs.Freeze()
            $m.cache[$key] = $bs
        }
        $m.img.Source = $m.cache[$key]
        $m.pill.BorderBrush = Brush $c; $m.dot.Fill = Brush $c
        $m.tb.Text = if ($script:state -eq 'lost') { $lostLabel } else { $label }
        if ($script:state -eq 'lost') {   # the orange dot pulses while the link is down
            $an = New-Object Windows.Media.Animation.DoubleAnimation 1.0, 0.25, ([TimeSpan]::FromMilliseconds(550))
            $an.AutoReverse = $true; $an.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $m.dot.BeginAnimation([Windows.UIElement]::OpacityProperty, $an)
        } else { $m.dot.BeginAnimation([Windows.UIElement]::OpacityProperty, $null); $m.dot.Opacity = 1 }
    }
}
Apply-State

# ---- the big cursor: arrow with glow, press animation, drag ring, typing dots, scroll chevrons, comet tail
$CW = 140; $HX = 44; $HY = 44
$cwin = New-Win -500 -500 $CW $CW; $cwin.Show(); Click-Through $cwin; $cwin.Hide()
$cv = New-Object Windows.Controls.Canvas; $cwin.Content = $cv
$trailDots = @(); 1..9 | ForEach-Object { $e = New-Object Windows.Shapes.Ellipse; $e.Width = 8; $e.Height = 8; $e.Visibility = 'Collapsed'; [void]$cv.Children.Add($e); $trailDots += $e }
$ring = New-Object Windows.Shapes.Ellipse; $ring.Width = 46; $ring.Height = 46; $ring.StrokeThickness = 2.4; $ring.Visibility = 'Collapsed'
[Windows.Controls.Canvas]::SetLeft($ring, $HX - 23); [Windows.Controls.Canvas]::SetTop($ring, $HY - 23); [void]$cv.Children.Add($ring)
$arrow = New-Object Windows.Shapes.Polygon
$pts = New-Object Windows.Media.PointCollection
foreach ($q in @(@(0, 0), @(0, 23), @(5.2, 18.2), @(8.8, 26.5), @(12.3, 25), @(8.7, 16.8), @(15.6, 16.8))) { $pts.Add((New-Object Windows.Point ($q[0] * 1.4), ($q[1] * 1.4))) }
$arrow.Points = $pts; $arrow.Fill = [Windows.Media.Brushes]::White; $arrow.Stroke = Brush (C 13 26 46 242); $arrow.StrokeThickness = 1.7; $arrow.StrokeLineJoin = 'Round'
$arrowScale = New-Object Windows.Media.ScaleTransform 1, 1; $arrow.RenderTransform = $arrowScale; $arrow.RenderTransformOrigin = New-Object Windows.Point 0, 0
$glow = New-Object Windows.Media.Effects.DropShadowEffect; $glow.ShadowDepth = 0; $glow.BlurRadius = 16; $glow.Opacity = 0.9; $arrow.Effect = $glow
[Windows.Controls.Canvas]::SetLeft($arrow, $HX); [Windows.Controls.Canvas]::SetTop($arrow, $HY); [void]$cv.Children.Add($arrow)
$typeDots = @(); 0..2 | ForEach-Object { $e = New-Object Windows.Shapes.Ellipse; $e.Width = 6.4; $e.Height = 6.4; $e.Visibility = 'Collapsed'
    [Windows.Controls.Canvas]::SetLeft($e, $HX + 27 + $_ * 9); [Windows.Controls.Canvas]::SetTop($e, $HY + 37); [void]$cv.Children.Add($e); $typeDots += $e }
$chev = @(); 0..2 | ForEach-Object { $l = New-Object Windows.Shapes.Polyline; $l.StrokeThickness = 3; $l.StrokeStartLineCap = 'Round'; $l.StrokeEndLineCap = 'Round'; $l.StrokeLineJoin = 'Round'
    $l.Points = New-Object Windows.Media.PointCollection; foreach ($q in @(@(0, 0), @(7, 7), @(14, 0))) { $l.Points.Add((New-Object Windows.Point $q[0], $q[1])) }
    $l.Visibility = 'Collapsed'; [void]$cv.Children.Add($l); $chev += $l }

# ---- click ripple
$RW = 220
$rwin = New-Win -500 -500 $RW $RW; $rwin.Show(); Click-Through $rwin; $rwin.Hide()
$rc = New-Object Windows.Controls.Canvas; $rwin.Content = $rc
$rings = @(); 0..1 | ForEach-Object { $e = New-Object Windows.Shapes.Ellipse; $e.Visibility = 'Collapsed'; [void]$rc.Children.Add($e); $rings += $e }
$rdot = New-Object Windows.Shapes.Ellipse; $rdot.Fill = [Windows.Media.Brushes]::White; $rdot.Visibility = 'Collapsed'; [void]$rc.Children.Add($rdot)
function Place($e, $cx, $cy, $r) { $e.Width = 2 * $r; $e.Height = 2 * $r; [Windows.Controls.Canvas]::SetLeft($e, $cx - $r); [Windows.Controls.Canvas]::SetTop($e, $cy - $r) }

$clock = [Diagnostics.Stopwatch]::StartNew()
$script:lastActive = -99.0; $script:opacity = 0.0; $script:pressedT = -99.0; $script:dragging = $false
$script:scrollDir = 0; $script:scrollT = -99.0; $script:typingT = -99.0; $script:rip = $null; $script:cursorShown = $false; $script:ripShown = $false
$trail = New-Object System.Collections.ArrayList
$script:lastPtr = $null

function On-Line($line) {
    $f = $line.Trim() -split '\s+'; $now = $clock.Elapsed.TotalSeconds
    if (-not $f -or -not $f[0]) { return }
    if ($f[0] -eq 'state' -and $f.Count -gt 1) { if ($script:state -ne $f[1]) { $script:state = $f[1]; Apply-State }; return }
    $script:lastActive = $now
    switch ($f[0]) {
        'click' { $script:pressedT = $now; $c = if ($f[3] -eq 'right') { $VIOLET } else { Cur }; $script:rip = @{ x = [double]$f[1]; y = [double]$f[2]; t = $now; c = $c } }
        'down'  { $script:dragging = $true; $script:pressedT = $now }
        'up'    { $script:dragging = $false; if ($f.Count -ge 3) { $script:rip = @{ x = [double]$f[1]; y = [double]$f[2]; t = $now; c = (Cur) } } }
        'scroll' { $script:scrollDir = if ([double]$f[1] -gt 0) { 1 } else { -1 }; $script:scrollT = $now }
        'typing' { $script:typingT = $now }
    }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(16)
$timer.Add_Tick({
    $line = $null
    while ([O.Pump]::Q.TryDequeue([ref]$line)) { On-Line $line }
    if ([O.Pump]::Eof) { [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown(); return }
    $now = $clock.Elapsed.TotalSeconds; $p = [Windows.Forms.Cursor]::Position; $c = Cur
    if ($trail.Count -eq 0 -or $trail[$trail.Count - 1].x -ne $p.X -or $trail[$trail.Count - 1].y -ne $p.Y) { [void]$trail.Add(@{ t = $now; x = $p.X; y = $p.Y }); if ($trail.Count -gt 14) { $trail.RemoveAt(0) } }
    $active = (($now - $script:lastActive) -lt 3.0) -or $script:dragging
    $tgt = if ($active) { 1.0 } else { 0.0 }
    $script:opacity += ($tgt - $script:opacity) * 0.22
    if ($script:opacity -lt 0.03 -and -not $active) { if ($script:cursorShown) { $cwin.Hide(); $script:cursorShown = $false } }
    else {
        if (-not $script:cursorShown) { $cwin.Show(); $script:cursorShown = $true }
        $cwin.Left = $p.X / $dpi - $HX; $cwin.Top = $p.Y / $dpi - $HY; $cwin.Opacity = [Math]::Min(1.0, $script:opacity)
        $glow.Color = $c; $br = Brush $c
        $pa = $now - $script:pressedT
        $s = if ($script:dragging) { 0.9 } elseif ($pa -ge 0 -and $pa -lt 0.2) { 1 - 0.16 * [Math]::Sin([Math]::PI * $pa / 0.2) } else { 1.0 }
        $arrowScale.ScaleX = $s; $arrowScale.ScaleY = $s
        if ($script:dragging) { $ring.Visibility = 'Visible'; $ring.Stroke = $br; $ring.Fill = Brush (C $c.R $c.G $c.B 46); $rr = 23 + 3 * [Math]::Sin($now * 8); Place $ring $HX $HY $rr } else { $ring.Visibility = 'Collapsed' }
        for ($i = 0; $i -lt $trailDots.Count; $i++) {   # comet tail
            $e = $trailDots[$i]; $k = $trail.Count - 2 - $i
            if ($k -ge 0 -and ($now - $trail[$k].t) -lt 0.3) {
                $age = ($now - $trail[$k].t) / 0.3; $e.Visibility = 'Visible'; $e.Fill = Brush (C $c.R $c.G $c.B ([int](82 * (1 - $age))))
                $e.Width = 12 * (1 - $age) + 2; $e.Height = $e.Width
                [Windows.Controls.Canvas]::SetLeft($e, $HX + $trail[$k].x - $p.X + 3 - $e.Width / 2); [Windows.Controls.Canvas]::SetTop($e, $HY + $trail[$k].y - $p.Y + 5 - $e.Width / 2)
            } else { $e.Visibility = 'Collapsed' }
        }
        $ta = $now - $script:typingT
        for ($i = 0; $i -lt 3; $i++) { if ($ta -ge 0 -and $ta -lt 1.6) { $typeDots[$i].Visibility = 'Visible'; $typeDots[$i].Fill = Brush (C $c.R $c.G $c.B ([int](255 * (0.35 + 0.65 * [Math]::Max(0, [Math]::Sin($ta * 9 - $i * 0.9)))))) } else { $typeDots[$i].Visibility = 'Collapsed' } }
        $sa = $now - $script:scrollT
        for ($i = 0; $i -lt 3; $i++) {
            if ($script:scrollDir -ne 0 -and $sa -ge 0 -and $sa -lt 0.7) {
                $q = (($sa / 0.7) + $i / 3.0) % 1.0; $yy = $HY + 26 + $script:scrollDir * (6 + 26 * $q) + $(if ($script:scrollDir -lt 0) { -26 } else { 0 })
                $chev[$i].Visibility = 'Visible'; $chev[$i].Stroke = Brush (C $c.R $c.G $c.B ([int](230 * (1 - $q))))
                $chev[$i].RenderTransform = New-Object Windows.Media.ScaleTransform 1, $script:scrollDir
                [Windows.Controls.Canvas]::SetLeft($chev[$i], $HX + 34); [Windows.Controls.Canvas]::SetTop($chev[$i], $yy - 3.5 * $script:scrollDir - $(if ($script:scrollDir -lt 0) { 0 } else { 0 }))
            } else { $chev[$i].Visibility = 'Collapsed' }
        }
    }
    if ($script:rip -and ($now - $script:rip.t) -gt 0.9) { $script:rip = $null }
    if ($script:rip) {
        $r = $script:rip; if (-not $script:ripShown) { $rwin.Show(); $script:ripShown = $true }
        $rwin.Left = $r.x / $dpi - $RW / 2; $rwin.Top = $r.y / $dpi - $RW / 2; $rb = Brush $r.c
        $idx = 0
        foreach ($d in @(@(0.0, 8), @(0.16, 4))) {
            $pp = ($now - $r.t - $d[0]) / 0.6; $e = $rings[$idx]; $idx++
            if ($pp -ge 0 -and $pp -le 1) {
                $e.Visibility = 'Visible'; Place $e ($RW / 2) ($RW / 2) ($d[1] + 72 * (1 - [Math]::Pow(1 - $pp, 3)))
                $e.Stroke = Brush (C $r.c.R $r.c.G $r.c.B ([int](230 * [Math]::Pow(1 - $pp, 1.3)))); $e.StrokeThickness = 3.4 * (1 - $pp) + 1; $e.Fill = Brush (C $r.c.R $r.c.G $r.c.B ([int](30 * (1 - $pp))))
            } else { $e.Visibility = 'Collapsed' }
        }
        $p0 = ($now - $r.t) / 0.3
        if ($p0 -ge 0 -and $p0 -le 1) { $rdot.Visibility = 'Visible'; Place $rdot ($RW / 2) ($RW / 2) (9 * (1 - $p0) + 2); $rdot.Opacity = 1 - $p0 } else { $rdot.Visibility = 'Collapsed' }
    } elseif ($script:ripShown) { $rwin.Hide(); $script:ripShown = $false }
})
$timer.Start()
$wd = New-Object Windows.Threading.DispatcherTimer
$wd.Interval = [TimeSpan]::FromSeconds(1.5)
$wd.Add_Tick({
    if (-not (Get-Process -Id $ppid -ErrorAction SilentlyContinue)) { [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() }   # agent gone: remove the overlay too
    else { foreach ($m in $mons) { $m.win.Topmost = $false; $m.win.Topmost = $true } }   # stay above other topmost windows
})
$wd.Start()
[Windows.Threading.Dispatcher]::Run()
'@
function Start-Overlay {
    if ($env:HELPER_NO_OVERLAY) { return }
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
        # the script is too long for -EncodedCommand (the command line limit is ~32k chars): run it from a temp file (UTF-8 with BOM for PS 5.1)
        $file = Join-Path $env:TEMP ('helpermcp-overlay-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
        [IO.File]::WriteAllText($file, $OverlayScript, (New-Object Text.UTF8Encoding $true)); $script:TmpDirs += $file
        $psi.Arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $file + '"'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardInput = $true
        $psi.EnvironmentVariables['HM_LABEL'] = (T 'Удалённое управление' 'Remote control'); $psi.EnvironmentVariables['HM_PPID'] = [string]$PID
        $psi.EnvironmentVariables['HM_LOST'] = (T 'Связь потеряна, переподключение…' 'Connection lost, reconnecting…')
        $script:OverlayProc = [Diagnostics.Process]::Start($psi)
        $script:OverlayIn = $script:OverlayProc.StandardInput; $script:OverlayIn.AutoFlush = $true
    } catch { }   # a missing overlay must never block the help session
}

function Cleanup-Children {
    foreach ($c in $Children.Values) { Stop-Tree $c.p }
    if ($script:OverlayProc) { try { $script:OverlayProc.Kill() } catch { } }
    foreach ($d in @($script:NodeDir) + $script:TmpDirs) { if ($d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } }
}

# Light requests (screenshots, sysinfo, file reads) are answered even while a long command runs: the live viewer and the AI's
# screenshots never freeze behind a 5-minute install or render. Heavy ones wait their turn.
$LightTools = 'screenshot', 'sysinfo', 'list_dir', 'read_file', 'mcp_tools'
$script:Deferred = New-Object System.Collections.ArrayList
$script:Token = $null; $script:Mode = 'full'; $script:LastPump = [DateTime]::MinValue

function Process-Command($cmd) {
    $name = $cmd.tool; $a = $cmd.args
    $short = ($cmd.args | ConvertTo-Json -Compress); if ($short.Length -gt 200) { $short = $short.Substring(0, 200) }
    Write-Host "[helper] $name $short"
    $res = @{ id = $cmd.id }
    try {
        if ($script:Mode -eq 'ask' -and $AskTools -contains $name) {
            $yn = Read-Host (T 'Разрешить? [y/N]' 'Allow? [y/N]')
            if ($yn -notmatch '^(y|yes|д|да)$') { throw 'User denied this action.' }
        }
        $fn = @{ screenshot = 'Do-Screenshot'; click = 'Do-Click'; move = 'Do-Move'; drag = 'Do-Drag'; scroll = 'Do-Scroll'; type_text = 'Do-TypeText'; press_key = 'Do-PressKey'
            run = 'Do-Run'; read_file = 'Do-ReadFile'; write_file = 'Do-WriteFile'; list_dir = 'Do-ListDir'; sysinfo = 'Do-SysInfo'
            fetch_file = 'Do-FetchFile'; start_process = 'Do-StartProcess'; mcp_start = 'Do-McpStart'; mcp_tools = 'Do-McpTools'; mcp_call = 'Do-McpCall'; mcp_stop = 'Do-McpStop' }[$name]
        if (-not $fn) { throw "Unknown tool $name" }
        $res.ok = $true; $res.data = & $fn $a
    } catch { $res.ok = $false; $res.error = $_.Exception.Message }
    for ($attempt = 0; $attempt -lt 5; $attempt++) {   # a lost result would leave the operator waiting for a call that already finished
        try { Post-Result $res $script:Token; break }
        catch { $sc = 0; try { $sc = [int]$_.Exception.Response.StatusCode } catch { }; if ($sc -eq 401 -or $sc -eq 410) { break }; Start-Sleep (1 + $attempt) }
    }
}

# Called from the wait loops of long operations: take a look at the relay without blocking, serve light requests right away.
function Pump-Light {
    if (-not $script:Token -or ([DateTime]::UtcNow - $script:LastPump).TotalMilliseconds -lt 400) { return }
    $script:LastPump = [DateTime]::UtcNow
    try { $r = Api '/a/poll?w=0' $null $script:Token 10 } catch { return }
    if ($r.StatusCode -ne 200 -or -not $r.Content) { return }
    $cmd = $r.Content | ConvertFrom-Json
    if ($cmd.tool -eq 'bye') { [void]$script:Deferred.Add($cmd); return }
    if ($LightTools -contains $cmd.tool) { Process-Command $cmd } else { [void]$script:Deferred.Add($cmd) }
}

# Tell the overlay about connection state and effects (click ripple, drag, scroll ...). Never throws.
function Overlay-Send($line) { try { if ($script:OverlayIn) { $script:OverlayIn.WriteLine($line) } } catch { } }

$script:Net = 'ok'
function Net-State($st) {
    if ($script:Net -eq $st) { return }
    $script:Net = $st
    Write-Host ("[helper] " + $(if ($st -eq 'lost') { 'connection lost, retrying ...' } else { 'connection restored' }))
    Overlay-Send "state $st"   # the overlay turns orange while the link is down
}

function Register-Agent($mode, $resume) {
    $body = @{ os = (Get-CimInstance Win32_OperatingSystem).Caption; host = $env:COMPUTERNAME; user = $env:USERNAME; mode = $mode }
    if ($resume) { $body.resume = $resume }   # the server may have forgotten us (restart, long outage): ask for the same code back
    (Api '/a/register' $body $null 20).Content | ConvertFrom-Json
}

function Start-Helper {
    $mode = $env:HELPER_MODE
    if ($mode -ne 'ask' -and $mode -ne 'full') {
        $ans = Read-Host (T 'Режим: [1] спрашивать про каждое действие (рекомендуется)  [2] полный доступ' 'Mode: [1] ask before every action (recommended)  [2] full access')
        $mode = if ($ans.Trim() -eq '2') { 'full' } else { 'ask' }
    }
    $script:Mode = $mode
    $wait = 1.0
    while ($true) {   # the server can be unreachable right at the start (no internet yet, VPN still connecting): keep trying
        try { $r = Register-Agent $mode $null; break }
        catch { Write-Host "[helper] cannot reach the server, retrying ..."; Start-Sleep -Milliseconds ([int]([Math]::Min($wait, 10.0) * 1000)); $wait *= 1.7 }
    }
    $token = $r.token; $script:Token = $token; $code = $r.code
    Write-Host ''
    Write-Host ("  " + (T 'УДАЛЁННАЯ ПОМОЩЬ. Код сессии:' 'REMOTE HELP. Session code:') + "  " + $code) -ForegroundColor Yellow
    Write-Host ("  " + (T 'Назови этот код тому, кто тебе помогает. Закрой окно или Ctrl+C - доступ пропадёт.' 'Give this code to your helper. Close this window or press Ctrl+C to stop.'))
    Write-Host ''
    Start-Overlay
    $fails = 0; $delay = 1.0
    try {
        while ($true) {
            if ($script:Deferred.Count) { $cmd = $script:Deferred[0]; $script:Deferred.RemoveAt(0) }
            else {
                $failed = $false; $resp = $null
                try { $resp = Api '/a/poll' $null $script:Token 22 }   # the relay answers within 15 s; anything longer is a dead connection
                catch {
                    $sc = 0; try { $sc = [int]$_.Exception.Response.StatusCode } catch { }
                    if ($sc -eq 410) { Write-Host (T 'сессия закрыта (помощник завершил её)' 'session closed (ended by the helper)'); return }
                    if ($sc -eq 401) {   # unknown to the server: it was reset or we were away too long -> register again, same code if possible
                        try {
                            $r = Register-Agent $mode $code; $script:Token = $r.token; $code = $r.code
                            Write-Host "[helper] registered again, session code: $code"
                            $fails = 0; $delay = 1.0; Net-State 'ok'; continue
                        } catch { }
                    }
                    $failed = $true
                }
                if ($failed) {   # no internet, DNS, VPN switch, TLS, timeouts ... keep trying with backoff
                    $fails++
                    if ($fails -ge 2) { Net-State 'lost' }
                    try { [Net.ServicePointManager]::FindServicePoint([Uri]$RELAY).CloseConnectionGroup('') | Out-Null } catch { }   # drop connections that died with the old route
                    Start-Sleep -Milliseconds ([int]([Math]::Min($delay, 10.0) * 1000 * (0.8 + 0.4 * (Get-Random -Maximum 1.0))))
                    $delay = $delay * 1.7; continue
                }
                $fails = 0; $delay = 1.0; Net-State 'ok'
                if ($resp.StatusCode -ne 200 -or -not $resp.Content) { continue }
                $cmd = $resp.Content | ConvertFrom-Json
            }
            if ($cmd.tool -eq 'bye') { Write-Host 'session closed'; return }
            Process-Command $cmd
        }
    } finally {
        Cleanup-Children
        try { [void](Api '/a/bye' @{} $script:Token 5) } catch { }
    }
}
Start-Helper
$ErrorActionPreference = $prevEAP
