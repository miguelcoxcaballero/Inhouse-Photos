using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Management;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace InhousePhotos {
  /// Publishes private socket hints only. Every route still uses the public
  /// HTTPS origin, hostname verification and the user's existing account.
  public static class LanRoute {
    static string lastDocument;
    static DateTime nextRefreshUtc=DateTime.MinValue;
    static readonly SemaphoreSlim publicationGate=new SemaphoreSlim(1,1);
    public const string RoutePath="/descargas/lan.json";
    internal const int MaximumRoutes=8;

    internal sealed class Adapter {
      public string Id,Description,PnpDeviceId;
      public string[] Addresses=new string[0];
      public NetworkInterfaceType Type;
      public bool Up,Physical,HasGateway;
      public long Speed;
    }
    internal sealed class Candidate {
      public string ipv4,kind;
      public int port=443;
      // Negotiated first-hop speed is diagnostic, not measured upload speed.
      public int linkMbps;
    }
    sealed class Hardware {
      public string Description,PnpDeviceId;
      public bool Physical;
    }

    internal static bool PrivateIpv4(IPAddress ip) {
      if(ip==null||ip.AddressFamily!=AddressFamily.InterNetwork)return false;
      var b=ip.GetAddressBytes();
      return b[0]==10||(b[0]==172&&b[1]>=16&&b[1]<=31)||(b[0]==192&&b[1]==168);
    }
    internal static bool IsPhoneUsbTether(string pnpDeviceId,string description) {
      // An attached/charging phone is not an upload transport. Require an
      // actual USB network device. Do not label ordinary USB Ethernet dongles
      // as a phone cable just because their device identifier starts with USB.
      if(String.IsNullOrWhiteSpace(pnpDeviceId)||!pnpDeviceId.StartsWith("USB\\",StringComparison.OrdinalIgnoreCase))return false;
      var text=description??"";
      if(Regex.IsMatch(text,@"\b(remote\s+ndis|rndis)\b",RegexOptions.IgnoreCase))return true;
      var knownPhoneVendor=Regex.IsMatch(pnpDeviceId,@"\\VID_(18D1|04E8|22B8|2717|2A70|12D1|2D95|22D9|05AC)(&|\\)",RegexOptions.IgnoreCase);
      return knownPhoneVendor&&Regex.IsMatch(text,@"\b(ncm|apple\s+mobile\s+device)\b",RegexOptions.IgnoreCase);
    }
    internal static Candidate[] Candidates(IEnumerable<Adapter> adapters) {
      return (adapters??Enumerable.Empty<Adapter>()).Where(a=>a!=null&&a.Up)
        .SelectMany(a=>{
          var usb=IsPhoneUsbTether(a.PnpDeviceId,a.Description);
          var lan=a.Physical&&a.HasGateway&&
            (a.Type==NetworkInterfaceType.Ethernet||a.Type==NetworkInterfaceType.Wireless80211)&&
            !Regex.IsMatch(a.Description??"",@"\b(virtual|hyper-v|vpn|tunnel|tap|tun)\b",RegexOptions.IgnoreCase);
          if(!usb&&!lan)return Enumerable.Empty<Candidate>();
          return (a.Addresses??new string[0]).Select(address=>{
            IPAddress ip;if(!IPAddress.TryParse(address,out ip)||!PrivateIpv4(ip))return null;
            return new Candidate{ipv4=ip.ToString(),kind=usb?"usb":"lan",linkMbps=(int)Math.Min(1000000L,Math.Max(0L,a.Speed/1000000L))};
          }).Where(c=>c!=null);
        }).OrderBy(c=>c.kind=="usb"?0:1).ThenByDescending(c=>c.linkMbps).ThenBy(c=>c.ipv4,StringComparer.Ordinal)
        .GroupBy(c=>c.ipv4,StringComparer.Ordinal).Select(group=>group.First()).Take(MaximumRoutes).ToArray();
    }
    internal static string Document(string endpoint,IEnumerable<Adapter> adapters) {
      Uri origin;
      if(!Uri.TryCreate(endpoint,UriKind.Absolute,out origin)||origin.Scheme!="https"||origin.Port!=443||
         String.IsNullOrEmpty(origin.Host)||!String.IsNullOrEmpty(origin.UserInfo)||
         origin.AbsolutePath!="/"||!String.IsNullOrEmpty(origin.Query)||!String.IsNullOrEmpty(origin.Fragment))return null;
      var routes=Candidates(adapters);
      // Older clients continue to prefer the normal LAN. New clients can try
      // verified USB routes first. Publish an empty document on disconnect so
      // a removed adapter never remains advertised for the refresh interval.
      var legacy=routes.FirstOrDefault(c=>c.kind=="lan")??routes.FirstOrDefault();
      return Backend.Json.Serialize(new{origin=origin.GetLeftPart(UriPartial.Authority),ipv4=legacy==null?null:legacy.ipv4,port=443,routes=routes});
    }
    static string AdapterKey(string id) {
      Guid parsed;return Guid.TryParse(id,out parsed)?parsed.ToString("D"):id??"";
    }
    internal static Adapter[] ReadAdapters() {
      var hardware=new Dictionary<string,Hardware>(StringComparer.OrdinalIgnoreCase);
      try {
        using(var query=new ManagementObjectSearcher("root\\CIMV2","SELECT GUID, Name, PNPDeviceID, PhysicalAdapter FROM Win32_NetworkAdapter")) {
          query.Options.Timeout=TimeSpan.FromSeconds(2);
          using(var results=query.Get())foreach(ManagementObject item in results)using(item) {
            var id=AdapterKey(item["GUID"] as string);
            if(String.IsNullOrEmpty(id))continue;
            hardware[id]=new Hardware{Description=item["Name"] as string,PnpDeviceId=item["PNPDeviceID"] as string,
              Physical=item["PhysicalAdapter"] is bool&&(bool)item["PhysicalAdapter"]};
          }
        }
      } catch { /* Without hardware proof retain public HTTPS rather than guess. */ }
      var adapters=new List<Adapter>();
      foreach(var network in NetworkInterface.GetAllNetworkInterfaces()) {
        if(network.OperationalStatus!=OperationalStatus.Up)continue;
        Hardware proof;if(!hardware.TryGetValue(AdapterKey(network.Id),out proof))continue;
        try {
          var properties=network.GetIPProperties();
          adapters.Add(new Adapter{Id=network.Id,Description=(proof.Description??"")+" "+network.Description,
            PnpDeviceId=proof.PnpDeviceId,Physical=proof.Physical,Up=true,Type=network.NetworkInterfaceType,
            Speed=network.Speed,HasGateway=properties.GatewayAddresses.Any(g=>g.Address.AddressFamily==AddressFamily.InterNetwork&&!g.Address.Equals(IPAddress.Any)),
            Addresses=properties.UnicastAddresses.Select(u=>u.Address.ToString()).ToArray()});
        } catch(NetworkInformationException) { /* Hot-unplugged adapter. */ }
      }
      return adapters.ToArray();
    }
    public static string LocalAddress() {
      var candidates=Candidates(ReadAdapters());
      var preferred=candidates.FirstOrDefault(c=>c.kind=="lan")??candidates.FirstOrDefault();
      return preferred==null?null:preferred.ipv4;
    }
    public static async Task Publish(Preferences prefs) {
      if(prefs==null||String.IsNullOrWhiteSpace(prefs.Installation)||String.IsNullOrWhiteSpace(prefs.Endpoint))return;
      var snapshot=Backend.Json.Deserialize<Preferences>(Backend.Json.Serialize(prefs));
      await publicationGate.WaitAsync();
      try {
        // Supervision and network-change notifications may arrive together.
        // Take fresh adapter evidence inside the serialized publication, then
        // copy one complete document; never let two writes race the same file.
        var body=await Task.Run(()=>Document(snapshot.Endpoint,ReadAdapters()));
        if(body==null)return;
        var caddyfile=Path.Combine(snapshot.Installation,"Caddyfile");
        if(!File.Exists(caddyfile))return;
        var caddyText=File.ReadAllText(caddyfile);
        var existingDownloads=caddyText.Contains("handle_path /descargas/*");
        if(!caddyText.Contains(RoutePath)&&!existingDownloads)return;
        if(body==lastDocument&&DateTime.UtcNow<nextRefreshUtc)return;
        var container=(await Backend.Compose(snapshot,"ps -q caddy",15)).Trim();
        if(String.IsNullOrWhiteSpace(container))return;
        Backend.PrivateDirectory(Backend.SettingsDir);
        var hint=Path.Combine(Backend.SettingsDir,"lan-route.json");
        File.WriteAllText(hint,body,new UTF8Encoding(false));
        var target=existingDownloads?"/data/inhouse-downloads/lan.json":"/data/inhouse-lan.json";
        await Backend.Run(Backend.DockerExe(),"cp "+Backend.Quote(hint)+" "+Backend.Quote(container+":"+target),snapshot.Installation,30);
        lastDocument=body;nextRefreshUtc=DateTime.UtcNow.AddMinutes(10);
      } finally {publicationGate.Release();}
    }
  }
}
