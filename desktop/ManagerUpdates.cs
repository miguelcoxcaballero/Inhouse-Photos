using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace InhousePhotos {
  public sealed class ManagerUpdateManifest {
    public string Version {get;set;}
    public string InstallerUrl {get;set;}
    public string Sha256 {get;set;}
    public string Notes {get;set;}
  }
  public sealed class ManagerUpdateStatus {
    public string CurrentVersion {get;set;}
    public string LatestVersion {get;set;}
    public bool Available {get;set;}
    public string Phase {get;set;}
    public int Progress {get;set;}
    public string Error {get;set;}
    public string Notes {get;set;}
  }
  /// Updates only the Windows manager. The Docker Compose project is never
  /// stopped, recreated, or touched by the installer hand-off.
  public static class ManagerUpdates {
    public const string ManifestUrl="https://raw.githubusercontent.com/miguelcoxcaballero/Inhouse-Photos/main/windows-server-update.json";
    static readonly SemaphoreSlim CheckGate=new SemaphoreSlim(1,1);
    static readonly object StateGate=new object();
    static ManagerUpdateManifest cached;
    static DateTime checkedAtUtc=DateTime.MinValue;
    static string phase="idle",error="";
    static int progress;
    static bool applying;
    static Process helper;
    public static bool IsApplying {get{lock(StateGate){RefreshHelper();return applying;}}}
    static string UpdatesDir {get{return Path.Combine(Backend.SettingsDir,"updates");}}
    static string ErrorPath {get{return Path.Combine(Backend.SettingsDir,"last-manager-update-error.txt");}}

    public static ManagerUpdateStatus Status() {
      lock(StateGate) {
        RefreshHelper();
        if(phase=="idle"&&File.Exists(ErrorPath)) {
          var recorded=RecordedError();if(recorded!=null){error=recorded;phase="error";}
        }
        return new ManagerUpdateStatus {
        CurrentVersion=Backend.Version,LatestVersion=cached==null?Backend.Version:cached.Version,
        Available=cached!=null&&Compare(cached.Version,Backend.Version)>0,
        Phase=phase,Progress=progress,Error=error,Notes=cached==null?"":cached.Notes??""
        };
      }
    }
    public static int Compare(string a,string b) {return Version.Parse(a).CompareTo(Version.Parse(b));}
    static bool Valid(ManagerUpdateManifest value) {
      Version parsed;
      if(value==null||!Regex.IsMatch(value.Version??"","^[0-9]+\\.[0-9]+\\.[0-9]+$")||
         !Version.TryParse(value.Version,out parsed)||
         !Regex.IsMatch(value.Sha256??"","^[a-f0-9]{64}$"))return false;
      Uri uri;if(!Uri.TryCreate(value.InstallerUrl,UriKind.Absolute,out uri)||uri.Scheme!="https"||uri.Host!="github.com"||
        uri.AbsolutePath!="/miguelcoxcaballero/Inhouse-Photos/releases/download/server-v"+value.Version+"/Inhouse-Photos-Server-Setup.exe"||
        !String.IsNullOrEmpty(uri.Query)||!String.IsNullOrEmpty(uri.Fragment))return false;
      return value.Notes==null||value.Notes.Length<=500;
    }
    static async Task<byte[]> ReadLimited(Stream stream,int max) {
      using(var output=new MemoryStream()) {var buffer=new byte[4096];int size;
        while((size=await stream.ReadAsync(buffer,0,buffer.Length))>0){if(output.Length+size>max)throw new IOException("El aviso de actualización es demasiado grande.");output.Write(buffer,0,size);}
        return output.ToArray();
      }
    }
    public static async Task<ManagerUpdateStatus> Check(bool force=false) {
      await CheckGate.WaitAsync();
      try {
        if(!force&&cached!=null&&DateTime.UtcNow-checkedAtUtc<TimeSpan.FromSeconds(15))return Status();
        ServicePointManager.SecurityProtocol|=SecurityProtocolType.Tls12;
        var request=(HttpWebRequest)WebRequest.Create(ManifestUrl);
        request.Method="GET";request.Timeout=8000;request.ReadWriteTimeout=8000;
        request.Headers[HttpRequestHeader.CacheControl]="no-cache";
        using(var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(8)))using(deadline.Token.Register(()=>request.Abort()))
        using(var response=(HttpWebResponse)await request.GetResponseAsync()) {
          if(response.StatusCode!=HttpStatusCode.OK||response.ResponseUri.Scheme!="https"||
             response.ResponseUri.Host!="raw.githubusercontent.com"||response.ContentLength>4096)
            throw new IOException("No se pudo verificar la versión publicada.");
          var bytes=await ReadLimited(response.GetResponseStream(),4096);
          var manifest=Backend.Json.Deserialize<ManagerUpdateManifest>(Encoding.UTF8.GetString(bytes));
          if(!Valid(manifest))throw new IOException("Los datos de actualización no son válidos.");
          lock(StateGate){cached=manifest;checkedAtUtc=DateTime.UtcNow;}
        }
        return Status();
      } finally {CheckGate.Release();}
    }
    static void State(string next,int percent=0,string message="") {
      lock(StateGate){phase=next;progress=percent;error=message;}
    }
    static string RecordedError() {
      try {
        if(!File.Exists(ErrorPath)||(File.GetAttributes(ErrorPath)&FileAttributes.ReparsePoint)!=0||new FileInfo(ErrorPath).Length>4096)return null;
        var recorded=File.ReadAllText(ErrorPath).Trim();
        return String.IsNullOrEmpty(recorded)?null:recorded.Substring(0,Math.Min(300,recorded.Length));
      }catch{return null;}
    }
    static void RefreshHelper() {
      if(helper==null)return;
      // A living installer can still be changing the validated active pointer.
      // Only its confirmed exit makes retrying safe; elapsed time alone does not.
      try{if(!helper.HasExited)return;}catch{return;}
      helper.Dispose();helper=null;applying=false;progress=0;
      error=RecordedError()??(phase=="error"&&!String.IsNullOrEmpty(error)?error:
        "El instalador terminó sin cerrar este gestor. Pulsa Actualizar para reintentar; el servidor y tus fotos siguen disponibles.");
      phase="error";
    }
    static void TrackHelper(Process process) {
      if(process==null)throw new IOException("No se pudo iniciar el instalador de Windows.");
      lock(StateGate){helper=process;applying=true;phase="installing";progress=100;error="";}
    }
    public static bool TryBegin() {
      lock(StateGate){RefreshHelper();if(applying)return false;applying=true;phase="downloading";progress=0;error="";try{if(File.Exists(ErrorPath))File.Delete(ErrorPath);}catch{}return true;}
    }
    public static void Fail(Exception ex) {
      lock(StateGate){RefreshHelper();phase="error";error=ex.Message;applying=helper!=null;}
    }
    public static async Task<string> Prepare() {
      var status=await Check(true);
      if(!status.Available)throw new IOException("El gestor ya tiene la versión más reciente.");
      ManagerUpdateManifest manifest;lock(StateGate)manifest=cached;
      Backend.PrivateDirectory(UpdatesDir);
      var target=Path.Combine(UpdatesDir,"Inhouse-Photos-Server-Setup-"+manifest.Version+".exe");
      if(!File.Exists(target)||Backend.Hash(target)!=manifest.Sha256){
        var partial=target+"."+Guid.NewGuid().ToString("N")+".partial";
        try {
          var request=(HttpWebRequest)WebRequest.Create(manifest.InstallerUrl);
          request.Timeout=15000;request.ReadWriteTimeout=30000;
          using(var response=(HttpWebResponse)await request.GetResponseAsync()) {
            var host=response.ResponseUri.Host;
            if(response.ResponseUri.Scheme!="https"||
              (host!="github.com"&&host!="release-assets.githubusercontent.com"&&host!="objects.githubusercontent.com")||
              response.ContentLength>20*1024*1024)
              throw new IOException("La descarga de Windows no procede de una fuente permitida.");
            using(var input=response.GetResponseStream())using(var output=new FileStream(partial,FileMode.CreateNew,FileAccess.Write,FileShare.None,65536,true)) {
              var buffer=new byte[65536];long total=0;int count;
              while((count=await input.ReadAsync(buffer,0,buffer.Length))>0) {
                total+=count;if(total>20*1024*1024)throw new IOException("La descarga de Windows es demasiado grande.");
                await output.WriteAsync(buffer,0,count);
                if(response.ContentLength>0)State("downloading",(int)Math.Min(99,total*100/response.ContentLength));
              }
            }
          }
          if(Backend.Hash(partial)!=manifest.Sha256)throw new IOException("La descarga no coincide con la versión publicada. No se instalará.");
          if(File.Exists(target))File.Delete(target);
          File.Move(partial,target);
        } finally {if(File.Exists(partial))File.Delete(partial);}
      }
      State("verifying",100);
      if(Backend.Hash(target)!=manifest.Sha256)throw new IOException("El instalador no pasa la comprobación de integridad.");
      var embedded=AssemblyName.GetAssemblyName(target).Version;
      if(embedded.Major!=Version.Parse(manifest.Version).Major||embedded.Minor!=Version.Parse(manifest.Version).Minor||
         embedded.Build!=Version.Parse(manifest.Version).Build)
        throw new IOException("El instalador no contiene la versión esperada.");
      using(var process=Process.Start(new ProcessStartInfo(target,"--verify-payload") {
        UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden
      })) {
        if(!await Task.Run(()=>process.WaitForExit(15000))) {try{process.Kill();}catch{}throw new TimeoutException("No se pudo comprobar el instalador.");}
        if(process.ExitCode!=0)throw new IOException("El instalador no pasa la comprobación interna.");
      }
      State("ready",100);return target;
    }
    public static void StartHelper(string installer,int managerPid,bool hidden) {
      ManagerUpdateManifest release;lock(StateGate)release=cached;
      if(release==null||!File.Exists(installer)||Backend.Hash(installer)!=release.Sha256)
        throw new IOException("El instalador cambió después de comprobarlo. No se ejecutará.");
      var arguments="--wait-and-install "+managerPid+(hidden?" --restart-hidden":"");
      TrackHelper(Process.Start(new ProcessStartInfo(installer,arguments) {
        UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden,
        WorkingDirectory=Path.GetDirectoryName(installer)
      }));
    }
  }
}
