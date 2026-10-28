using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.IO;
using System.Net;

namespace HelperPointer {
  public interface IPointerSink { void Move(int x, int y); void Button(uint flags); }
  public interface IKeyboardSink { void Key(int vk, bool extended, bool up); }
  public sealed class NativeSink : IPointerSink, IKeyboardSink {
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll",SetLastError=true)] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr extra);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk,byte scan,uint flags,UIntPtr extra);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code,uint mapType);
    public NativeSink() { SetProcessDPIAware(); }
    public void Move(int x, int y) { if (!SetCursorPos(x,y)) throw new InvalidOperationException("Desktop rejected pointer input (Win32 "+Marshal.GetLastWin32Error()+")"); }
    public void Button(uint flags) { mouse_event(flags,0,0,0,UIntPtr.Zero); }
    public void Key(int vk,bool extended,bool up) { keybd_event((byte)vk,(byte)MapVirtualKey((uint)vk,0),(extended?1u:0u)|(up?2u:0u),UIntPtr.Zero); }
  }
  public sealed class KeyboardLease : IDisposable {
    readonly object gate=new object();readonly IKeyboardSink sink;readonly Timer timer;readonly Stopwatch clock=Stopwatch.StartNew();readonly int ttl;
    readonly Dictionary<int,bool> held=new Dictionary<int,bool>();readonly Dictionary<string,long> sequences=new Dictionary<string,long>();string owner="";long deadline;bool disposed;
    public KeyboardLease(IKeyboardSink sink,int ttlMs){this.sink=sink;if(ttlMs<200||ttlMs>5000)throw new ArgumentOutOfRangeException("ttlMs");ttl=ttlMs;timer=new Timer(delegate{lock(gate){try{if(held.Count>0&&clock.ElapsedMilliseconds>=deadline)Release();}catch{}}},null,50,50);}
    void Release(){foreach(var pair in new List<KeyValuePair<int,bool>>(held)){sink.Key(pair.Key,pair.Value,true);held.Remove(pair.Key);}owner="";}
    public string Handle(string who,long seq,string op,int vk,bool extended){lock(gate){
      if(disposed)throw new ObjectDisposedException("KeyboardLease");if(sink==null)throw new InvalidOperationException("Keyboard worker unavailable");
      if(held.Count>0&&clock.ElapsedMilliseconds>=deadline)Release();
      if(op=="release"){if(owner==who)Release();return "released";}
      long previous;if(sequences.TryGetValue(who,out previous)&&seq<=previous)return "duplicate";
      if(sequences.Count>=256&&!sequences.ContainsKey(who)){string remove=null;foreach(string key in sequences.Keys)if(key!=owner){remove=key;break;}if(remove!=null)sequences.Remove(remove);}
      sequences[who]=seq;
      if(op=="kcancel"){if(owner==who)Release();return "released";}
      if(owner!=""&&owner!=who)throw new InvalidOperationException("Another keyboard owner is active");
      if(op=="kkeep"){if(owner==who)deadline=clock.ElapsedMilliseconds+ttl;return "held";}
      if(vk<8||vk>254)throw new InvalidOperationException("Invalid keyboard code");
      deadline=clock.ElapsedMilliseconds+ttl;
      if(op=="kdown"){if(!held.ContainsKey(vk)&&held.Count>=32)throw new InvalidOperationException("Too many held keys");owner=who;held[vk]=extended;try{sink.Key(vk,extended,false);}catch{Release();throw;}return "held";}
      if(op=="kup"){bool was;if(held.TryGetValue(vk,out was)){sink.Key(vk,was,true);held.Remove(vk);}if(held.Count==0)owner="";return "released";}
      throw new InvalidOperationException("Unknown keyboard operation");
    }}
    public void Dispose(){lock(gate){if(disposed)return;Release();disposed=true;timer.Dispose();}}
  }
  // Runs in a separate process. The timer is independent of PowerShell/relay;
  // EOF (including parent process exit) also releases the held button.
  public sealed class PointerLease : IDisposable {
    readonly object gate = new object(); readonly IPointerSink sink; readonly Timer timer;
    readonly int ttl; readonly Stopwatch clock = Stopwatch.StartNew();
    readonly Dictionary<string,long> sequences = new Dictionary<string,long>();
    string owner = "", gesture = ""; uint up; long deadline; bool disposed;
    public PointerLease(IPointerSink sink, int ttlMs) {
      if (ttlMs < 200 || ttlMs > 5000) throw new ArgumentOutOfRangeException("ttlMs");
      this.sink=sink; ttl=ttlMs;
      timer=new Timer(delegate { lock(gate) { try { Expire(); } catch { /* retry release on the next tick */ } } },null,50,50);
    }
    void Release() { if(up!=0) { sink.Button(up); up=0; } owner=""; gesture=""; }
    void Expire() { if(up!=0 && clock.ElapsedMilliseconds>=deadline) Release(); }
    public string Handle(string who, string id, long seq, string op, int x, int y, string button) {
      lock(gate) {
        if(disposed)throw new ObjectDisposedException("PointerLease");
        Expire();
        if(op=="release") { if(owner==who)Release(); return "released"; }
        long previous;
        if(sequences.TryGetValue(who,out previous) && seq<=previous)return "duplicate";
        // A fresh tab has a fresh owner token. Bound bookkeeping for long runs.
        if(sequences.Count>=256 && !sequences.ContainsKey(who)) {
          string remove=null; foreach(string key in sequences.Keys)if(key!=owner){remove=key;break;}
          if(remove!=null)sequences.Remove(remove);
        }
        sequences[who]=seq;
        if(op=="cancel") { if(owner==who && gesture==id)Release(); return "released"; }
        if(op=="hover"){if(up!=0&&owner!=who)throw new InvalidOperationException("Another pointer owner is active");sink.Move(x,y);return "moved";}
        if(op=="down") {
          if(up!=0)throw new InvalidOperationException("Another pointer gesture is held");
          sink.Move(x,y); owner=who; gesture=id; deadline=clock.ElapsedMilliseconds+ttl;
          uint down=2; up=4;
          if(button=="right"){down=8;up=16;}else if(button=="middle"){down=32;up=64;}
          try { sink.Button(down); } catch { Release(); throw; }
          return "held";
        }
        if(owner!=who || gesture!=id || up==0) {
          if(op=="up")return "released";
          throw new InvalidOperationException("Pointer lease expired or gesture is not active");
        }
        if(op=="up") { try { sink.Move(x,y); } finally { Release(); } return "released"; }
        if(op=="move")sink.Move(x,y);
        else if(op!="keep")throw new InvalidOperationException("Unknown pointer operation");
        deadline=clock.ElapsedMilliseconds+ttl; return "held";
      }
    }
    public void Dispose() { lock(gate) { if(disposed)return; Release(); disposed=true; timer.Dispose(); } }
  }
  public static class PointerProgram {
    static bool Hex(string value,int length) { if(value.Length!=length)return false;foreach(char c in value)if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return false;return true; }
    static volatile bool networkStop;static HttpWebRequest networkRequest;
    public static void Main() { if(string.IsNullOrEmpty(Environment.GetEnvironmentVariable("HELPER_INPUT_RELAY")))Run(new NativeSink());else NetworkLoop(); }
    sealed class FreshReader : TextReader {
      readonly TextReader input;readonly long epoch;readonly Stopwatch elapsed=Stopwatch.StartNew();public FreshReader(TextReader input,string serverTime){this.input=input;if(!long.TryParse(serverTime,out epoch))epoch=(DateTime.UtcNow.Ticks-621355968000000000L)/10000;}
      public override string ReadLine(){string line;while((line=input.ReadLine())!=null){if(line.Length==0)continue;int split=line.IndexOf('|');long when;long now=epoch+elapsed.ElapsedMilliseconds;
        if(split<0||!long.TryParse(line.Substring(0,split),out when)||now-when>1500||when-now>5000)continue;return line.Substring(split+1);}return null;}
    }
    static void NetworkLoop(){
      // This worker is compiled for .NET Framework independently of the host
      // PowerShell process; it must not inherit Framework 4's TLS 1.0 default.
      ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;ServicePointManager.Expect100Continue=false;
      var relay=Environment.GetEnvironmentVariable("HELPER_INPUT_RELAY");var token=Environment.GetEnvironmentVariable("HELPER_INPUT_TOKEN");var proxy=Environment.GetEnvironmentVariable("HELPER_INPUT_PROXY");
      var parent=new Thread(delegate(){try{Console.In.ReadToEnd();}catch{}networkStop=true;try{if(networkRequest!=null)networkRequest.Abort();}catch{}}){IsBackground=true};parent.Start();
      while(!networkStop){try{
        var rq=(HttpWebRequest)WebRequest.Create(relay+"/a/input");networkRequest=rq;rq.Headers["Authorization"]="Bearer "+token;rq.Timeout=8000;rq.ReadWriteTimeout=5000;rq.ServicePoint.UseNagleAlgorithm=false;rq.ServicePoint.ConnectionLimit=4;
        if(!string.IsNullOrEmpty(proxy))rq.Proxy=new WebProxy(proxy);
        using(var response=rq.GetResponse())using(var reader=new StreamReader(response.GetResponseStream()))using(var fresh=new FreshReader(reader,response.Headers["x-input-clock"]))Run(new NativeSink(),fresh,TextWriter.Null,true);
      }catch{}finally{networkRequest=null;}if(!networkStop)Thread.Sleep(500);}
    }
    public static void Run(IPointerSink sink){Run(sink,Console.In,Console.Out,false);}
    static void Run(IPointerSink sink,TextReader input,TextWriter output,bool strict) {
      using(var lease=new PointerLease(sink,3000)) using(var keyboard=new KeyboardLease(sink as IKeyboardSink,3000)) {
        string line;
        while((line=input.ReadLine())!=null) {
          try {
            var a=line.Split(' '); long seq; int x,y;
            if(line.Length>512 || a.Length!=8 || !Hex(a[0],64) || !Hex(a[1],32) ||
              !long.TryParse(a[2],out seq) || seq<0 || seq>9007199254740991L ||
              !int.TryParse(a[4],out x) || !int.TryParse(a[5],out y) || Math.Abs((long)x)>=100000 || Math.Abs((long)y)>=100000 ||
              (a[6]!="left"&&a[6]!="right"&&a[6]!="middle") || a[7]!="v1" ||
              (a[3]!="down"&&a[3]!="hover"&&a[3]!="move"&&a[3]!="up"&&a[3]!="keep"&&a[3]!="cancel"&&a[3]!="release"&&a[3]!="kdown"&&a[3]!="kup"&&a[3]!="kkeep"&&a[3]!="kcancel"))throw new InvalidOperationException("Invalid pointer command");
            if(a[3]=="release"){lease.Handle(a[0],a[1],seq,a[3],x,y,a[6]);if(sink is IKeyboardSink)keyboard.Handle(a[0],seq,"release",0,false);output.WriteLine("OK released");}
            else output.WriteLine("OK "+(a[3].StartsWith("k")&&a[3]!="keep"?keyboard.Handle(a[0],seq,a[3],x,y==1):lease.Handle(a[0],a[1],seq,a[3],x,y,a[6])));
          }catch(Exception ex){if(strict)throw;output.WriteLine("ERR "+ex.Message.Replace('\r',' ').Replace('\n',' ')); }
        }
      }
    }
  }
}
