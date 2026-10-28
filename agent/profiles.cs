using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net.Security;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;
using YamlDotNet.Core;
using YamlDotNet.Core.Events;
using YamlDotNet.RepresentationModel;

namespace P__BUILD__ {
  // Closing the helper's handle (including abrupt process exit) closes the
  // job and terminates only the diagnostic core and its descendants.
  public sealed class ProfileProcess : IDisposable {
    public static readonly RemoteCertificateValidationCallback StrictCertificate = (sender, certificate, chain, errors) => errors == SslPolicyErrors.None;
    [StructLayout(LayoutKind.Sequential)] struct Basic { public long processTime, jobTime; public uint flags; public UIntPtr minWorking, maxWorking; public uint active; public UIntPtr affinity; public uint priority, scheduling; }
    [StructLayout(LayoutKind.Sequential)] struct Io { public ulong readOps, writeOps, otherOps, readBytes, writeBytes, otherBytes; }
    [StructLayout(LayoutKind.Sequential)] struct Extended { public Basic basic; public Io io; public UIntPtr processMemory, jobMemory, peakProcess, peakJob; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int type, ref Extended info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    IntPtr job; Timer timer;
    public Process Process { get; private set; }
    void CloseJob() { var handle = Interlocked.Exchange(ref job, IntPtr.Zero); if (handle != IntPtr.Zero) CloseHandle(handle); }
    public static ProfileProcess Start(string file, string arguments, string directory, int lifetimeMs) {
      var owner = new ProfileProcess();
      try {
        owner.job = CreateJobObject(IntPtr.Zero, null);
        var limits = new Extended { basic = new Basic { flags = 0x2000 } };
        if (owner.job == IntPtr.Zero || !SetInformationJobObject(owner.job, 9, ref limits, (uint)Marshal.SizeOf(typeof(Extended)))) throw new IOException("Diagnostic process guard unavailable");
        owner.Process = new Process { StartInfo = new ProcessStartInfo(file, arguments) { WorkingDirectory = directory, UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true } };
        foreach (string key in new[] { "SAFE_PATHS", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy", "NO_PROXY", "no_proxy" }) owner.Process.StartInfo.EnvironmentVariables.Remove(key);
        // Core output may include UUID/password on an invalid config. Discard it;
        // the report uses controlled stages and exit codes instead.
        owner.Process.OutputDataReceived += (sender, data) => { };
        owner.Process.ErrorDataReceived += (sender, data) => { };
        owner.Process.Start();
        if (!AssignProcessToJobObject(owner.job, owner.Process.Handle)) { try { owner.Process.Kill(); } catch { } throw new IOException("Diagnostic process guard attachment failed"); }
        owner.Process.BeginOutputReadLine(); owner.Process.BeginErrorReadLine();
        owner.timer = new Timer(state => owner.CloseJob(), null, lifetimeMs, Timeout.Infinite);
        return owner;
      } catch { owner.Dispose(); throw; }
    }
    public void Dispose() {
      if (timer != null) { timer.Dispose(); timer = null; }
      CloseJob();
      if (Process != null) { try { Process.WaitForExit(2000); } catch { } Process.Dispose(); Process = null; }
      GC.SuppressFinalize(this);
    }
    ~ProfileProcess() { CloseJob(); }
  }
  // Parse a local export as data. No deserializer, type activation, includes,
  // provider fetches or profile switching. Only endpoint metadata leaves here.
  public static class Profiles {
    public sealed class Endpoint { public string host, protocol; public int port; }
    sealed class Frame { public bool map, key = true; }
    sealed class Budget { public int left = 2000; }
    sealed class Identity : IEqualityComparer<YamlMappingNode> {
      public bool Equals(YamlMappingNode x, YamlMappingNode y) { return Object.ReferenceEquals(x, y); }
      public int GetHashCode(YamlMappingNode x) { return RuntimeHelpers.GetHashCode(x); }
    }
    static void Complete(Stack<Frame> stack) { if (stack.Count > 0 && stack.Peek().map) stack.Peek().key = !stack.Peek().key; }
    static void Validate(string text) {
      var clock = Stopwatch.StartNew(); var stack = new Stack<Frame>(); int count = 0, documents = 0;
      using (var input = new StringReader(text)) {
        var parser = new Parser(input);
        while (parser.MoveNext()) {
          if (++count > 100000 || clock.ElapsedMilliseconds > 2000) throw new InvalidDataException("YAML resource limit");
          var e = parser.Current;
          if (e is DocumentStart && ++documents > 1) throw new InvalidDataException("One YAML document required");
          if (e is MappingStart || e is SequenceStart) {
            if (stack.Count > 0 && stack.Peek().map && stack.Peek().key) throw new InvalidDataException("Scalar mapping keys required");
            if (stack.Count >= 48) throw new InvalidDataException("YAML nesting limit");
            stack.Push(new Frame { map = e is MappingStart });
          } else if (e is MappingEnd || e is SequenceEnd) { stack.Pop(); Complete(stack); }
          else if (e is Scalar || e is AnchorAlias) {
            if (stack.Count > 0 && stack.Peek().map && stack.Peek().key) {
              var scalar = e as Scalar;
              if (scalar == null || scalar.Value.Length > 256) throw new InvalidDataException("Scalar mapping keys required");
            }
            Complete(stack);
          }
        }
      }
    }
    static YamlNode Field(YamlMappingNode map, string name, HashSet<YamlMappingNode> visiting, int depth, Budget budget) {
      if (map == null) return null;
      if (--budget.left < 0 || depth > 48 || !visiting.Add(map)) throw new InvalidDataException("YAML merge limit or cycle");
      try {
        foreach (var entry in map.Children) {
          var key = entry.Key as YamlScalarNode;
          if (key != null && key.Value == name) return entry.Value;
        }
        foreach (var entry in map.Children) {
          var key = entry.Key as YamlScalarNode;
          if (key == null || key.Value != "<<") continue;
          var parent = entry.Value as YamlMappingNode;
          if (parent != null) { var found = Field(parent, name, visiting, depth + 1, budget); if (found != null) return found; continue; }
          var parents = entry.Value as YamlSequenceNode;
          if (parents == null) throw new InvalidDataException("Invalid YAML merge");
          foreach (var item in parents.Children) {
            parent = item as YamlMappingNode;
            if (parent == null) throw new InvalidDataException("Invalid YAML merge");
            var found = Field(parent, name, visiting, depth + 1, budget); if (found != null) return found;
          }
        }
        return null;
      } finally { visiting.Remove(map); }
    }
    static YamlNode Field(YamlMappingNode map, string name) { return Field(map, name, new HashSet<YamlMappingNode>(new Identity()), 0, new Budget()); }
    static string Value(YamlMappingNode map, string name) { var scalar = Field(map, name) as YamlScalarNode; return scalar == null ? null : scalar.Value; }
    static void Add(List<Endpoint> rows, string host, string port, string protocol) {
      int number;
      if (String.IsNullOrEmpty(host) || !Int32.TryParse(port, NumberStyles.None, CultureInfo.InvariantCulture, out number) || number < 1 || number > 65535) return;
      rows.Add(new Endpoint { host = host, port = number, protocol = protocol });
    }
    static void Record(List<Endpoint> rows, YamlMappingNode map) {
      if (map == null) return;
      string protocol = Value(map, "type") ?? Value(map, "protocol");
      Add(rows, Value(map, "server"), Value(map, "port") ?? Value(map, "server_port"), protocol);
      var settings = Field(map, "settings") as YamlMappingNode;
      foreach (string name in new[] { "vnext", "servers" }) {
        var servers = Field(settings, name) as YamlSequenceNode;
        if (servers == null) continue;
        foreach (var item in servers.Children) {
          var server = item as YamlMappingNode;
          if (server != null) Add(rows, Value(server, "address"), Value(server, "port"), protocol);
        }
      }
    }
    static YamlMappingNode Selected(string text, int index) {
      Validate(text);
      var stream = new YamlStream(); using (var input = new StringReader(text)) stream.Load(input);
      if (stream.Documents.Count != 1 || index < 0) throw new InvalidDataException("Invalid profile selection");
      var root = stream.Documents[0].RootNode; var map = root as YamlMappingNode;
      var list = map == null ? root as YamlSequenceNode : Field(map, "proxies") as YamlSequenceNode;
      if (list == null || index >= list.Children.Count) throw new InvalidDataException("Mihomo export with a proxies list required; profile_index is its zero-based index");
      var selected = list.Children[index] as YamlMappingNode;
      if (selected == null) throw new InvalidDataException("Selected profile is not a mapping");
      string type = Value(selected, "type");
      if (!new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "vless", "vmess", "trojan", "ss", "ssr", "hysteria", "hysteria2", "tuic", "wireguard", "socks5", "http", "anytls" }.Contains(type ?? "")) throw new InvalidDataException("Selected profile needs a supported proxy protocol");
      if (!String.IsNullOrEmpty(Value(selected, "dialer-proxy"))) throw new InvalidDataException("Chained profiles need a complete isolated chain; this test did not activate one");
      return selected;
    }
    public static Endpoint MihomoEndpoint(string text, int index) {
      var selected = Selected(text, index); var rows = new List<Endpoint>(); Record(rows, selected);
      if (rows.Count != 1) throw new InvalidDataException("Selected profile needs one explicit server and port");
      return rows[0];
    }
    static void Keys(YamlMappingNode map, HashSet<string> keys, HashSet<YamlMappingNode> visiting, Budget budget) {
      if (--budget.left < 0 || !visiting.Add(map)) throw new InvalidDataException("YAML merge limit or cycle");
      try {
        foreach (var entry in map.Children) {
          string key = ((YamlScalarNode)entry.Key).Value;
          if (key != "<<") { keys.Add(key); continue; }
          var parent = entry.Value as YamlMappingNode;
          if (parent != null) { Keys(parent, keys, visiting, budget); continue; }
          var list = entry.Value as YamlSequenceNode;
          if (list == null) throw new InvalidDataException("Invalid YAML merge");
          foreach (var item in list.Children) { parent = item as YamlMappingNode; if (parent == null) throw new InvalidDataException("Invalid YAML merge"); Keys(parent, keys, visiting, budget); }
        }
      } finally { visiting.Remove(map); }
    }
    static YamlNode Copy(YamlNode node, HashSet<YamlNode> visiting, int depth, Budget budget) {
      if (--budget.left < 0 || depth > 48 || !visiting.Add(node)) throw new InvalidDataException("Profile copy limit or cycle");
      try {
        var scalar = node as YamlScalarNode;
        if (scalar != null) return new YamlScalarNode(scalar.Value) { Style = scalar.Style };
        var list = node as YamlSequenceNode;
        if (list != null) { var result = new YamlSequenceNode(); foreach (var child in list.Children) result.Add(Copy(child, visiting, depth + 1, budget)); return result; }
        var map = node as YamlMappingNode;
        if (map == null) throw new InvalidDataException("Unsupported profile value");
        var copy = new YamlMappingNode(); var keys = new HashSet<string>(StringComparer.Ordinal);
        Keys(map, keys, new HashSet<YamlMappingNode>(new Identity()), new Budget());
        foreach (string key in keys) {
          var value = Field(map, key);
          if (key == "skip-cert-verify" && !String.Equals((value as YamlScalarNode ?? new YamlScalarNode("")).Value, "false", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Certificate verification disabled in profile; no test was started");
          copy.Add(key, Copy(value, visiting, depth + 1, budget));
        }
        return copy;
      } finally { visiting.Remove(node); }
    }
    sealed class NodeIdentity : IEqualityComparer<YamlNode> {
      public bool Equals(YamlNode x, YamlNode y) { return Object.ReferenceEquals(x, y); }
      public int GetHashCode(YamlNode x) { return RuntimeHelpers.GetHashCode(x); }
    }
    public static string MihomoConfig(string text, int index, int port, string adapter, string serverIp, string password) {
      try {
        var selected = Selected(text, index);
        var proxy = (YamlMappingNode)Copy(selected, new HashSet<YamlNode>(new NodeIdentity()), 0, new Budget());
        proxy.Children[new YamlScalarNode("name")] = new YamlScalarNode("helper-profile");
        proxy.Children.Remove(new YamlScalarNode("interface-name")); proxy.Children.Remove(new YamlScalarNode("routing-mark"));
        if (!String.IsNullOrEmpty(adapter)) proxy.Add("interface-name", adapter);
        if (!String.IsNullOrEmpty(serverIp)) {
          // TLS can be implicit (Trojan, Hysteria, TUIC, AnyTLS). Preserve its
          // original default SNI when pinning the transport to a real IP.
          string type = (Value(selected, "type") ?? "").ToLowerInvariant();
          string sniKey = type == "vless" || type == "vmess" ? "servername" : "sni";
          if (String.IsNullOrEmpty(Value(selected, sniKey))) proxy.Children[new YamlScalarNode(sniKey)] = new YamlScalarNode(Value(selected, "server"));
          proxy.Children[new YamlScalarNode("server")] = new YamlScalarNode(serverIp);
        }
        var root = new YamlMappingNode {
          { "mixed-port", port.ToString(CultureInfo.InvariantCulture) }, { "bind-address", "127.0.0.1" },
          { "allow-lan", "false" }, { "ipv6", "false" }, { "mode", "rule" }, { "log-level", "silent" },
          { "find-process-mode", "off" }, { "authentication", new YamlSequenceNode("helper-probe:" + password) },
          { "tun", new YamlMappingNode { { "enable", "false" } } }, { "dns", new YamlMappingNode { { "enable", "false" } } },
          { "profile", new YamlMappingNode { { "store-selected", "false" }, { "store-fake-ip", "false" } } },
          { "proxies", new YamlSequenceNode(proxy) }, { "rules", new YamlSequenceNode("MATCH,helper-profile") }
        };
        if (!String.IsNullOrEmpty(adapter)) root.Add("interface-name", adapter);
        var output = new YamlStream(new YamlDocument(root)); using (var writer = new StringWriter(CultureInfo.InvariantCulture)) { output.Save(writer, false); return writer.ToString(); }
      } catch (InvalidDataException) { throw; }
      catch { throw new InvalidDataException("Could not build isolated profile; input values omitted"); }
    }
    public static Endpoint[] Yaml(string text) {
      try {
        if (text == null || text.Length > 4 * 1024 * 1024) throw new InvalidDataException("YAML size limit");
        Validate(text);
        var stream = new YamlStream(); using (var reader = new StringReader(text)) stream.Load(reader);
        if (stream.Documents.Count != 1) throw new InvalidDataException("One YAML document required");
        var root = stream.Documents[0].RootNode; var rows = new List<Endpoint>();
        var map = root as YamlMappingNode;
        var sequence = root as YamlSequenceNode;
        if (map != null) {
          sequence = (Field(map, "proxies") ?? Field(map, "outbounds")) as YamlSequenceNode;
          if (sequence == null) Record(rows, map);
        }
        if (sequence != null) {
          var clock = Stopwatch.StartNew();
          foreach (var item in sequence.Children) {
            if (clock.ElapsedMilliseconds > 2000) throw new InvalidDataException("YAML extraction limit");
            Record(rows, item as YamlMappingNode);
          }
        }
        return rows.ToArray();
      } catch { throw new InvalidDataException("Invalid YAML export or parsing limit exceeded; input values omitted"); }
    }
  }
}
