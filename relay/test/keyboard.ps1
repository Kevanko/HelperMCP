$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source=[IO.File]::ReadAllText((Join-Path $root 'agent/pointer.cs'))
Add-Type -TypeDefinition ($source+@'
namespace HelperPointer {
 public sealed class KeyboardFixture : IKeyboardSink {
  public readonly System.Collections.Generic.List<string> Events=new System.Collections.Generic.List<string>();
  public void Key(int vk,bool extended,bool up){lock(Events){Events.Add(vk+":"+extended+":"+up);}}
  public int Count {get{lock(Events){return Events.Count;}}}
 }
}
'@)
function Assert($value,$why){if(-not $value){throw $why}}
$sink=New-Object HelperPointer.KeyboardFixture
$lease=New-Object HelperPointer.KeyboardLease($sink,300)
try{
 Assert ($lease.Handle('a',1,'kdown',162,$false) -eq 'held') 'Ctrl down'
 Assert ($lease.Handle('a',2,'kdown',37,$true) -eq 'held') 'extended arrow down'
 Assert ($lease.Handle('a',2,'kdown',37,$true) -eq 'duplicate') 'duplicate keydown injected'
 Assert ($sink.Count -eq 2) 'duplicate changed keyboard'
 try{$null=$lease.Handle('b',1,'kdown',38,$true);throw 'ownership accepted'}catch{Assert ($_.Exception.Message -match 'Another keyboard owner') 'wrong owner error'}
 $null=$lease.Handle('b',2,'kcancel',0,$false)
 Assert ($sink.Count -eq 2) 'other owner released keys'
 Start-Sleep -Milliseconds 200
 $null=$lease.Handle('a',3,'kkeep',0,$false)
 Start-Sleep -Milliseconds 200
 Assert ($sink.Count -eq 2) 'keepalive failed'
 Start-Sleep -Milliseconds 200
 Assert ($sink.Count -eq 4) 'independent expiry did not release all keys'
 Assert ($lease.Handle('a',2,'kdown',37,$true) -eq 'duplicate') 'expired keydown replayed'
 $null=$lease.Handle('a',4,'kdown',37,$true)
 $null=$lease.Handle('a',5,'kdown',37,$true)
 Assert ($sink.Count -eq 6) 'intentional repeat lost'
 $null=$lease.Handle('a',6,'kup',37,$false)
 Assert ($sink.Events[6] -eq '37:True:True') 'keyup lost original extended flag'
 Assert ($lease.Handle('a',5,'kdown',37,$true) -eq 'duplicate') 'released keydown replayed'
 $null=$lease.Handle('a',10,'kcancel',0,$false)
 Assert ($lease.Handle('a',9,'kdown',37,$true) -eq 'duplicate') 'canceled keydown replayed'
 $null=$lease.Handle('a',11,'kdown',160,$false)
 $lease.Dispose()
 Assert ($sink.Events[$sink.Count-1] -eq '160:False:True') 'dispose left Shift held'
 Write-Output 'Keyboard lease: repeat, ownership, keepalive, independent expiry, extended keyup, replay cancellation and dispose PASS'
}finally{$lease.Dispose()}
