using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.Linq;
using System.Management;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace InhousePhotos {
  /// Privacy-safe status only. Never serialize device instance IDs, serial
  /// numbers, user-assigned phone names, USB paths or network addresses.
  public sealed class UsbDeviceStatus {
    public string State {get;internal set;}
    public string Title {get;internal set;}
    public string Message {get;internal set;}
    public string Action {get;internal set;}
    public bool Connected {get;internal set;}
    public int PhoneCount {get;internal set;}
    public string Platform {get;internal set;}
    public string DeviceName {get;internal set;}
    public bool NetworkReady {get;internal set;}
    public bool NeedsPreparation {get;internal set;}
    public bool CanPrepare {get;internal set;}
    public int LinkMbps {get;internal set;}
    public string CheckedUtc {get;internal set;}
    // Calculate freshness on the server. A phone/browser clock may be hours
    // ahead or behind; it must not decide whether this hardware scan is stale.
    public int AgeSeconds {
      get {
        DateTime checkedAt;
        if(!DateTime.TryParse(CheckedUtc,CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind,out checkedAt))return Int32.MaxValue;
        return (int)Math.Min(Int32.MaxValue,Math.Max(0,(DateTime.UtcNow-checkedAt.ToUniversalTime()).TotalSeconds));
      }
    }
  }

  /// Physical cable detection is separate from transfer readiness. A phone
  /// in MTP/charging mode must appear in the UI even though it is not a USB
  /// network. All OS inspection runs on one background worker; rendering and
  /// HTTP requests only read an immutable cached snapshot.
  public sealed class UsbDeviceMonitor : IDisposable {
    static readonly Lazy<UsbDeviceMonitor> instance=new Lazy<UsbDeviceMonitor>(()=>new UsbDeviceMonitor());
    public static UsbDeviceMonitor Current {get{return instance.Value;}}
    readonly object gate=new object();
    UsbDeviceStatus snapshot=Status("checking","Comprobando el cable","Buscando un móvil conectado al PC…",null,DateTime.UtcNow);
    Timer poll,debounce;
    ManagementEventWatcher watcher;
    NetworkAddressChangedEventHandler networkChanged;
    bool started,disposed,scanning,refreshAgain;
    public event EventHandler Changed;
    public UsbDeviceStatus Snapshot {get{lock(gate)return snapshot;}}

    internal sealed class DeviceProof {
      public string Id,RootId,Name,Class,CompatibleIds;
      public bool Present;
      public int Problem;
    }
    internal sealed class PhoneProof {
      public string RootId,Platform;
      public bool Accessible,DriverProblem;
      public DeviceProof[] Devices;
    }

    public void Start() {
      lock(gate) {
        if(started||disposed)return;started=true;
        debounce=new Timer(ignored=>RunScan(),null,Timeout.Infinite,Timeout.Infinite);
        // A fallback also covers a disabled WMI notification provider. Device
        // notifications normally update the UI in under a second.
        poll=new Timer(ignored=>Refresh(),null,0,5000);
        networkChanged=(sender,args)=>Refresh();
        NetworkChange.NetworkAddressChanged+=networkChanged;
      }
      _=Task.Run(()=>StartDeviceNotifications());
    }
    public void Refresh() {
      lock(gate) {
        if(disposed||!started)return;
        if(scanning){refreshAgain=true;return;}
        debounce.Change(450,Timeout.Infinite);
      }
    }
    void StartDeviceNotifications() {
      ManagementEventWatcher candidate=null;
      try {
        candidate=new ManagementEventWatcher("root\\CIMV2","SELECT * FROM Win32_DeviceChangeEvent WHERE EventType = 2 OR EventType = 3");
        candidate.EventArrived+=(sender,args)=>Refresh();candidate.Start();
        lock(gate) {
          if(disposed){candidate.Stop();candidate.Dispose();return;}
          watcher=candidate;
        }
      } catch {if(candidate!=null)try{candidate.Dispose();}catch{} /* Polling remains available. */}
    }
    void RunScan() {
      lock(gate) {
        if(disposed||scanning)return;scanning=true;
      }
      _=Task.Run(()=>{
        UsbDeviceStatus next;
        try {
          var devices=ReadPresentDevices();
          var adapters=LanRoute.ReadAdapters();
          var hasNetwork=LanRoute.Candidates(adapters).Any(route=>route.kind=="usb");
          // Network policy queries are unnecessary when only an MTP/locked
          // phone is present, and never run in the UI or API thread.
          var preparation=hasNetwork?UsbNetworkSafety.AssessPreparation():new UsbNetworkSafety.PreparationStatus();
          next=Describe(devices,adapters,preparation,DateTime.UtcNow);
        } catch {
          next=Status("detection_unavailable","No se pudo comprobar el cable",
            "Windows no ha respondido a la detección de dispositivos. Tu servidor y su conexión habitual siguen funcionando.",
            "Volver a comprobar",DateTime.UtcNow);
        }
        bool changed;
        lock(gate) {
          scanning=false;if(disposed)return;
          changed=!SameStatus(snapshot,next);snapshot=next;
          if(refreshAgain){refreshAgain=false;debounce.Change(450,Timeout.Infinite);}
        }
        if(changed) {
          var handler=Changed;if(handler!=null)try{handler(this,EventArgs.Empty);}catch{ /* Subscribers cannot stop detection. */ }
        }
      });
    }
    static bool SameStatus(UsbDeviceStatus first,UsbDeviceStatus second) {
      return first!=null&&second!=null&&first.State==second.State&&first.Title==second.Title&&first.Message==second.Message&&
        first.Action==second.Action&&first.Connected==second.Connected&&first.PhoneCount==second.PhoneCount&&
        first.Platform==second.Platform&&first.DeviceName==second.DeviceName&&first.NetworkReady==second.NetworkReady&&
        first.NeedsPreparation==second.NeedsPreparation&&first.CanPrepare==second.CanPrepare&&first.LinkMbps==second.LinkMbps;
    }
    public void Dispose() {
      ManagementEventWatcher deviceWatcher;
      lock(gate) {
        if(disposed)return;disposed=true;
        if(networkChanged!=null)NetworkChange.NetworkAddressChanged-=networkChanged;
        if(poll!=null)poll.Dispose();if(debounce!=null)debounce.Dispose();deviceWatcher=watcher;watcher=null;
      }
      if(deviceWatcher!=null){try{deviceWatcher.Stop();}catch{}deviceWatcher.Dispose();}
    }

    static UsbDeviceStatus Status(string state,string title,string message,string action,DateTime checkedAt) {
      return new UsbDeviceStatus{State=state,Title=title,Message=message,Action=action,
        Platform="unknown",DeviceName="Móvil",CheckedUtc=checkedAt.ToUniversalTime().ToString("o",CultureInfo.InvariantCulture)};
    }
    static bool UsbRoot(string id) {
      return !String.IsNullOrWhiteSpace(id)&&Regex.IsMatch(id,@"^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}(?:\\|&[^\\]*)",RegexOptions.IgnoreCase)&&
        !Regex.IsMatch(id,@"&MI_[0-9A-F]{2}",RegexOptions.IgnoreCase);
    }
    static bool KnownAndroidVendor(string id) {
      return Regex.IsMatch(id??"",@"^USB\\VID_(18D1|04E8|22B8|2717|2A70|12D1|2D95|22D9|0BB4|1004|0FCE|2B4C|19D2)(&|\\)",RegexOptions.IgnoreCase);
    }
    static bool PhoneProduct(string id) {
      // A generic composite node can be the only evidence while a phone is
      // locked. Restrict that inference to known handset product ranges;
      // vendor alone would mistake keyboards, controllers and hubs for phones.
      return Regex.IsMatch(id??"",@"^USB\\(?:VID_18D1&PID_(?:4EE[0-9A-F]|2D0[0-5])|VID_04E8&PID_686[0-9A-F]|VID_2717&PID_FF[0-9A-F]{2}|VID_05AC&PID_12[0-9A-F]{2})(?:&|\\)",RegexOptions.IgnoreCase);
    }
    static bool PhoneFunction(DeviceProof proof) {
      var name=proof.Name??"";var type=proof.Class??"";var compatible=proof.CompatibleIds??"";
      if(Regex.IsMatch(type,@"^(HIDClass|Keyboard|Mouse|Printer|USBSTOR|DiskDrive)$",RegexOptions.IgnoreCase))return false;
      return Regex.IsMatch(name,@"\b(android|iphone|ipad|ipod|smartphone|mtp|apple\s+mobile\s+device|mobile\s+phone|remote\s+ndis|rndis|ncm)\b",RegexOptions.IgnoreCase)||
        Regex.IsMatch(type,@"^(WPD|AndroidUsbDevice|AndroidDevice|PortableDevice)$",RegexOptions.IgnoreCase)||
        Regex.IsMatch(compatible,@"USB\\(?:CLASS_FF&SUBCLASS_42&PROT_01|MS_COMP_MTP)",RegexOptions.IgnoreCase);
    }
    internal static PhoneProof[] FindPhones(IEnumerable<DeviceProof> evidence) {
      var devices=(evidence??Enumerable.Empty<DeviceProof>()).Where(device=>device!=null&&device.Present&&!String.IsNullOrWhiteSpace(device.Id)).ToArray();
      var roots=devices.Where(device=>UsbRoot(device.Id)).ToDictionary(device=>device.Id,StringComparer.OrdinalIgnoreCase);
      var phones=new List<PhoneProof>();
      foreach(var root in roots.Values) {
        var members=devices.Where(device=>String.Equals(device.Id,root.Id,StringComparison.OrdinalIgnoreCase)||
          String.Equals(device.RootId,root.Id,StringComparison.OrdinalIgnoreCase)).ToArray();
        var apple=Regex.IsMatch(root.Id,@"^USB\\VID_05AC&",RegexOptions.IgnoreCase);
        var functions=members.Where(PhoneFunction).ToArray();
        // Apple's non-phone devices use the same vendor identifier. They must
        // not be labeled an iPhone just because they are plugged into USB.
        var identified=apple?(PhoneProduct(root.Id)||functions.Any(device=>Regex.IsMatch(device.Name??"",@"\b(iphone|ipad|ipod|apple\s+mobile\s+device)\b",RegexOptions.IgnoreCase))):
          (KnownAndroidVendor(root.Id)&&(PhoneProduct(root.Id)||functions.Length!=0));
        if(!identified)continue;
        var accessible=functions.Any(device=>device.Problem==0&&
          (Regex.IsMatch(device.Class??"",@"^(WPD|AndroidUsbDevice|AndroidDevice|PortableDevice|Net)$",RegexOptions.IgnoreCase)||
           Regex.IsMatch(device.Name??"",@"\b(mtp|android|apple\s+mobile\s+device|remote\s+ndis|rndis|ncm)\b",RegexOptions.IgnoreCase)));
        // Any phone data interface with an actual PnP error deserves a visible
        // diagnosis; unrelated sibling HID interfaces are not data drivers.
        phones.Add(new PhoneProof{RootId=root.Id,Platform=apple?"ios":"android",Accessible=accessible,
          DriverProblem=root.Problem!=0||functions.Any(device=>device.Problem!=0),Devices=members});
      }
      return phones.ToArray();
    }
    internal static UsbDeviceStatus Describe(IEnumerable<DeviceProof> devices,IEnumerable<LanRoute.Adapter> adapters,
      UsbNetworkSafety.PreparationStatus preparation,DateTime checkedAt) {
      var phones=FindPhones(devices);
      if(phones.Length==0) {
        // Fail closed: a network description alone is not physical proof of a
        // present handset. A historical MTP node must not keep USB connected.
        return Status("no_device","No hay un móvil conectado por USB",
          "Conecta un móvil desbloqueado con un cable de datos. Si sólo carga, Windows no puede detectar sus fotos ni crear una conexión por cable.",
          "Volver a comprobar",checkedAt);
      }
      var status=Status("connected_needs_unlock","Móvil conectado por USB","",null,checkedAt);
      status.Connected=true;status.PhoneCount=phones.Length;status.Platform=phones.Length==1?phones[0].Platform:"unknown";
      status.DeviceName=status.Platform=="ios"?"iPhone o iPad":status.Platform=="android"?"Android":"Móviles";
      if(phones.Length>1) {
        status.State="multiple_devices";status.Title="Varios móviles conectados";
        status.Message="Deja conectado sólo el móvil que quieres usar. Así no se preparará el cable de otro dispositivo.";
        status.Action="Volver a comprobar";return status;
      }
      var phone=phones[0];
      // Match the actual network device to this present phone's PnP tree;
      // a disconnected/other phone's network cannot make this one 'ready'.
      var phoneAdapters=(adapters??Enumerable.Empty<LanRoute.Adapter>()).Where(adapter=>adapter!=null&&adapter.Up&&
        LanRoute.IsPhoneUsbTether(adapter.PnpDeviceId,adapter.Description)&&phone.Devices.Any(device=>
          String.Equals(device.Id,adapter.PnpDeviceId,StringComparison.OrdinalIgnoreCase))).ToArray();
      var phoneRoutes=LanRoute.Candidates(phoneAdapters).Where(route=>route.kind=="usb").ToArray();
      if(phoneRoutes.Length!=0) {
        status.LinkMbps=phoneRoutes.Max(route=>route.linkMbps);
        status.CanPrepare=preparation!=null&&preparation.CanPrepare;
        status.NeedsPreparation=preparation==null||!preparation.Prepared;
        if(!status.NeedsPreparation) {
          status.State="ready";status.Title="Conexión USB preparada";status.NetworkReady=true;
          status.Message="Windows detecta la red del móvil por cable. Mantén abierta Inhouse Photos en el móvil; el icono de cable confirma cuándo la app está transfiriendo por USB.";
          status.Action="Volver a comprobar";
        } else {
          status.State="network_unprepared";status.Title="Cable detectado · falta preparar la conexión";
          status.Message=status.CanPrepare?
            "La red USB ya está disponible. Prepararla conserva Internet por el Ethernet o Wi-Fi del PC; Windows pedirá permiso una sola vez.":
            (preparation!=null&&preparation.Code==13?
              "Conecta primero el PC a su Ethernet o Wi-Fi habitual. No se usará Internet ni los datos móviles del teléfono.":
              "Windows ve la red USB, pero no puede confirmar que sea seguro prepararla. No se ha cambiado la red del PC. Vuelve a comprobar el cable.");
          status.Action=status.CanPrepare?"Preparar conexión USB":"Volver a comprobar";
        }
        return status;
      }
      if(phone.DriverProblem) {
        status.State="driver_issue";status.Title="Móvil detectado · Windows necesita un controlador";
        status.Message=status.Platform=="ios"?
          "Desbloquea el iPhone y pulsa Confiar. Si sigue igual, instala o actualiza Dispositivos Apple desde Microsoft Store; después vuelve a conectar el cable.":
          "Desbloquea el móvil y acepta el permiso USB. Si sigue igual, revisa el dispositivo en Windows Update o Administrador de dispositivos; no se instalarán controladores desconocidos.";
        status.Action="Volver a comprobar";return status;
      }
      if(phone.Accessible) {
        status.State="connected_needs_network";status.Title="Móvil conectado · falta activar la red USB";
        status.Message=status.Platform=="ios"?
          "El cable está detectado. Activa Punto de acceso personal en el iPhone y acepta Confiar si se solicita. Windows no puede activar esa opción por ti.":
          "El cable está detectado. En la notificación USB del móvil, activa Compartir conexión USB. El modo Transferir archivos no es una red para subir desde la app.";
        status.Action="Volver a comprobar";return status;
      }
      status.Title="Móvil detectado · desbloquéalo";
      status.Message=status.Platform=="ios"?
        "Desbloquea el iPhone y acepta Confiar en este ordenador. Después activa Punto de acceso personal para usar la red USB.":
        "Desbloquea el móvil y acepta el permiso de datos USB. Después activa Compartir conexión USB; cargar el móvil no basta para transferir desde la app.";
      status.Action="Volver a comprobar";return status;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct DeviceInfo {public uint Size;public Guid ClassGuid;public uint DevInst;public IntPtr Reserved;}
    [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern IntPtr SetupDiGetClassDevs(IntPtr classGuid,string enumerator,IntPtr parent,uint flags);
    [DllImport("setupapi.dll",SetLastError=true)]
    static extern bool SetupDiEnumDeviceInfo(IntPtr devices,uint index,ref DeviceInfo info);
    [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern bool SetupDiGetDeviceInstanceId(IntPtr devices,ref DeviceInfo info,StringBuilder text,uint length,out uint required);
    [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern bool SetupDiGetDeviceRegistryProperty(IntPtr devices,ref DeviceInfo info,uint property,out uint type,byte[] bytes,uint length,out uint required);
    [DllImport("setupapi.dll",SetLastError=true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr devices);
    [DllImport("cfgmgr32.dll")]
    static extern uint CM_Get_Parent(out uint parent,uint child,uint flags);
    [DllImport("cfgmgr32.dll",CharSet=CharSet.Unicode)]
    static extern uint CM_Get_Device_ID(uint node,StringBuilder text,uint length,uint flags);
    [DllImport("cfgmgr32.dll")]
    static extern uint CM_Get_DevNode_Status(out uint status,out uint problem,uint node,uint flags);
    static string Property(IntPtr devices,ref DeviceInfo info,uint key) {
      uint type,required;var bytes=new byte[8192];
      if(!SetupDiGetDeviceRegistryProperty(devices,ref info,key,out type,bytes,(uint)bytes.Length,out required)||required>bytes.Length)return "";
      if(type!=1&&type!=7)return ""; // REG_SZ / REG_MULTI_SZ only.
      return Encoding.Unicode.GetString(bytes,0,(int)required).TrimEnd('\0').Replace('\0',' ');
    }
    static string RootId(uint node,string ownId) {
      if(UsbRoot(ownId))return ownId;
      for(var depth=0;depth<12;depth++) {
        uint parent;if(CM_Get_Parent(out parent,node,0)!=0)break;node=parent;
        var text=new StringBuilder(1024);if(CM_Get_Device_ID(node,text,(uint)text.Capacity,0)!=0)break;
        if(UsbRoot(text.ToString()))return text.ToString();
      }
      return null;
    }
    internal static DeviceProof[] ReadPresentDevices() {
      // DIGCF_PRESENT is critical: ordinary WMI/registry enumeration includes
      // old unplugged phones. SetupAPI owns the present-only device set.
      var handle=SetupDiGetClassDevs(IntPtr.Zero,null,IntPtr.Zero,0x02|0x04);
      if(handle==new IntPtr(-1))throw new Win32Exception(Marshal.GetLastWin32Error());
      try {
        var devices=new List<DeviceProof>();
        for(uint index=0;index<4096;index++) {
          var info=new DeviceInfo{Size=(uint)Marshal.SizeOf(typeof(DeviceInfo))};
          if(!SetupDiEnumDeviceInfo(handle,index,ref info)) {
            if(Marshal.GetLastWin32Error()==259)break;throw new Win32Exception(Marshal.GetLastWin32Error());
          }
          uint required;var id=new StringBuilder(1024);
          if(!SetupDiGetDeviceInstanceId(handle,ref info,id,(uint)id.Capacity,out required))continue;
          var deviceId=id.ToString();
          if(!deviceId.StartsWith("USB\\",StringComparison.OrdinalIgnoreCase)&&
             !deviceId.StartsWith("SWD\\WPDBUSENUM\\",StringComparison.OrdinalIgnoreCase))continue;
          var type=Property(handle,ref info,7);var name=Property(handle,ref info,12);
          if(String.IsNullOrWhiteSpace(name))name=Property(handle,ref info,0);
          uint status,problem;var problemCode=CM_Get_DevNode_Status(out status,out problem,info.DevInst,0)==0?(int)problem:0;
          devices.Add(new DeviceProof{Id=deviceId,RootId=RootId(info.DevInst,deviceId),Name=name,Class=type,
            CompatibleIds=Property(handle,ref info,2),Problem=problemCode,Present=true});
        }
        return devices.ToArray();
      } finally {SetupDiDestroyDeviceInfoList(handle);}
    }

    /// Fixture-only coverage. Never enumerates hardware or modifies networks.
    public static int SelfTest() {
      var at=new DateTime(2026,10,3,12,0,0,DateTimeKind.Utc);
      var root=new DeviceProof{Id=@"USB\VID_18D1&PID_4EE1\private-serial",Name="USB Composite Device",Class="USB",Present=true};
      var mtp=new DeviceProof{Id=@"SWD\WPDBUSENUM\private-mtp",RootId=root.Id,Name="My private phone name",Class="WPD",Present=true};
      var tether=new DeviceProof{Id=@"USB\VID_18D1&PID_4EE1&MI_00\private-network",RootId=root.Id,
        Name="Remote NDIS based Internet Sharing Device",Class="Net",Present=true};
      var none=new LanRoute.Adapter[0];var unprepared=new UsbNetworkSafety.PreparationStatus{CanPrepare=true};
      Assert(Describe(new DeviceProof[0],none,unprepared,at).State=="no_device","empty USB");
      Assert(Describe(new[]{root},none,unprepared,at).State=="connected_needs_unlock","locked phone");
      Assert(Describe(new[]{root,mtp},none,unprepared,at).State=="connected_needs_network","MTP detected without tether");
      var adapter=new LanRoute.Adapter{Up=true,PnpDeviceId=tether.Id,Description=tether.Name,
        Addresses=new[]{"192.168.42.2"},Speed=480000000,Type=NetworkInterfaceType.Ethernet};
      var waiting=Describe(new[]{root,mtp,tether},new[]{adapter},unprepared,at);
      Assert(waiting.State=="network_unprepared"&&waiting.CanPrepare&&waiting.NeedsPreparation&&!waiting.NetworkReady,"USB safety pending");
      var ready=Describe(new[]{root,mtp,tether},new[]{adapter},new UsbNetworkSafety.PreparationStatus{CanPrepare=true,Prepared=true},at);
      Assert(ready.State=="ready"&&ready.NetworkReady&&ready.LinkMbps==480&&!ready.NeedsPreparation,"prepared USB");
      var wrongAdapter=new LanRoute.Adapter{Up=true,PnpDeviceId=@"USB\VID_18D1&PID_4EE3\another-phone",Description=tether.Name,
        Addresses=new[]{"192.168.42.2"},Speed=480000000,Type=NetworkInterfaceType.Ethernet};
      Assert(!Describe(new[]{root,mtp},new[]{wrongAdapter},new UsbNetworkSafety.PreparationStatus{Prepared=true},at).NetworkReady,"other phone network");
      root.Present=false;mtp.Present=false;tether.Present=false;
      Assert(Describe(new[]{root,mtp,tether},new[]{adapter},unprepared,at).State=="no_device","historical devices excluded");
      root.Present=true;mtp.Present=true;tether.Present=true;
      mtp.Problem=28;Assert(Describe(new[]{root,mtp},none,unprepared,at).State=="driver_issue","driver missing");mtp.Problem=0;
      var apple=new DeviceProof{Id=@"USB\VID_05AC&PID_12A8\private-iphone",Name="Apple iPhone",Class="USB",Present=true};
      var iphone=Describe(new[]{apple},none,unprepared,at);
      Assert(iphone.Connected&&iphone.Platform=="ios"&&iphone.State=="connected_needs_unlock","locked iPhone");
      var appleDriver=new DeviceProof{Id=@"USB\VID_05AC&PID_12A8&MI_00\private-iphone",RootId=apple.Id,
        Name="Apple Mobile Device USB Driver",Class="USBDevice",Present=true};
      Assert(Describe(new[]{apple,appleDriver},none,unprepared,at).State=="connected_needs_network","iPhone driver");
      var keyboard=new DeviceProof{Id=@"USB\VID_05AC&PID_024F\keyboard",Name="Apple Keyboard",Class="HIDClass",Present=true};
      var dongle=new DeviceProof{Id=@"USB\VID_0BDA&PID_8153\ethernet",Name="Realtek USB GbE",Class="Net",Present=true};
      var controller=new DeviceProof{Id=@"USB\VID_18D1&PID_9400\controller",Name="Stadia Controller",Class="HIDClass",Present=true};
      Assert(FindPhones(new[]{keyboard,dongle,controller}).Length==0,"non-phone USB devices");
      var ncmRoot=new DeviceProof{Id=@"USB\VID_2A70&PID_F003\private-ncm",Name="USB Composite Device",Class="USB",Present=true};
      var ncm=new DeviceProof{Id=@"USB\VID_2A70&PID_F003&MI_00\private-ncm-network",RootId=ncmRoot.Id,Name="USB NCM",Class="Net",Present=true};
      Assert(FindPhones(new[]{ncmRoot,ncm}).Single().Accessible,"known phone vendor NCM function");
      Assert(Describe(new[]{root,mtp,apple},none,unprepared,at).State=="multiple_devices","ambiguous phones");
      var orphan=new DeviceProof{Id=@"SWD\WPDBUSENUM\unplugged",RootId=@"USB\VID_18D1&PID_4EE1\absent",Class="WPD",Present=true};
      Assert(FindPhones(new[]{orphan}).Length==0,"WPD requires present physical ancestor");
      var serialized=Backend.Json.Serialize(ready);
      Assert(!serialized.Contains("private-")&&!serialized.Contains("192.168")&&!serialized.Contains("VID_")&&!serialized.Contains("My private"),"status privacy");
      var stale=Status("checking","","",null,DateTime.UtcNow.AddMinutes(-2));
      Assert(stale.AgeSeconds>=119&&stale.AgeSeconds<=121,"server-computed freshness");
      stale.CheckedUtc="not-a-date";Assert(stale.AgeSeconds==Int32.MaxValue,"invalid scan time fails closed");
      return 0;
    }
    static void Assert(bool condition,string name) {if(!condition)throw new InvalidOperationException("USB detection fixture failed: "+name);}
  }
}
