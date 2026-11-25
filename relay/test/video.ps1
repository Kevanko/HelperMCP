$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source = [IO.File]::ReadAllText((Join-Path $root 'agent/video.cs')).Replace('__BUILD__', 'VideoTest')
Add-Type -TypeDefinition ($source + @'
public static class VideoTestWorker {
 static bool Key(byte[] data){for(int i=0;i+4<data.Length;i++)if(data[i]==0&&data[i+1]==0&&data[i+2]==1&&(data[i+3]&31)==5)return true;return false;}
 public static void Run(){System.Exception error=null;var thread=new System.Threading.Thread(()=>{try{
  for(int pass=0;pass<2;pass++)using(var encoder=new FVideoTest.MfEncoder(640,360,30,1800000)){
   var rgb=new int[640*360];for(int i=0;i<rgb.Length;i++)rgb[i]=i%640<320?0xff0000:0x00ff00;
   int count=0,bytes=0;bool forced=false;
   for(int i=0;i<90;i++){
    if(i==45&&!encoder.ForceKeyFrame())throw new System.Exception("Key frame request rejected");
    foreach(var frame in encoder.EncodeRgb(rgb)){if(i==45&&Key(frame))forced=true;count++;bytes+=frame.Length;}
   }
   foreach(var frame in encoder.Finish()){count++;bytes+=frame.Length;}
   if(count!=90||bytes<1000||!forced)throw new System.Exception("Missing frames or requested IDR");
  }
 }catch(System.Exception e){error=e;}});thread.IsBackground=true;thread.SetApartmentState(System.Threading.ApartmentState.MTA);thread.Start();
 if(!thread.Join(30000))throw new System.TimeoutException("Encoder worker hung");if(error!=null)throw error;
 }
}
'@)
[VideoTestWorker]::Run()
Write-Output 'Media Foundation worker initialization, RGB encoding, forced IDR and repeated disposal PASS'

# Sample the existing bitmap without a second capture, retaining absolute-coordinate masks.
$agentSource = [IO.File]::ReadAllText((Join-Path $root 'agent/agent.ps1'))
$sampler = [regex]::Match($agentSource, '(?s)Add-Type -ReferencedAssemblies Accessibility, System.Drawing -TypeDefinition @"\r?\n.*?\r?\n"@')
if (-not $sampler.Success) { throw 'Missing screenshot sampler' }
Invoke-Expression ($sampler.Value.Replace('__BUILD__', 'SampleFixture'))
$bmp = New-Object Drawing.Bitmap 2, 1
try {
    $bmp.SetPixel(0, 0, [Drawing.Color]::Black)
    $bmp.SetPixel(1, 0, [Drawing.Color]::White)
    $first = [VSampleFixture.Probe]::Sample($bmp, 100, 50, 2, 1, [int[]]@(100, 50, 1, 1))
    $second = [VSampleFixture.Probe]::Sample($bmp, 100, 50, 2, 1, [int[]]@(100, 50, 1, 1))
    if (($first -join ',') -ne '0,255' -or ($second -join ',') -ne '0,255') { throw 'Screenshot fingerprint lost the mask or locked the bitmap' }
} finally { $bmp.Dispose() }
Write-Output 'Screenshot fingerprint uses the existing bitmap and retains cursor and overlay masks PASS'
