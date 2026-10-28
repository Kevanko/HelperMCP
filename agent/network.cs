namespace N__BUILD__ {
using System;
using System.IO;
using System.Text;
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Net.NetworkInformation;
using System.Security.Authentication;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;

  // Independent sockets: never change routes, DNS, VPN state or the relay proxy.
  public static class Network {
    static readonly object workLock = new object();
    static readonly HashSet<Socket> workSockets = new HashSet<Socket>();
    static readonly ThreadLocal<int> workContext = new ThreadLocal<int>(() => 0);
    static int workGeneration;
    public static void CancelWork() {
      lock (workLock) {
        workGeneration++;
        foreach (var socket in workSockets) try { socket.Close(); } catch { }
        workSockets.Clear();
      }
    }
    static int BeginWork() { CancelWork(); return workGeneration; }
    static bool Cancelled { get { return workContext.Value != 0 && workContext.Value != workGeneration; } }
    public class Path {
      public int index; public string name, source; public bool vpn;
      public string[] dns; public long link_bps;
    }
    public class DnsResult {
      public string server, error; public string[] addresses = new string[0]; public long ms;
    }
    public class Sample {
      public DateTime started_utc = DateTime.UtcNow;
      public string ip, source, stage = "dns", error;
      public long tcp_ms = -1, tls_ms = -1, first_byte_ms = -1, total_ms;
      public int status, bytes; public double download_mbps;
    }
    public class Target {
      public string host, server_name; public int port; public bool tls, http; public string path = "/";
    }
    public class Result {
      public Path route; public Target target; public DnsResult[] dns;
      public List<Sample> samples = new List<Sample>();
      public List<string> findings = new List<string>();
      public string scope = "IPv4; adapter binding does not bypass WinDivert/WFP/zapret; no application/protocol handshake";
    }
    public class LoadResult {
      public Result idle, during_load; public int downloaded_bytes, overlapping_samples;
      public string scope = "Bounded download, max 3 MiB; NOT proof of saturation or bufferbloat. Compare TCP/TLS/TTFB and CPU; small responses may create no meaningful load.";
    }
    public static bool Fake(string ip) {
      IPAddress a; if (!IPAddress.TryParse(ip, out a) || a.AddressFamily != AddressFamily.InterNetwork) return false;
      var b = a.GetAddressBytes(); return b[0] == 198 && (b[1] == 18 || b[1] == 19);
    }
    public static Path[] Paths(int index, bool matrix) {
      var list = new List<Path>();
      if (index == 0) list.Add(new Path { index = 0, name = "default (may use TUN)", source = "", dns = new string[0] });
      foreach (var ni in NetworkInterface.GetAllNetworkInterfaces()) {
        if (ni.OperationalStatus != OperationalStatus.Up || ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
        try {
          var p = ni.GetIPProperties(); var v = p.GetIPv4Properties(); if (v == null) continue;
          var ips = new List<string>(); foreach (var u in p.UnicastAddresses) if (u.Address.AddressFamily == AddressFamily.InterNetwork && !u.Address.ToString().StartsWith("169.254.")) ips.Add(u.Address.ToString());
          if (ips.Count == 0) continue;
          bool vpn = System.Text.RegularExpressions.Regex.IsMatch(ni.Name + " " + ni.Description, "tun|tap|vpn|wintun|wireguard|clash|mihomo|sing-box|warp|koala|incy|happ|tailscale|zerotier|amnezia", System.Text.RegularExpressions.RegexOptions.IgnoreCase) || ni.NetworkInterfaceType == NetworkInterfaceType.Ppp || ni.NetworkInterfaceType == NetworkInterfaceType.Tunnel;
          if (index != 0 && index != v.Index) continue;
          bool virtualAdapter = System.Text.RegularExpressions.Regex.IsMatch(ni.Name + " " + ni.Description, "Hyper-V|vEthernet|VirtualBox|VMware|WSL|Bluetooth", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
          if (index == 0 && (!matrix || (!vpn && (virtualAdapter || p.GatewayAddresses.Count == 0)))) continue;
          var dns = new List<string>(); foreach (var d in p.DnsAddresses) if (d.AddressFamily == AddressFamily.InterNetwork) dns.Add(d.ToString());
          list.Add(new Path { index = v.Index, name = ni.Name, source = ips[0], dns = dns.ToArray(), vpn = vpn, link_bps = ni.Speed });
        } catch { }
      }
      list.Sort((a, b) => a.index == 0 && b.index == 0 ? 0 : a.index == 0 ? -1 : b.index == 0 ? 1 : a.vpn.CompareTo(b.vpn));
      if (index == 0 && list.Count > 5) list.RemoveRange(5, list.Count - 5);
      if (list.Count == 0) throw new ArgumentException("Adapter is down, missing or has no usable IPv4 address; no fallback to default was made.");
      return list.ToArray();
    }
    static Socket Sock(Path p, SocketType type, ProtocolType protocol, int ms) {
      var s = new Socket(AddressFamily.InterNetwork, type, protocol);
      try {
        if (workContext.Value != 0) lock (workLock) {
          if (Cancelled) throw new OperationCanceledException(); workSockets.Add(s);
        }
        s.ReceiveTimeout = ms; s.SendTimeout = ms;
        if (p.index > 0) {
          s.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31, IPAddress.HostToNetworkOrder(p.index));
          s.Bind(new IPEndPoint(IPAddress.Parse(p.source), 0));
        }
        return s;
      } catch { s.Close(); throw; }
    }
    static int U16(byte[] b, int o) { if (o + 1 >= b.Length) throw new IOException("truncated DNS"); return b[o] * 256 + b[o + 1]; }
    static int SkipName(byte[] b, int o) {
      for (int n = 0; n < 128 && o < b.Length; n++) {
        int v = b[o++]; if (v == 0) return o;
        if ((v & 192) == 192) { if (o >= b.Length) break; return o + 1; }
        if (v > 63 || o + v >= b.Length) break; o += v;
      }
      throw new IOException("invalid DNS name");
    }
    public static DnsResult Resolve(Path p, string host, string server, int ms) {
      var r = new DnsResult { server = server }; var sw = Stopwatch.StartNew();
      try {
        IPAddress literal; if (IPAddress.TryParse(host, out literal)) {
          if (literal.AddressFamily != AddressFamily.InterNetwork) throw new IOException("IPv6 not supported by this probe");
          r.addresses = new[] { literal.ToString() }; return r;
        }
        if (server == "system") {
          var task = Task.Factory.StartNew(() => Dns.GetHostAddresses(host));
          if (!task.Wait(ms)) throw new TimeoutException("system DNS timeout");
          var a = new List<string>(); foreach (var ip in task.Result) if (ip.AddressFamily == AddressFamily.InterNetwork) a.Add(ip.ToString()); r.addresses = a.ToArray();
        } else {
          if (Fake(server)) throw new IOException("fake-IP resolver: cannot establish a physical DNS baseline");
          byte[] id = Guid.NewGuid().ToByteArray(); var q = new List<byte> { id[0], id[1], 1, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
          foreach (var label in new System.Globalization.IdnMapping().GetAscii(host).TrimEnd('.').Split('.')) {
            if (label.Length == 0 || label.Length > 63) throw new ArgumentException("invalid hostname");
            q.Add((byte)label.Length); q.AddRange(Encoding.ASCII.GetBytes(label));
          }
          q.AddRange(new byte[] { 0, 0, 1, 0, 1 });
          using (var s = Sock(p, SocketType.Dgram, ProtocolType.Udp, ms)) {
            s.Connect(IPAddress.Parse(server), 53); s.Send(q.ToArray());
            byte[] buf = new byte[4096]; int size = s.Receive(buf); Array.Resize(ref buf, size);
            if (size < 12 || buf[0] != id[0] || buf[1] != id[1] || (buf[2] & 128) == 0) throw new IOException("invalid DNS response");
            if ((buf[2] & 2) != 0) throw new IOException("DNS response truncated; TCP fallback not tested");
            if ((buf[3] & 15) != 0) throw new IOException("DNS rcode " + (buf[3] & 15));
            int o = 12; for (int k = 0; k < U16(buf, 4); k++) o = SkipName(buf, o) + 4;
            var a = new List<string>();
            for (int k = 0; k < U16(buf, 6); k++) {
              o = SkipName(buf, o); int type = U16(buf, o), cls = U16(buf, o + 2), len = U16(buf, o + 8); o += 10;
              if (o + len > size) throw new IOException("truncated DNS answer");
              if (type == 1 && cls == 1 && len == 4) a.Add(new IPAddress(new byte[] { buf[o], buf[o+1], buf[o+2], buf[o+3] }).ToString()); o += len;
            }
            r.addresses = a.ToArray();
          }
        }
        if (r.addresses.Length == 0) r.error = "no IPv4 answer";
      } catch (Exception e) { r.error = Error(e); }
      finally { r.ms = sw.ElapsedMilliseconds; }
      return r;
    }
    static string Error(Exception e) {
      while (e.InnerException != null) e = e.InnerException;
      var se = e as SocketException; return se != null ? se.SocketErrorCode.ToString() : e is IOException ? "IO: " + e.Message : e.GetType().Name;
    }
    static string Line(Stream stream) {
      var text = new StringBuilder();
      while (text.Length < 512) { int b = stream.ReadByte(); if (b < 0) throw new IOException("truncated chunk header"); if (b == 10) return text.ToString().TrimEnd('\r'); text.Append((char)b); }
      throw new IOException("chunk header too long");
    }
    public static Sample Probe(Path p, Target t, string ip, int ms, int bytes) {
      var r = new Sample { ip = ip, stage = "tcp" }; var sw = Stopwatch.StartNew();
      try {
        if (Fake(ip) && p.index > 0 && !p.vpn) { r.stage = "dns"; r.error = "fake-IP refused on physical adapter"; return r; }
        using (var s = Sock(p, SocketType.Stream, ProtocolType.Tcp, ms))
        using (var timer = new Timer(_ => { try { s.Close(); } catch { } }, null, ms * 3, Timeout.Infinite)) {
          var ar = s.BeginConnect(IPAddress.Parse(ip), t.port, null, null);
          using (ar.AsyncWaitHandle) { if (!ar.AsyncWaitHandle.WaitOne(ms)) throw new TimeoutException(); s.EndConnect(ar); }
          r.tcp_ms = sw.ElapsedMilliseconds; r.source = s.LocalEndPoint.ToString();
          using (var net = new NetworkStream(s, false)) {
            Stream stream = net; SslStream ssl = null;
            try {
              if (t.tls) {
                r.stage = "tls"; ssl = new SslStream(net, false);
                ssl.ReadTimeout = ms; ssl.WriteTimeout = ms;
                var ts = Stopwatch.StartNew(); ssl.AuthenticateAsClient(string.IsNullOrEmpty(t.server_name) ? t.host : t.server_name, null, SslProtocols.None, false); r.tls_ms = ts.ElapsedMilliseconds; stream = ssl;
              }
              if (!t.http) { r.stage = "connected"; return r; }
              r.stage = "http";
              var request = Encoding.ASCII.GetBytes("GET " + t.path + " HTTP/1.1\r\nHost: " + t.host + ":" + t.port + "\r\nUser-Agent: HelperMCP-network/1\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n"); stream.Write(request, 0, request.Length);
              var head = new List<byte>(); var bodyTime = Stopwatch.StartNew();
              while (head.Count < 16384) {
                int b = stream.ReadByte(); if (b < 0) throw new IOException("EOF before headers");
                if (r.first_byte_ms < 0) r.first_byte_ms = sw.ElapsedMilliseconds;
                head.Add((byte)b); int n = head.Count;
                if (n >= 4 && head[n-4] == 13 && head[n-3] == 10 && head[n-2] == 13 && head[n-1] == 10) break;
              }
              string[] status = Encoding.ASCII.GetString(head.ToArray()).Split('\n')[0].Trim().Split(' ');
              if (status.Length < 2 || !int.TryParse(status[1], out r.status)) throw new IOException("invalid HTTP status");
              string headers = Encoding.ASCII.GetString(head.ToArray());
              bool chunked = System.Text.RegularExpressions.Regex.IsMatch(headers, @"(?im)^Transfer-Encoding:\s*.*chunked");
              var cl = System.Text.RegularExpressions.Regex.Match(headers, @"(?im)^Content-Length:\s*(\d+)");
              long length = cl.Success ? long.Parse(cl.Groups[1].Value) : -1;
              r.stage = "body"; byte[] data = new byte[8192]; long remaining = chunked ? 0 : length;
              while (r.bytes < bytes) {
                if (chunked && remaining == 0) {
                  string line = Line(stream).Split(';')[0]; long chunk;
                  if (!long.TryParse(line, System.Globalization.NumberStyles.HexNumber, System.Globalization.CultureInfo.InvariantCulture, out chunk) || chunk < 0) throw new IOException("invalid chunk length");
                  remaining = chunk; if (remaining == 0) break;
                }
                if (!chunked && remaining == 0) break;
                int want = Math.Min(data.Length, bytes - r.bytes); if (remaining > 0) want = (int)Math.Min(want, remaining);
                int n = stream.Read(data, 0, want);
                if (n <= 0) { if (remaining > 0) throw new IOException("truncated HTTP body"); break; }
                r.bytes += n; if (remaining > 0) remaining -= n;
                if (chunked && remaining == 0 && Line(stream) != "") throw new IOException("invalid chunk terminator");
              }
              r.download_mbps = Math.Round(r.bytes * 8.0 / Math.Max(.001, bodyTime.Elapsed.TotalSeconds) / 1000000, 3);
              r.stage = "response";
            } finally { if (ssl != null) ssl.Dispose(); }
          }
        }
      } catch (Exception e) { r.error = Error(e); }
      finally { r.total_ms = sw.ElapsedMilliseconds; }
      return r;
    }
    public static Result Check(Path p, Target t, int repeat, int ms, bool speed, string resolver, DateTime deadline) {
      var r = new Result { route = p, target = t }; var dns = new List<DnsResult>();
      if (p.index == 0) dns.Add(Resolve(p, t.host, "system", ms));
      else if (p.dns.Length > 0) dns.Add(Resolve(p, t.host, p.dns[0], ms));
      if (resolver != "") dns.Add(Resolve(p, t.host, resolver, ms));
      r.dns = dns.ToArray(); string chosen = null;
      foreach (var d in dns) foreach (var ip in d.addresses) if (chosen == null && (!Fake(ip) || p.index == 0 || p.vpn)) chosen = ip;
      if (chosen == null) { r.findings.Add("No usable IPv4 DNS answer on this path; TCP/TLS/HTTP not tested."); return r; }
      for (int n = 0; n < repeat; n++) {
        if (Cancelled) { r.findings.Add("Cancelled; remaining samples NOT TESTED."); break; }
        if (DateTime.UtcNow >= deadline) { r.findings.Add("Time budget exhausted; remaining samples NOT TESTED."); break; }
        r.samples.Add(Probe(p, t, chosen, ms, speed ? 1048576 : 4096));
      }
      repeat = r.samples.Count;
      int fail = 0; long min = long.MaxValue, max = 0;
      foreach (var s in r.samples) { if (s.error != null) fail++; if (s.tcp_ms >= 0) { min = Math.Min(min, s.tcp_ms); max = Math.Max(max, s.tcp_ms); } }
      r.findings.Add(fail + "/" + repeat + " probe failures (not ICMP packet loss).");
      if (max > 1000 || (min != long.MaxValue && max - min > 300)) r.findings.Add("High/variable TCP connect latency; compare idle and loaded measurements on the SAME path.");
      foreach (var s in r.samples) {
        if (s.error != null && s.stage == "tls") { r.findings.Add("TCP connected, TLS failed: certificate, interception, server or SNI filtering are candidates; SNI block is NOT proven."); break; }
      }
      foreach (var s in r.samples) if (s.status >= 400) { r.findings.Add("HTTP rejection is not working application access (403/401/429 may be server policy)."); break; }
      r.findings.Add("Only first resolved IPv4 tested; no VPN authentication, UDP/QUIC, Discord voice, video or game verification.");
      return r;
    }
    public static Result[] Batch(Path[] paths, Target[] targets, int repeat, int ms, bool speed, string resolver, int job) {
      var results = new Result[paths.Length * targets.Length]; int next = -1;
      var deadline = DateTime.UtcNow.AddSeconds(55); var threads = new List<Thread>();
      for (int w = 0; w < Math.Min(4, results.Length); w++) {
        var thread = new Thread(() => {
          workContext.Value = job;
          while (true) {
            int k = Interlocked.Increment(ref next); if (k >= results.Length) break;
            var p = paths[k / targets.Length]; var t = targets[k % targets.Length];
            try {
              if (Cancelled || DateTime.UtcNow >= deadline) { results[k] = new Result { route = p, target = t, findings = new List<string> { "NOT TESTED: cancelled or time budget exhausted" } }; continue; }
              results[k] = Check(p, t, repeat, ms, speed, resolver, deadline);
            } catch (Exception e) { results[k] = new Result { route = p, target = t, findings = new List<string> { "Probe failed: " + Error(e) } }; }
          }
        }) { IsBackground = true }; threads.Add(thread); thread.Start();
      }
      foreach (var t in threads) t.Join(); return results;
    }
    public static Task<Result[]> StartBatch(Path[] paths, Target[] targets, int repeat, int ms, bool speed, string resolver) {
      int job = BeginWork(); return Task.Factory.StartNew(() => Batch(paths, targets, repeat, ms, speed, resolver, job));
    }
    public static Task<LoadResult> StartLoad(Path path, Target control, Target download, int ms, string resolver) {
      int job = BeginWork();
      return Task.Factory.StartNew(() => {
        workContext.Value = job;
        try {
        var result = new LoadResult(); var deadline = DateTime.UtcNow.AddSeconds(55);
        result.idle = Check(path, control, 2, ms, false, resolver, deadline);
        var dns = Resolve(path, download.host, path.index > 0 && path.dns.Length > 0 ? path.dns[0] : "system", ms);
        string ip = null; foreach (var a in dns.addresses) if (!Fake(a) || path.vpn || path.index == 0) { ip = a; break; }
        if (ip == null) { dns = Resolve(path, download.host, resolver, ms); foreach (var a in dns.addresses) if (!Fake(a)) { ip = a; break; } }
        if (ip == null) { result.scope += " Load target DNS failed; loaded phase NOT TESTED."; return result; }
        var started = new ManualResetEventSlim(false);
        DateTime loadStart = DateTime.MinValue, loadEnd = DateTime.MinValue;
        var load = Task.Factory.StartNew(() => {
          workContext.Value = job;
          try {
          loadStart = DateTime.UtcNow; started.Set(); int count = 0; var until = DateTime.UtcNow.AddSeconds(8);
          for (int n = 0; n < 3 && !Cancelled && DateTime.UtcNow < until; n++) count += Probe(path, download, ip, ms, 1048576).bytes;
          loadEnd = DateTime.UtcNow;
          return count;
          } finally { workContext.Value = 0; }
        });
        started.Wait();
        result.during_load = Check(path, control, 2, ms, false, resolver, deadline);
        result.downloaded_bytes = load.Result; started.Dispose();
        foreach (var sample in result.during_load.samples) if (sample.started_utc < loadEnd && sample.started_utc.AddMilliseconds(sample.total_ms) > loadStart) result.overlapping_samples++;
        if (result.overlapping_samples == 0) result.scope += " No latency sample overlapped the load; repeat with a suitable download target before comparing.";
        return result;
        } finally { workContext.Value = 0; }
      });
    }
  }
}
