using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Management;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace InhousePhotos {
  /// User-invoked only. Protects the PC's normal Internet route before
  /// phone tethering is used as a direct, authenticated photo transport.
  /// Never disable an adapter or change its gateway, DHCP, DNS or firewall.
  public static class UsbNetworkSafety {
    internal const int CableMetric=5000;
    public const string HelperArgument="--prepare-usb-network";
    public const string DiagnosticFileName="usb-network-setup.txt";

    internal sealed class AdapterProof {
      public int Index;
      public Guid Id;
      public string PnpDeviceId,Description;
      public bool Connected,Physical,HasPrivateIpv4,Prepared;
      public NetworkInterfaceType Type;
      public string[] Gateways=new string[0];
    }
    internal sealed class RouteProof {
      public int Index,Family;
      public string Destination,NextHop;
      public long EffectiveMetric,RouteMetric;
    }
    internal sealed class Snapshot {
      public AdapterProof[] Adapters;
      public RouteProof[] Routes;
    }
    internal sealed class Plan {
      public AdapterProof Phone,Internet;
    }
    internal sealed class PreparationStatus {
      public bool CanPrepare,Prepared;
      public int Code;
    }
    sealed class GuardFailure:InvalidOperationException {
      public readonly int Code;
      public GuardFailure(int code):base(MessageFor(code)){Code=code;}
    }

    public static async Task PrepareWithConsent() {
      // Preflight is read-only and does not display UAC when there is no
      // usable cable or no separate PC Internet connection to preserve.
      await Task.Run(()=>SelectPlan(ReadSnapshot()));
      var executable=typeof(UsbNetworkSafety).Assembly.Location;
      if(String.IsNullOrWhiteSpace(executable)||!File.Exists(executable))throw new GuardFailure(16);
      try {
        using(var child=Process.Start(new ProcessStartInfo(executable,HelperArgument){
          UseShellExecute=true,Verb="runas",WindowStyle=ProcessWindowStyle.Hidden,
          WorkingDirectory=Environment.SystemDirectory})) {
          if(child==null)throw new GuardFailure(16);
          // The helper is finite and owns its own timeout. Do not kill it
          // midway through a network-setting operation from the UI process.
          await Task.Run(()=>child.WaitForExit());
          if(child.ExitCode!=0)throw new GuardFailure(child.ExitCode);
        }
      } catch(Win32Exception error) {
        if(error.NativeErrorCode==1223)throw new InvalidOperationException("Se ha cancelado el permiso de Windows. No se ha cambiado la configuración de red.");
        throw new InvalidOperationException("Windows no ha podido abrir la preparación del cable. No se ha cambiado la configuración de red.");
      }
    }

    /// Called only by the fixed helper CLI, never by startup/supervision.
    public static int RunElevated() {
      var index=0;
      RouteProof[] before=null;
      try {
        using(var identity=WindowsIdentity.GetCurrent())
          if(!new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))throw new GuardFailure(10);
        var plan=SelectPlan(ReadSnapshot());index=plan.Phone.Index;
        // Hot-unplug/replug can recycle an interface index. Bind the operation
        // to the GUID and hardware fingerprint, not an alias/name from input.
        var fresh=SelectPlan(ReadSnapshot());
        if(!SameAdapter(plan.Phone,fresh.Phone)||!SameAdapter(plan.Internet,fresh.Internet))throw new GuardFailure(14);
        var beforeSnapshot=ReadSnapshot();var beforePlan=SelectPlan(beforeSnapshot);
        if(!SameAdapter(fresh.Phone,beforePlan.Phone)||!SameAdapter(fresh.Internet,beforePlan.Internet))throw new GuardFailure(14);
        before=DefaultRoutes(beforeSnapshot,index);
        SaveDefaultReceipt(fresh.Phone,before);
        var powershell=Path.Combine(Environment.SystemDirectory,@"WindowsPowerShell\v1.0\powershell.exe");
        if(!File.Exists(powershell))throw new GuardFailure(16);
        var encoded=Convert.ToBase64String(Encoding.Unicode.GetBytes(Command(fresh)));
        var start=new ProcessStartInfo(powershell,"-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand "+encoded){
          UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden,
          WorkingDirectory=Environment.SystemDirectory,RedirectStandardOutput=true,RedirectStandardError=true};
        int result;
        using(var process=Process.Start(start)) {
          if(process==null)throw new GuardFailure(16);
          // Drain output to prevent a blocked pipe, but never persist command
          // output, adapter serial numbers, IPs, credentials or error bodies.
          var output=process.StandardOutput.ReadToEndAsync();
          var errors=process.StandardError.ReadToEndAsync();
          if(!process.WaitForExit(45000)) {
            // A hung network provider is not proof that no setting changed.
            // Stop only this helper's shell and report an unverified result.
            try{process.Kill();}catch{}
            WriteDiagnostic(22,index,"timeout",before,null);return 22;
          } else result=process.ExitCode;
          Task.WhenAll(output,errors).GetAwaiter().GetResult();
        }
        if(result!=0){WriteDiagnostic(result,index,"provider",before,null);return result;}
        // Re-check hardware and the protected LAN after the provider returns.
        var afterSnapshot=ReadSnapshot();var after=SelectPlan(afterSnapshot);
        if(!SameAdapter(fresh.Phone,after.Phone)||!SameAdapter(fresh.Internet,after.Internet))throw new GuardFailure(14);
        var defaultsAfter=DefaultRoutes(afterSnapshot,index);
        if(defaultsAfter.Length!=0)throw new GuardFailure(21);
        WriteDiagnostic(0,index,"verified",before,defaultsAfter);return 0;
      } catch(GuardFailure error) {WriteDiagnostic(error.Code,index,"guard",before,null);return error.Code;}
      catch {WriteDiagnostic(20,index,"unverified",before,null);return 20;}
    }

    static bool SameAdapter(AdapterProof first,AdapterProof second) {
      return first!=null&&second!=null&&first.Index==second.Index&&first.Id==second.Id&&
        String.Equals(first.PnpDeviceId,second.PnpDeviceId,StringComparison.OrdinalIgnoreCase)&&
        String.Equals(first.Description,second.Description,StringComparison.OrdinalIgnoreCase);
    }
    static bool Phone(AdapterProof adapter) {
      return adapter!=null&&adapter.Index>0&&adapter.Id!=Guid.Empty&&adapter.Connected&&adapter.HasPrivateIpv4&&
        LanRoute.IsPhoneUsbTether(adapter.PnpDeviceId,adapter.Description);
    }
    static bool InternetLan(AdapterProof adapter) {
      return adapter!=null&&adapter.Index>0&&adapter.Id!=Guid.Empty&&adapter.Connected&&adapter.Physical&&adapter.HasPrivateIpv4&&
        !String.IsNullOrWhiteSpace(adapter.PnpDeviceId)&&!adapter.PnpDeviceId.StartsWith("USB\\",StringComparison.OrdinalIgnoreCase)&&
        (adapter.Type==NetworkInterfaceType.Ethernet||adapter.Type==NetworkInterfaceType.Wireless80211)&&
        !Regex.IsMatch(adapter.Description??"",@"\b(virtual|hyper-v|vpn|tunnel|tap|tun)\b",RegexOptions.IgnoreCase);
    }
    internal static Plan SelectPlan(Snapshot snapshot) {
      if(snapshot==null||snapshot.Adapters==null||snapshot.Routes==null)throw new GuardFailure(20);
      var phones=snapshot.Adapters.Where(Phone).ToArray();
      if(phones.Length==0)throw new GuardFailure(11);
      if(phones.Length!=1)throw new GuardFailure(12);
      var phone=phones[0];
      // A split default is not a phone connected-prefix route. Never attempt
      // to infer or modify a broader, unexpected tether routing policy.
      if(snapshot.Routes.Any(route=>route.Index==phone.Index&&
        route.Family==2&&(route.Destination=="0.0.0.0/1"||route.Destination=="128.0.0.0/1")))throw new GuardFailure(15);
      var internet=(from adapter in snapshot.Adapters where InternetLan(adapter)
        from route in snapshot.Routes where route.Index==adapter.Index&&route.Family==2&&route.Destination=="0.0.0.0/0"&&
          route.EffectiveMetric>=0&&route.EffectiveMetric<CableMetric&&
          adapter.Gateways.Contains(route.NextHop,StringComparer.OrdinalIgnoreCase)
        orderby route.EffectiveMetric select adapter).FirstOrDefault();
      if(internet==null||internet.Index==phone.Index)throw new GuardFailure(13);
      return new Plan{Phone=phone,Internet=internet};
    }

    /// Background-only, read-only assessment. Merely connecting a phone or
    /// opening a status page must never change Windows' network settings.
    internal static PreparationStatus AssessPreparation() {
      try {
        var snapshot=ReadSnapshot();var plan=SelectPlan(snapshot);
        return new PreparationStatus{CanPrepare=true,
          Prepared=plan.Phone.Prepared&&DefaultRoutes(snapshot,plan.Phone.Index).Length==0};
      } catch(GuardFailure failure) {return new PreparationStatus{Code=failure.Code};}
      catch {return new PreparationStatus{Code=20};}
    }

    static Snapshot ReadSnapshot() {
      var hardware=new Dictionary<Guid,AdapterProof>();
      using(var query=new ManagementObjectSearcher("root\\CIMV2","SELECT GUID, InterfaceIndex, Name, PNPDeviceID, PhysicalAdapter FROM Win32_NetworkAdapter")) {
        query.Options.Timeout=TimeSpan.FromSeconds(3);
        using(var results=query.Get())foreach(ManagementObject item in results)using(item) {
          Guid id;if(!Guid.TryParse(item["GUID"] as string,out id)||id==Guid.Empty||item["InterfaceIndex"]==null)continue;
          var index=Convert.ToInt64(item["InterfaceIndex"],CultureInfo.InvariantCulture);
          if(index<1||index>Int32.MaxValue)continue;
          hardware[id]=new AdapterProof{Id=id,Index=(int)index,PnpDeviceId=item["PNPDeviceID"] as string,
            Description=item["Name"] as string,Physical=item["PhysicalAdapter"] is bool&&(bool)item["PhysicalAdapter"]};
        }
      }
      var adapters=new List<AdapterProof>();
      foreach(var network in NetworkInterface.GetAllNetworkInterfaces()) {
        Guid id;AdapterProof proof;
        if(network.OperationalStatus!=OperationalStatus.Up||!Guid.TryParse(network.Id,out id)||!hardware.TryGetValue(id,out proof))continue;
        try {
          var properties=network.GetIPProperties();
          if(properties.GetIPv4Properties().Index!=proof.Index)continue;
          proof.Type=network.NetworkInterfaceType;proof.Connected=true;
          proof.HasPrivateIpv4=properties.UnicastAddresses.Any(address=>LanRoute.PrivateIpv4(address.Address));
          proof.Gateways=properties.GatewayAddresses.Where(gateway=>gateway.Address.AddressFamily==AddressFamily.InterNetwork&&
            !gateway.Address.Equals(IPAddress.Any)).Select(gateway=>gateway.Address.ToString()).ToArray();
          adapters.Add(proof);
        } catch(NetworkInformationException) { /* Hot-unplugged adapter: not a verified target. */ }
      }
      var metrics=new Dictionary<int,long>();
      var prepared=new Dictionary<int,bool>();
      using(var query=new ManagementObjectSearcher("root\\StandardCimv2","SELECT InterfaceIndex, AddressFamily, InterfaceMetric, IgnoreDefaultRoutes FROM MSFT_NetIPInterface WHERE CompartmentId = 1")) {
        query.Options.Timeout=TimeSpan.FromSeconds(3);
        using(var results=query.Get())foreach(ManagementObject item in results)using(item) {
          var index=Convert.ToInt32(item["InterfaceIndex"],CultureInfo.InvariantCulture);
          var family=Convert.ToInt32(item["AddressFamily"],CultureInfo.InvariantCulture);
          if(family!=2&&family!=23)continue;
          var metric=Convert.ToInt64(item["InterfaceMetric"],CultureInfo.InvariantCulture);
          if(family==2)metrics[index]=metric;
          var safe=item["IgnoreDefaultRoutes"]!=null&&Convert.ToInt32(item["IgnoreDefaultRoutes"],CultureInfo.InvariantCulture)==1&&metric>=CableMetric;
          bool previous;prepared[index]=!prepared.TryGetValue(index,out previous)?safe:previous&&safe;
        }
      }
      foreach(var adapter in adapters){bool safe;adapter.Prepared=prepared.TryGetValue(adapter.Index,out safe)&&safe;}
      var routes=new List<RouteProof>();
      using(var query=new ManagementObjectSearcher("root\\StandardCimv2","SELECT InterfaceIndex, AddressFamily, DestinationPrefix, NextHop, RouteMetric FROM MSFT_NetRoute WHERE CompartmentId = 1")) {
        query.Options.Timeout=TimeSpan.FromSeconds(3);
        using(var results=query.Get())foreach(ManagementObject item in results)using(item) {
          var index=Convert.ToInt32(item["InterfaceIndex"],CultureInfo.InvariantCulture);
          long metric;var family=Convert.ToInt32(item["AddressFamily"],CultureInfo.InvariantCulture);
          routes.Add(new RouteProof{Index=index,Family=family,Destination=item["DestinationPrefix"] as string,NextHop=item["NextHop"] as string,
            RouteMetric=Convert.ToInt64(item["RouteMetric"],CultureInfo.InvariantCulture),
            EffectiveMetric=family==2&&metrics.TryGetValue(index,out metric)?metric+Convert.ToInt64(item["RouteMetric"],CultureInfo.InvariantCulture):-1});
        }
      }
      return new Snapshot{Adapters=adapters.ToArray(),Routes=routes.ToArray()};
    }

    static string Numbers(IEnumerable<byte> values) {return String.Join(",",values.Select(value=>value.ToString(CultureInfo.InvariantCulture)));}
    static byte[] Fingerprint(AdapterProof adapter) {
      using(var sha=SHA256.Create())return sha.ComputeHash(Encoding.UTF8.GetBytes((adapter.PnpDeviceId??"").ToUpperInvariant()+"\n"+(adapter.Description??"").ToUpperInvariant()));
    }
    internal static string Command(Plan plan) {
      if(plan==null||!Phone(plan.Phone)||!InternetLan(plan.Internet)||plan.Phone.Index==plan.Internet.Index)throw new ArgumentException("Invalid USB preparation scope.");
      // Only validated positive integer indices and numeric identity bytes are
      // substituted. No filename, alias, PnP string, address or user text is
      // interpolated into an elevated command.
      var phoneIndex=plan.Phone.Index.ToString(CultureInfo.InvariantCulture);
      var lanIndex=plan.Internet.Index.ToString(CultureInfo.InvariantCulture);
      return "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; $changed=$false; try {"+
        "Import-Module (Join-Path $PSHOME 'Modules\\CimCmdlets\\CimCmdlets.psd1') -ErrorAction Stop; "+
        "Import-Module (Join-Path $PSHOME 'Modules\\NetTCPIP\\NetTCPIP.psd1') -ErrorAction Stop; "+
        "$u="+phoneIndex+"; $l="+lanIndex+"; "+
        "function Proof([int]$i,[int[]]$g,[int[]]$h,[bool]$usb) { "+
          "$a=@(CimCmdlets\\Get-CimInstance -ClassName Win32_NetworkAdapter -Filter ('InterfaceIndex='+$i)); "+
          "if($a.Count -ne 1 -or -not $a[0].NetEnabled){exit 14}; $a=$a[0]; "+
          "if((([Guid]$a.GUID).ToByteArray() -join ',') -ne ($g -join ',')){exit 14}; "+
          "$sha=[Security.Cryptography.SHA256]::Create(); try{$fp=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(([string]$a.PNPDeviceID).ToUpperInvariant()+\"`n\"+([string]$a.Name).ToUpperInvariant()))}finally{$sha.Dispose()}; "+
          "if(($fp -join ',') -ne ($h -join ',')){exit 14}; "+
          "if($usb){if(-not ([string]$a.PNPDeviceID).StartsWith('USB\\',[StringComparison]::OrdinalIgnoreCase)){exit 14}} "+
          "else {if(-not $a.PhysicalAdapter -or ([string]$a.PNPDeviceID).StartsWith('USB\\',[StringComparison]::OrdinalIgnoreCase)){exit 13}}; "+
          "return $a; }; "+
        "$null=Proof $u @("+Numbers(plan.Phone.Id.ToByteArray())+") @("+Numbers(Fingerprint(plan.Phone))+") $true; "+
        "$null=Proof $l @("+Numbers(plan.Internet.Id.ToByteArray())+") @("+Numbers(Fingerprint(plan.Internet))+") $false; "+
        "$lan=NetTCPIP\\Get-NetIPInterface -InterfaceIndex $l -AddressFamily IPv4 -PolicyStore ActiveStore; "+
        "if($lan.ConnectionState -ne 'Connected'){exit 13}; "+
        "$r=@(NetTCPIP\\Get-NetRoute -InterfaceIndex $l -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object {([long]$_.RouteMetric+[long]$lan.InterfaceMetric) -lt 5000 -and $_.NextHop -ne '0.0.0.0'}); "+
        "if($r.Count -eq 0){exit 13}; "+
        "$split=@(NetTCPIP\\Get-NetRoute -InterfaceIndex $u -AddressFamily IPv4 -PolicyStore ActiveStore | Where-Object {$_.DestinationPrefix -eq '0.0.0.0/1' -or $_.DestinationPrefix -eq '128.0.0.0/1'}); "+
        "if($split.Count -gt 0){exit 15}; "+
        // Unexpected manually persistent USB defaults could return at boot
        // despite blocking dynamic advertisements. Do not overwrite such a
        // custom policy or claim a durable result after removing only active
        // routes: fail before changing anything and request manual review.
        "foreach($family in @('IPv4','IPv6')) { $default=if($family -eq 'IPv4'){'0.0.0.0/0'}else{'::/0'}; "+
          "$persistent=@(NetTCPIP\\Get-NetRoute -InterfaceIndex $u -AddressFamily $family -DestinationPrefix $default -PolicyStore PersistentStore -ErrorAction SilentlyContinue); "+
          "if($persistent.Count -gt 0){exit 15}; }; "+
        // Microsoft documents omission of PolicyStore as writing active and
        // persistent settings. IgnoreDefaultRoutes blocks future dynamic
        // defaults; the high metric also deprioritises existing DHCP defaults.
        // https://learn.microsoft.com/powershell/module/nettcpip/set-netipinterface
        "foreach($family in @('IPv4','IPv6')) { "+
          "$available=@(NetTCPIP\\Get-NetIPInterface -InterfaceIndex $u -AddressFamily $family -PolicyStore ActiveStore -ErrorAction SilentlyContinue); "+
          "if($available.Count -eq 0){continue}; "+
          "$changed=$true; NetTCPIP\\Set-NetIPInterface -InterfaceIndex $u -AddressFamily $family -IgnoreDefaultRoutes Enabled -AutomaticMetric Disabled -InterfaceMetric 5000 -ErrorAction Stop; "+
          "foreach($store in @('ActiveStore','PersistentStore')) { $p=NetTCPIP\\Get-NetIPInterface -InterfaceIndex $u -AddressFamily $family -PolicyStore $store; "+
            "if($p.IgnoreDefaultRoutes -ne 'Enabled' -or $p.AutomaticMetric -ne 'Disabled' -or [long]$p.InterfaceMetric -ne 5000){exit 21}; }; "+
          // Metrics alone cannot stop a phone being the ONLY IPv6 default.
          // Remove exactly its active default, never its connected prefix or
          // the PC's protected physical-LAN default. Revalidate before removal.
          "$null=Proof $u @("+Numbers(plan.Phone.Id.ToByteArray())+") @("+Numbers(Fingerprint(plan.Phone))+") $true; "+
          "$default=if($family -eq 'IPv4'){'0.0.0.0/0'}else{'::/0'}; "+
          "$defaults=@(NetTCPIP\\Get-NetRoute -InterfaceIndex $u -AddressFamily $family -DestinationPrefix $default -PolicyStore ActiveStore -ErrorAction SilentlyContinue); "+
          "if($defaults.Count -gt 0){NetTCPIP\\Remove-NetRoute -InterfaceIndex $u -AddressFamily $family -DestinationPrefix $default -PolicyStore ActiveStore -Confirm:$false -ErrorAction Stop}; "+
          "$remaining=@(NetTCPIP\\Get-NetRoute -InterfaceIndex $u -AddressFamily $family -DestinationPrefix $default -PolicyStore ActiveStore -ErrorAction SilentlyContinue); "+
          "if($remaining.Count -gt 0){exit 21}; }; "+
        "$lanAfter=NetTCPIP\\Get-NetIPInterface -InterfaceIndex $l -AddressFamily IPv4 -PolicyStore ActiveStore; "+
        "if($lanAfter.ConnectionState -ne 'Connected' -or $lanAfter.InterfaceMetric -ne $lan.InterfaceMetric -or $lanAfter.AutomaticMetric -ne $lan.AutomaticMetric){exit 21}; "+
        "exit 0; } catch {if($changed){exit 21}else{exit 20}}";
    }

    static RouteProof[] DefaultRoutes(Snapshot snapshot,int index) {
      return snapshot.Routes.Where(route=>route.Index==index&&
        ((route.Family==2&&route.Destination=="0.0.0.0/0")||(route.Family==23&&route.Destination=="::/0"))).ToArray();
    }
    static void SaveDefaultReceipt(AdapterProof phone,RouteProof[] routes) {
      if(routes==null||routes.Length==0)return;
      var directory=Path.Combine(Backend.SettingsDir,"diagnostics");Backend.PrivateDirectory(directory);
      var path=Path.Combine(directory,"usb-defaults-before-"+phone.Id.ToString("N")+".json");Backend.RejectLinks(path);
      // Preserve the first pre-preparation receipt for this verified adapter.
      // It contains only its default routes, never other network settings.
      if(!File.Exists(path))File.WriteAllText(path,Backend.Json.Serialize(new{CapturedUtc=DateTime.UtcNow.ToString("o",CultureInfo.InvariantCulture),
        InterfaceIndex=phone.Index,Defaults=routes}),new UTF8Encoding(false));
    }
    static void WriteDiagnostic(int result,int index,string phase,RouteProof[] before,RouteProof[] after) {
      try {
        var directory=Path.Combine(Backend.SettingsDir,"diagnostics");Backend.PrivateDirectory(directory);
        var path=Path.Combine(directory,DiagnosticFileName);
        Backend.RejectLinks(path);
        File.WriteAllText(path,DateTime.UtcNow.ToString("o",CultureInfo.InvariantCulture)+"\ncode="+result.ToString(CultureInfo.InvariantCulture)+
          "\nphase="+phase+"\ninterfaceIndex="+index.ToString(CultureInfo.InvariantCulture)+"\n"+MessageFor(result)+
          "\nusbDefaultsBefore="+Backend.Json.Serialize(before)+"\nusbDefaultsAfter="+Backend.Json.Serialize(after),new UTF8Encoding(false));
      } catch { /* A diagnostic failure must not repeat a network mutation. */ }
    }
    public static string MessageFor(int code) {
      switch(code) {
        case 0:return "Cable preparado. El PC conserva su conexión habitual a Internet y el móvil puede transferir por la red USB.";
        case 10:return "Acepta el permiso de administrador de Windows para preparar el cable.";
        case 11:return "Conecta un móvil y activa su conexión de red USB. Un cable en modo carga o archivos no crea esta conexión.";
        case 12:return "Deja conectado un solo móvil por red USB y vuelve a intentarlo. No se ha cambiado la red.";
        case 13:return "Conecta primero el PC a su Ethernet o Wi-Fi habitual. No se usará la conexión a Internet del móvil.";
        case 14:return "La conexión USB o la conexión habitual del PC ha cambiado. Revisa el cable y vuelve a intentarlo.";
        case 15:return "Este móvil anuncia rutas a Internet distintas de las habituales. No se ha cambiado la red; revisa su configuración USB.";
        case 16:return "No se encuentra el componente de Windows para preparar el cable. No se ha cambiado la red.";
        case 21:return "No se ha podido verificar la configuración del cable. La conexión Ethernet o Wi-Fi del PC no se ha modificado. Revisa los diagnósticos antes de repetir.";
        case 22:return "Windows ha tardado demasiado al preparar el cable. Revisa los diagnósticos antes de repetir; no se puede confirmar el resultado.";
        default:return "No se ha podido confirmar la preparación del cable. Revisa los diagnósticos; no se ha modificado la conexión Ethernet o Wi-Fi.";
      }
    }

    /// Pure scope/command tests: never inspect adapters, elevate or mutate.
    public static int SelfTest() {
      var phone=new AdapterProof{Index=29,Id=Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),Connected=true,HasPrivateIpv4=true,
        PnpDeviceId=@"USB\VID_18D1&PID_4EE3\test",Description="Remote NDIS based Internet Sharing Device",Type=NetworkInterfaceType.Ethernet};
      var lan=new AdapterProof{Index=3,Id=Guid.Parse("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"),Connected=true,Physical=true,HasPrivateIpv4=true,
        PnpDeviceId=@"PCI\VEN_10EC&DEV_8168",Description="Realtek PCIe GbE Family Controller",Type=NetworkInterfaceType.Ethernet,Gateways=new[]{"192.168.1.1"}};
      var route=new RouteProof{Index=3,Family=2,Destination="0.0.0.0/0",NextHop="192.168.1.1",EffectiveMetric=60};
      var snapshot=new Snapshot{Adapters=new[]{phone,lan},Routes=new[]{route}};
      var plan=SelectPlan(snapshot);
      if(plan.Phone!=phone||plan.Internet!=lan)throw new InvalidOperationException("USB scope test failed.");
      var command=Command(plan);
      var setters=Regex.Matches(command,@"NetTCPIP\\Set-NetIPInterface\s+-InterfaceIndex\s+\$u\s+-AddressFamily\s+\$family\s+-IgnoreDefaultRoutes\s+Enabled\s+-AutomaticMetric\s+Disabled\s+-InterfaceMetric\s+5000");
      var removers=Regex.Matches(command,@"NetTCPIP\\Remove-NetRoute\s+-InterfaceIndex\s+\$u\s+-AddressFamily\s+\$family\s+-DestinationPrefix\s+\$default\s+-PolicyStore\s+ActiveStore\s+-Confirm:\$false");
      if(setters.Count!=1||command.Contains(phone.PnpDeviceId)||command.Contains(phone.Description)||command.Contains(lan.PnpDeviceId)||
        removers.Count!=1||command.Contains("Set-NetRoute")||command.Contains("Set-Dns")||command.Contains("Disable-NetAdapter")||
        command.Contains("Restart-NetAdapter")||!command.Contains("PersistentStore")||!command.Contains("$u=29; $l=3;"))throw new InvalidOperationException("USB command safety test failed.");
      if(!command.Contains("foreach($family in @('IPv4','IPv6'))")||!command.Contains("'0.0.0.0/0'}else{'::/0'}"))throw new InvalidOperationException("USB default-family scope test failed.");
      AssertRejected(new Snapshot{Adapters=new[]{lan},Routes=new[]{route}},11);
      AssertRejected(new Snapshot{Adapters=new[]{phone,phone,lan},Routes=new[]{route}},12);
      AssertRejected(new Snapshot{Adapters=new[]{phone,lan},Routes=new RouteProof[0]},13);
      SelectPlan(new Snapshot{Adapters=new[]{phone,lan},Routes=new[]{route,new RouteProof{Index=29,Family=23,Destination="::/0"}}});
      AssertRejected(new Snapshot{Adapters=new[]{phone,lan},Routes=new[]{route,new RouteProof{Index=29,Family=2,Destination="0.0.0.0/1"}}},15);
      route.EffectiveMetric=CableMetric;AssertRejected(snapshot,13);route.EffectiveMetric=60;
      phone.Connected=false;AssertRejected(snapshot,11);phone.Connected=true;
      phone.Index=0;AssertRejected(snapshot,11);phone.Index=29;
      lan.PnpDeviceId=@"USB\VID_0BDA&PID_8153";AssertRejected(snapshot,13);lan.PnpDeviceId=@"PCI\VEN_10EC&DEV_8168";
      phone.PnpDeviceId=@"USB\VID_0BDA&PID_8153";phone.Description="Realtek USB GbE Family Controller";AssertRejected(snapshot,11);
      return 0;
    }
    static void AssertRejected(Snapshot snapshot,int code) {
      try{SelectPlan(snapshot);}catch(GuardFailure failure){if(failure.Code==code)return;throw;}
      throw new InvalidOperationException("Unsafe USB scope was accepted.");
    }
  }
}
