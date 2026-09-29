using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;

namespace InhousePhotos {
  /// Publishes only a private IP hint. The phone still connects to the public
  /// HTTPS hostname and validates its normal certificate before sending data.
  public static class LanRoute {
    static string lastAddress;
    static DateTime nextRefreshUtc=DateTime.MinValue;
    public const string RoutePath="/descargas/lan.json";

    static bool PrivateIpv4(IPAddress ip) {
      if(ip.AddressFamily!=AddressFamily.InterNetwork)return false;
      var b=ip.GetAddressBytes();
      return b[0]==10||(b[0]==172&&b[1]>=16&&b[1]<=31)||(b[0]==192&&b[1]==168);
    }
    public static string LocalAddress() {
      return NetworkInterface.GetAllNetworkInterfaces()
        .Where(n=>n.OperationalStatus==OperationalStatus.Up&&
          (n.NetworkInterfaceType==NetworkInterfaceType.Ethernet||n.NetworkInterfaceType==NetworkInterfaceType.Wireless80211))
        .SelectMany(n=>{
          var props=n.GetIPProperties();
          return props.GatewayAddresses.Any(g=>g.Address.AddressFamily==AddressFamily.InterNetwork)
            ? props.UnicastAddresses.Select(u=>u.Address) : Enumerable.Empty<IPAddress>();
        })
        .Where(PrivateIpv4).Select(ip=>ip.ToString()).FirstOrDefault();
    }
    public static async Task Publish(Preferences prefs) {
      if(prefs==null||String.IsNullOrWhiteSpace(prefs.Installation)||String.IsNullOrWhiteSpace(prefs.Endpoint))return;
      Uri origin;if(!Uri.TryCreate(prefs.Endpoint,UriKind.Absolute,out origin)||origin.Scheme!="https"||origin.Port!=443)return;
      var caddyfile=Path.Combine(prefs.Installation,"Caddyfile");
      if(!File.Exists(caddyfile))return;
      var caddyText=File.ReadAllText(caddyfile);
      if(!caddyText.Contains(RoutePath)&&!caddyText.Contains("handle_path /descargas/*"))return;
      var address=LocalAddress();
      if(String.IsNullOrEmpty(address))return;
      if(address==lastAddress&&DateTime.UtcNow<nextRefreshUtc)return;
      var container=(await Backend.Compose(prefs,"ps -q caddy",15)).Trim();
      if(String.IsNullOrWhiteSpace(container))return;
      Backend.PrivateDirectory(Backend.SettingsDir);
      var hint=Path.Combine(Backend.SettingsDir,"lan-route.json");
      var body=Backend.Json.Serialize(new{origin=origin.GetLeftPart(UriPartial.Authority),ipv4=address,port=443});
      File.WriteAllText(hint,body,new UTF8Encoding(false));
      await Backend.Run(Backend.DockerExe(),"cp "+Backend.Quote(hint)+" "+Backend.Quote(container+":/data/inhouse-downloads/lan.json"),prefs.Installation,30);
      lastAddress=address;nextRefreshUtc=DateTime.UtcNow.AddMinutes(10);
    }
  }
}
