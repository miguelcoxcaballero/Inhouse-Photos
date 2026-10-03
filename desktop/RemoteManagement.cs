using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace InhousePhotos {
  public sealed class RemoteDiskStatus {
    public string Root {get;set;}
    public string Name {get;set;}
    public long Total {get;set;}
    public long Free {get;set;}
    public bool IsLibrary {get;set;}
    public bool IsBackup {get;set;}
    public bool CanUseForBackup {get;set;}
  }
  public sealed class RemoteManagerStatus {
    public string Version {get;set;}
    public bool ServerOnline {get;set;}
    public bool Busy {get;set;}
    public string Operation {get;set;}
    public string Progress {get;set;}
    public string Error {get;set;}
    public string LibraryDrive {get;set;}
    public string BackupDestination {get;set;}
    public bool BackupConfigured {get;set;}
    public bool BackupRunning {get;set;}
    public bool BackupPresent {get;set;}
    public string BackupCompletedUtc {get;set;}
    public bool WeeklyBackupEnabled {get;set;}
    public string NextBackupUtc {get;set;}
    public bool StartupEnabled {get;set;}
    public bool StartupKnown {get;set;}
    public RemoteDiskStatus[] Disks {get;set;}
    public UsbDeviceStatus Usb {get;set;}
    public RuntimeUpdateStatus RuntimeUpdate {get;set;}
  }
  /// A tiny, fixed-purpose bridge for an administrator's phone. Only the
  /// Windows manager restarts after an update; the photo API stays in Docker.
  /// Caddy injects a private bridge key and the manager independently checks
  /// the phone's bearer token with the existing server before every request.
  public sealed class RemoteManagement : IDisposable {
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
    static void NoInherit(Socket socket) {
      if(!SetHandleInformation(socket.Handle,1,0))throw new IOException("No se pudo proteger el puerto local de gestión.");
    }
    public const int Port=52187;
    public const string Path="/inhouse-manager/v1/update";
    public const string StatusPath="/inhouse-manager/v1/status";
    public const string UsbPath="/inhouse-manager/v1/usb";
    public const string RuntimePath="/inhouse-manager/v1/runtime-update";
    const string BeginMarker="# INHOUSE-MANAGER-ROUTE-BEGIN";
    const string EndMarker="# INHOUSE-MANAGER-ROUTE-END";
    readonly Preferences prefs;
    readonly Func<bool> canUpdate;
    readonly Action requestUpdate;
    readonly Func<Task<RemoteManagerStatus>> readStatus;
    readonly Func<string,Task<bool>> performAction;
    readonly string secret;
    readonly TcpListener listener;
    readonly SemaphoreSlim capacity=new SemaphoreSlim(4,4);
    string publishedContainer,publishedConfigurationHash;
    bool disposed;
    readonly object authorizationGate=new object();
    readonly Dictionary<string,DateTime> recentAdministrators=new Dictionary<string,DateTime>();
    static string SecretPath {get{return System.IO.Path.Combine(Backend.SettingsDir,"manager-bridge.dpapi");}}

    public RemoteManagement(Preferences prefs,Func<bool> canUpdate,Action requestUpdate,
      Func<Task<RemoteManagerStatus>> readStatus,Func<string,Task<bool>> performAction) {
      this.prefs=prefs;this.canUpdate=canUpdate;this.requestUpdate=requestUpdate;
      this.readStatus=readStatus;this.performAction=performAction;
      secret=LoadOrCreateSecret();
      listener=new TcpListener(IPAddress.Any,Port);listener.Start(8);
      try{NoInherit(listener.Server);}catch{listener.Stop();throw;}
      _=AcceptLoop();
    }
    static string LoadOrCreateSecret() {
      Backend.PrivateDirectory(Backend.SettingsDir);
      if(File.Exists(SecretPath)) {
        var saved=Encoding.ASCII.GetString(ProtectedData.Unprotect(File.ReadAllBytes(SecretPath),null,DataProtectionScope.CurrentUser));
        if(!Regex.IsMatch(saved,"^[a-f0-9]{64}$"))throw new IOException("La clave local del gestor está dañada.");
        return saved;
      }
      var value=Backend.RandomHex(32);
      var temp=SecretPath+"."+Guid.NewGuid().ToString("N")+".new";
      try{File.WriteAllBytes(temp,ProtectedData.Protect(Encoding.ASCII.GetBytes(value),null,DataProtectionScope.CurrentUser));File.Move(temp,SecretPath);}
      finally{if(File.Exists(temp))File.Delete(temp);}
      return value;
    }
    static bool SameSecret(string a,string b) {
      if(a==null||b==null||a.Length!=b.Length)return false;
      var result=0;for(var i=0;i<a.Length;i++)result|=a[i]^b[i];return result==0;
    }
    async Task AcceptLoop() {
      while(!disposed) {
        TcpClient client=null;
        try{client=await listener.AcceptTcpClientAsync();NoInherit(client.Client);await capacity.WaitAsync();
          _=Task.Run(async()=>{
            try {
              var request=Serve(client);
              if(await Task.WhenAny(request,Task.Delay(30000))!=request)client.Dispose();
              try{await request;}catch{}
            } finally {client.Dispose();capacity.Release();}
          });
        }catch(ObjectDisposedException){break;}
        catch(SocketException){if(disposed)break;client?.Dispose();}
        catch{client?.Dispose();}
      }
    }
    static async Task Reply(NetworkStream stream,int status,object data) {
      var reason=status==200?"OK":status==202?"Accepted":status==400?"Bad Request":status==401?"Unauthorized":
        status==403?"Forbidden":status==404?"Not Found":status==409?"Conflict":"Service Unavailable";
      var body=Encoding.UTF8.GetBytes(Backend.Json.Serialize(data));
      var head=Encoding.ASCII.GetBytes("HTTP/1.1 "+status+" "+reason+"\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Length: "+body.Length+"\r\nConnection: close\r\n\r\n");
      await stream.WriteAsync(head,0,head.Length);await stream.WriteAsync(body,0,body.Length);await stream.FlushAsync();
    }
    static string ReadLineBounded(StreamReader reader,int limit) {
      var line=new StringBuilder();int value;
      while((value=reader.Read())>=0) {
        if(value=='\n')return line.ToString().TrimEnd('\r');
        if(line.Length>=limit)throw new IOException("Management request line too long");
        line.Append((char)value);
      }
      return null;
    }
    internal static string ReadOnlyBrowserToken(string method,string path,string cookie) {
      // Only read-only diagnostics accept the existing web session. All
      // mutating routes still require an explicit bearer token, preventing
      // a browser's ambient cookies from authorising cross-site actions.
      if(method!="GET"||(path!=StatusPath&&path!=UsbPath)||String.IsNullOrEmpty(cookie)||cookie.Length>2048)return null;
      string found=null;
      foreach(var part in cookie.Split(';')) {
        var pair=part.Trim();var separator=pair.IndexOf('=');
        if(separator<1||pair.Substring(0,separator)!="immich_access_token")continue;
        var value=pair.Substring(separator+1);
        if(found!=null||!Regex.IsMatch(value,"^[A-Za-z0-9._~-]{20,1024}$"))return null;
        found=value;
      }
      return found;
    }
    enum AdministratorAuthorization {Denied,Verified,Unavailable}
    async Task<AdministratorAuthorization> IsAdmin(string token) {
      if(String.IsNullOrWhiteSpace(token)||token.Length>2048)return AdministratorAuthorization.Denied;
      Uri uri;if(!Uri.TryCreate(prefs.LocalEndpoint,UriKind.Absolute,out uri)||!uri.IsLoopback||uri.AbsolutePath!="/")return AdministratorAuthorization.Denied;
      try {
        var request=(HttpWebRequest)WebRequest.Create(uri.GetLeftPart(UriPartial.Authority)+"/api/users/me");
        request.Method="GET";request.AllowAutoRedirect=false;request.Proxy=null;request.Timeout=7000;request.ReadWriteTimeout=7000;
        request.Headers[HttpRequestHeader.Authorization]="Bearer "+token;
        using(var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(8)))using(deadline.Token.Register(()=>request.Abort()))
        using(var response=(HttpWebResponse)await request.GetResponseAsync()) {
          if(response.StatusCode!=HttpStatusCode.OK||response.ContentLength>16384)return AdministratorAuthorization.Denied;
          using(var reader=new StreamReader(response.GetResponseStream())) {
            var body=await reader.ReadToEndAsync();if(body.Length>16384)return AdministratorAuthorization.Denied;
            var data=Backend.Json.Deserialize<Dictionary<string,object>>(body);
            return data!=null&&data.ContainsKey("isAdmin")&&data["isAdmin"] is bool&&(bool)data["isAdmin"]?
              AdministratorAuthorization.Verified:AdministratorAuthorization.Denied;
          }
        }
      }catch(WebException ex){
        var response=ex.Response as HttpWebResponse;
        if(response!=null)using(response) {
          if((int)response.StatusCode>=400&&(int)response.StatusCode<500)return AdministratorAuthorization.Denied;
        }
        return AdministratorAuthorization.Unavailable;
      }catch(IOException){return AdministratorAuthorization.Unavailable;}
      catch{return AdministratorAuthorization.Denied;}
    }
    static string TokenHash(string token) {
      using(var sha=SHA256.Create())return Convert.ToBase64String(sha.ComputeHash(Encoding.UTF8.GetBytes(token)));
    }
    internal static bool MayReadProgress(string method,string path,bool applying,DateTime verifiedUtc,DateTime nowUtc) {
      return method=="GET"&&(path==RuntimePath||path==StatusPath)&&applying&&nowUtc>=verifiedUtc&&
        nowUtc-verifiedUtc<=TimeSpan.FromMinutes(5);
    }
    async Task<AdministratorAuthorization> Authorize(string token,string method,string path) {
      var result=await IsAdmin(token);
      var hash=String.IsNullOrWhiteSpace(token)?null:TokenHash(token);
      lock(authorizationGate) {
        if(!RuntimeUpdates.IsApplying)recentAdministrators.Clear();
        if(result==AdministratorAuthorization.Verified) {
          if(hash!=null) {
            foreach(var expired in recentAdministrators.Where(item=>DateTime.UtcNow-item.Value>TimeSpan.FromMinutes(5)).Select(item=>item.Key).ToArray())recentAdministrators.Remove(expired);
            if(recentAdministrators.Count>=16)recentAdministrators.Clear();
            recentAdministrators[hash]=DateTime.UtcNow;
          }
          return AdministratorAuthorization.Verified;
        }
        if(result==AdministratorAuthorization.Denied){if(hash!=null)recentAdministrators.Remove(hash);return result;}
        DateTime verified;
        return hash!=null&&recentAdministrators.TryGetValue(hash,out verified)&&
          MayReadProgress(method,path,RuntimeUpdates.IsApplying,verified,DateTime.UtcNow)?
          AdministratorAuthorization.Verified:AdministratorAuthorization.Unavailable;
      }
    }
    async Task Serve(TcpClient client) {
      client.ReceiveTimeout=10000;client.SendTimeout=10000;client.NoDelay=true;
      var stream=client.GetStream();
      try {
        using(var reader=new StreamReader(stream,Encoding.ASCII,false,4096,true)) {
          var first=ReadLineBounded(reader,512);
          if(first==null||first.Length>512){await Reply(stream,400,new{message="Invalid request"});return;}
          var parts=first.Split(' ');
          if(parts.Length!=3||!Allowed(parts[0],parts[1])||parts[2]!="HTTP/1.1"||
             (parts[0]!="GET"&&parts[0]!="POST")){await Reply(stream,404,new{message="Not found"});return;}
          var headers=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);var total=first.Length;
          for(var i=0;i<40;i++) {
            var line=ReadLineBounded(reader,2048);if(line==null){await Reply(stream,400,new{message="Invalid request"});return;}
            total+=line.Length;if(total>8192){await Reply(stream,400,new{message="Invalid request"});return;}
            if(line.Length==0)break;
            var colon=line.IndexOf(':');if(colon<=0){await Reply(stream,400,new{message="Invalid request"});return;}
            var name=line.Substring(0,colon);if(headers.ContainsKey(name)){await Reply(stream,400,new{message="Invalid request"});return;}
            headers[name]=line.Substring(colon+1).Trim();
            if(i==39){await Reply(stream,400,new{message="Invalid request"});return;}
          }
          string key,authorization,length,cookie;
          headers.TryGetValue("X-Inhouse-Bridge",out key);
          if(!SameSecret(key,secret)){await Reply(stream,403,new{message="Forbidden"});return;}
          headers.TryGetValue("Content-Length",out length);
          if((length!=null&&length!="0")||headers.ContainsKey("Transfer-Encoding")){await Reply(stream,400,new{message="Body not allowed"});return;}
          headers.TryGetValue("Authorization",out authorization);
          headers.TryGetValue("Cookie",out cookie);
          var token=authorization!=null&&authorization.StartsWith("Bearer ",StringComparison.Ordinal)?authorization.Substring(7):
            authorization==null?ReadOnlyBrowserToken(parts[0],parts[1],cookie):null;
          var admin=await Authorize(token,parts[0],parts[1]);
          if(admin!=AdministratorAuthorization.Verified){
            await Reply(stream,admin==AdministratorAuthorization.Unavailable?503:401,new{message=admin==AdministratorAuthorization.Unavailable?
              "El motor de fotos no responde para verificar tu cuenta. Espera o comprueba el servidor en el PC.":"Administrator sign-in required"});return;
          }
          if(parts[1]==UsbPath) {
            await Reply(stream,200,UsbDeviceMonitor.Current.Snapshot);
            return;
          }
          if(parts[1]==StatusPath) {
            try{await Reply(stream,200,await readStatus());}
            catch{await Reply(stream,503,new{message="Could not read the Windows manager status."});}
            return;
          }
          if(parts[1]==Path&&parts[0]=="GET") {
            try{await ManagerUpdates.Check();await Reply(stream,200,ManagerUpdates.Status());}
            catch(Exception ex){await Reply(stream,503,new{message="Update check unavailable: "+ex.Message,currentVersion=Backend.Version});}
            return;
          }
          if(parts[1]==Path) {
            if(!canUpdate()){await Reply(stream,409,new{message="The PC is busy with a backup or another operation. Try again shortly."});return;}
            try {
              var status=await ManagerUpdates.Check(true);
              if(!status.Available){await Reply(stream,409,new{message="The Windows manager is already up to date."});return;}
              if(!ManagerUpdates.TryBegin()){await Reply(stream,409,new{message="The update is already in progress."});return;}
              requestUpdate();await Reply(stream,202,ManagerUpdates.Status());
            }catch(Exception ex){ManagerUpdates.Fail(ex);await Reply(stream,503,new{message=ex.Message});}
            return;
          }
          if(parts[1]==RuntimePath&&parts[0]=="GET") {
            try{await Reply(stream,200,await RuntimeUpdates.Check(prefs));}
            catch{await Reply(stream,503,new{message="No se pudo comprobar el motor instalado. Comprueba Docker en el PC."});}
            return;
          }
          if(parts[1]==RuntimePath) {
            try {
              if(!RuntimeUpdates.IsApplying)await RuntimeUpdates.Check(prefs,true);
              var accepted=await performAction("runtime-update");
              if(!accepted){await Reply(stream,409,new{message="El PC está ocupado o el motor ya está actualizado."});return;}
              await Reply(stream,202,RuntimeUpdates.Status());
            }catch{await Reply(stream,503,new{message="No se pudo iniciar la actualización del motor. Comprueba el gestor en el PC."});}
            return;
          }
          try {
            var accepted=await performAction(parts[1].Substring(StatusPath.Length+1));
            await Reply(stream,accepted?202:409,new{message=accepted?"Action accepted":"The PC is busy or the action is not available."});
          }catch(ArgumentException ex){await Reply(stream,400,new{message=ex.Message});}
          catch(InvalidOperationException ex){await Reply(stream,409,new{message=ex.Message});}
          catch{await Reply(stream,503,new{message="The Windows manager could not start this action."});}
        }
      }catch{ /* An interrupted management request must not affect the photo server. */ }
    }
    public static bool Allowed(string method,string path) {
      if(method=="GET")return path==Path||path==StatusPath||path==UsbPath||path==RuntimePath;
      if(method!="POST")return false;
      if(path==Path||path==RuntimePath)return true;
      if(path==StatusPath+"/backup/start"||path==StatusPath+"/backup/cancel"||
         path==StatusPath+"/backup/schedule/enable"||path==StatusPath+"/backup/schedule/disable"||
         path==StatusPath+"/startup/enable"||path==StatusPath+"/startup/disable"||
         path==StatusPath+"/snapshot")return true;
      return Regex.IsMatch(path??"","^"+StatusPath+"/backup/destination/[A-Z]$");
    }
    public static string WithRoute(string source,string secret) {
      if(String.IsNullOrEmpty(source)||!Regex.IsMatch(secret??"","^[a-f0-9]{64}$"))throw new ArgumentException("Invalid manager route inputs");
      var newline=source.Contains("\r\n")?"\r\n":"\n";
      // The download landing page deliberately forbids network requests.
      // Only the authenticated diagnostics UI needs same-origin fetch; serve
      // it through a narrower path rather than relaxing the entire website.
      var usbWeb=source.Contains("handle_path /descargas/*")?
        "\thandle_path /descargas/servidor/* {"+newline+
        "\t\troot * /data/inhouse-downloads/servidor"+newline+
        "\t\theader {"+newline+
        "\t\t\tX-Content-Type-Options nosniff"+newline+
        "\t\t\tReferrer-Policy no-referrer"+newline+
        "\t\t\tContent-Security-Policy \"default-src 'none'; style-src 'self'; img-src 'self'; script-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'\""+newline+
        "\t\t\tCache-Control \"no-cache\""+newline+
        "\t\t}"+newline+
        "\t\tfile_server"+newline+
        "\t}"+newline:"";
      var block=BeginMarker+newline+usbWeb+
        "\thandle /inhouse-manager/* {"+newline+
        "\t\treverse_proxy host.docker.internal:"+Port+" {"+newline+
        "\t\t\theader_up X-Inhouse-Bridge "+secret+newline+
        "\t\t}"+newline+
        "\t}"+newline+EndMarker+newline;
      var begin=source.IndexOf(BeginMarker,StringComparison.Ordinal);var end=source.IndexOf(EndMarker,StringComparison.Ordinal);
      if((begin>=0&&source.IndexOf(BeginMarker,begin+BeginMarker.Length,StringComparison.Ordinal)>=0)||
         (end>=0&&source.IndexOf(EndMarker,end+EndMarker.Length,StringComparison.Ordinal)>=0))
        throw new IOException("Hay varias rutas remotas guardadas. No se cambiará Caddy.");
      if(begin>=0&&end>begin){
        var after=end+EndMarker.Length;while(after<source.Length&&(source[after]=='\r'||source[after]=='\n'))after++;
        return source.Substring(0,begin)+block+source.Substring(after);
      } else {
        if(begin>=0||end>=0)throw new IOException("La ruta remota existente está incompleta. No se cambiará Caddy.");
        var matches=Regex.Matches(source,@"(?m)^[ \t]*handle \{\r?$");
        if(matches.Count!=1)throw new IOException("No se pudo identificar la ruta principal de Caddy sin riesgo.");
        return source.Insert(matches[0].Index,block);
      }
    }
    public async Task EnsurePublished() {
      if(!prefs.Managed||String.IsNullOrWhiteSpace(prefs.Endpoint))return;
      var endpoint=new Uri(Backend.CanonicalEndpoint(prefs.Endpoint));if(endpoint.Scheme!="https"||endpoint.Port!=443||endpoint.AbsolutePath!="/")return;
      var caddyfile=System.IO.Path.Combine(prefs.Installation,"Caddyfile");if(!File.Exists(caddyfile))return;
      var source=File.ReadAllText(caddyfile);
      var changed=WithRoute(source,secret);
      Backend.ValidateManagedConfiguration(prefs);
      var container=(await Backend.Compose(prefs,"ps -q caddy",15)).Trim();
      if(!Regex.IsMatch(container,"^[a-f0-9]{64}$"))throw new IOException("El proxy HTTPS no está disponible.");
      var sourceHash=Backend.Hash(caddyfile);
      if(File.ReadAllText(caddyfile)!=source)throw new IOException("La configuración cambió durante la comprobación de la ruta.");
      if(changed==source) {
        if(container==publishedContainer&&sourceHash==publishedConfigurationHash)return;
        // A saved route is not proof that the running proxy loaded it. Verify
        // the mounted configuration and hot-reload once per manager launch,
        // or when the proxy/container changes. No file or receipt is rewritten.
        var mounted=await Backend.Docker("exec "+container+" cat /etc/caddy/Caddyfile",20);
        if(mounted!=source)throw new IOException("El proxy no ve la configuración verificada de la ruta remota.");
        await Backend.Docker("exec "+container+" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile",30);
        if(Backend.Hash(caddyfile)!=sourceHash)throw new IOException("La configuración cambió durante la comprobación de la ruta.");
        await Backend.Docker("exec "+container+" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile",30);
        Backend.ValidateManagedConfiguration(prefs);
        if(Backend.Hash(caddyfile)!=sourceHash)throw new IOException("La configuración cambió durante la comprobación de la ruta.");
        publishedContainer=container;publishedConfigurationHash=sourceHash;
        return;
      }
      Backend.PrivateDirectory(Backend.SettingsDir);
      var id=Guid.NewGuid().ToString("N");var candidate=System.IO.Path.Combine(Backend.SettingsDir,"Caddyfile-manager-"+id);
      var backup=System.IO.Path.Combine(Backend.SettingsDir,"Caddyfile.before-manager-"+id);
      var inside="/tmp/inhouse-manager-"+id+".caddy";
      File.WriteAllText(candidate,changed,new UTF8Encoding(false));
      var wrote=false;
      try {
        await Backend.Docker("cp "+Backend.Quote(candidate)+" "+Backend.Quote(container+":"+inside),30);
        await Backend.Docker("exec "+container+" caddy validate --config "+inside+" --adapter caddyfile",30);
        Backend.ValidateManagedConfiguration(prefs);
        if(Backend.Hash(caddyfile)!=sourceHash)throw new IOException("La configuración cambió durante la comprobación de la ruta.");
        // Preserve the original bytes. The running Caddy process keeps serving
        // traffic while its new configuration is validated and hot-reloaded.
        File.Copy(caddyfile,backup,false);
        File.WriteAllText(caddyfile,changed,new UTF8Encoding(false));wrote=true;
        if(!File.ReadAllText(caddyfile).Contains(BeginMarker))throw new IOException("La nueva ruta no quedó guardada.");
        var mounted=await Backend.Docker("exec "+container+" cat /etc/caddy/Caddyfile",20);
        if(mounted!=changed)throw new IOException("El proxy no ve la nueva ruta; se conserva la configuración anterior.");
        await Backend.Docker("exec "+container+" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile",30);
        var receipt=Backend.Json.Deserialize<AdoptionReceipt>(File.ReadAllText(prefs.ReceiptPath));
        var actual=Backend.ConfigurationHashes(prefs);
        foreach(var item in receipt.ConfigurationHashes)if(item.Key!="Caddyfile"&&(!actual.ContainsKey(item.Key)||actual[item.Key]!=item.Value))
          throw new IOException("Otra configuración cambió durante la actualización de la ruta.");
        receipt.ConfigurationHashes["Caddyfile"]=actual["Caddyfile"];
        var receiptTemp=prefs.ReceiptPath+"."+id+".new";
        File.WriteAllText(receiptTemp,Backend.Json.Serialize(receipt),new UTF8Encoding(false));
        File.Replace(receiptTemp,prefs.ReceiptPath,prefs.ReceiptPath+"."+id+".before-manager");
        wrote=false;
        publishedContainer=container;publishedConfigurationHash=actual["Caddyfile"];
      }catch {
        if(wrote) {
          try{File.Copy(backup,caddyfile,true);await Backend.Docker("exec "+container+" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile",30);}catch{}
        }
        throw;
      }finally {
        try{await Backend.Docker("exec "+container+" rm -f "+inside,10);}catch{}
        if(File.Exists(candidate))File.Delete(candidate);
      }
    }
    public void Dispose() {disposed=true;listener.Stop();}
  }
}
