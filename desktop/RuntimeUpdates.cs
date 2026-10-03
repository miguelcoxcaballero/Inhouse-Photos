using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace InhousePhotos {
  public sealed class RuntimeUpdateStatus {
    public string CurrentVersion {get;set;}
    public string LatestVersion {get;set;}
    public bool Available {get;set;}
    public string Phase {get;set;}
    public int Progress {get;set;}
    public string Error {get;set;}
    public string Notes {get;set;}
    public bool RecoveryRequired {get;set;}
  }
  public sealed class RuntimeImageIdentity {
    public string ImageId,Version,SourceCommit,SchemaSha256;
  }
  public sealed class RuntimeTransaction {
    public int format {get;set;}
    public string status {get;set;}
    public string sourceCommit {get;set;}
    public string newImageId {get;set;}
    public string installation {get;set;}
    public string project {get;set;}
    public string receiptPath {get;set;}
  }
  /// The manager pins the already verified public engine. No phone input can
  /// select a release, URL, script, command, Docker context or recovery path.
  public static class RuntimeUpdates {
    public const string LatestVersion="3.1.0-durable-upload-20261003";
    public const string LatestImage="inhouse-photos-server:v3.1.0-durable-upload-20261003";
    public const string LatestImageId="sha256:dd8c68b182ef2cade7002e7625c43e60ee89e27ee42eec0fb4b6e392d34a8a75";
    public const string SourceCommit="f661cdd96ebfb50349ca60a40a7cff3e4511f995";
    public const string SchemaSha256="ab48e687123b61185a4467ca2b70a3a66ebfdaa93f5a78b5d7ae9eed613c699f";
    public const string ArchiveFile="inhouse-server-3.1.0-durable-upload-20261003.tar.gz";
    public const string ArchiveSha256="e291e6433c6238e5819e04ee578b2324c4539d19f92c622878f994561422f147";
    public const string ManifestSha256="4b75f5d1049bdb350e0b76ee789c6ba0b437bc622c3e0c25d5072212e8f8c513";
    public const string PackageSha256="ac0e1e8e0691544376b982f3d7b9bd784fa24a4db2aef2dbbe552db2e410aaf3";
    public const string PackageFile="Inhouse-Photos-Server-Runtime-3.1.0-durable-upload-20261003.zip";
    public const string PackageUrl="https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/server-runtime-v3.1.0-durable-upload-20261003/"+PackageFile;
    const string OriginalImage="sha256:283fb546c253d70c3e984062a2d2ebc08ce4547ef799e0ffba634222e4b5c16d";
    const string OriginalConfig="sha256:ac66612c5815b715123e1946fb833cc3baa5adcb404f774ded31307d82c1e368";
    const string FastImage="sha256:0034cd9b0031574479c192ed8be48212f6e57012785d804beb171ed8a2d5a8ac";
    const string Notes="Guarda originales y trabajos pendientes en el servidor; el móvil puede seguir subiendo mientras se procesan. Durante la instalación se reinicia brevemente el motor de fotos.";
    static readonly object StateGate=new object();
    static readonly SemaphoreSlim CheckGate=new SemaphoreSlim(1,1),DownloadGate=new SemaphoreSlim(1,1);
    static string current="",phase="idle",error="";
    static bool compatible,applying,recoveryRequired;
    static int progress;
    static DateTime checkedAt=DateTime.MinValue;
    static string ComponentDir {get{return Path.Combine(Backend.SettingsDir,"runtime-components",LatestVersion);}}
    static string ErrorPath {get{return Path.Combine(Backend.SettingsDir,"last-runtime-update-error.txt");}}

    public static bool IsApplying {get{lock(StateGate)return applying;}}
    public static bool IsBusy {get{return IsApplying||OtherHelperRunning();}}
    static bool OtherHelperRunning() {
      try {
        using(var mutex=Mutex.OpenExisting(@"Local\InhousePhotosRuntimeUpdate")) {
          bool acquired=false;
          try {try{acquired=mutex.WaitOne(0);}catch(AbandonedMutexException){acquired=true;}return !acquired;}
          finally{if(acquired)mutex.ReleaseMutex();}
        }
      }catch(WaitHandleCannotBeOpenedException){return false;}
    }
    public static bool BlocksOperations(Preferences prefs) {
      if(IsApplying||OtherHelperRunning())return true;
      try{return FindPendingTransaction(prefs)!=null;}catch{return true;}
    }
    public static RuntimeUpdateStatus Status() {
      lock(StateGate)return new RuntimeUpdateStatus {
        CurrentVersion=current,LatestVersion=LatestVersion,Available=compatible||recoveryRequired,
        Phase=phase,Progress=progress,Error=error,Notes=recoveryRequired?
          "La actualización anterior quedó pendiente. Reintenta para verificar el motor y recuperar las colas.":Notes,
        RecoveryRequired=recoveryRequired
      };
    }
    static void State(string next,int percent,string message="") {
      lock(StateGate){phase=next;progress=percent;error=message;}
    }
    internal static string KnownVersion(RuntimeImageIdentity image) {
      if(image==null)return "";
      if(image.ImageId==OriginalImage||image.ImageId==OriginalConfig)return "3.1.0-pairing-20260929";
      if(image.ImageId==FastImage)return "3.1.0-storage-saver-20261002";
      if(image.ImageId==LatestImageId&&image.Version==LatestVersion&&image.SourceCommit==SourceCommit&&image.SchemaSha256==SchemaSha256)return LatestVersion;
      return "";
    }
    static async Task<RuntimeImageIdentity> ReadImage(string image) {
      if(!Regex.IsMatch(image??"","^sha256:[a-f0-9]{64}$")&&image!=LatestImage)throw new IOException("Imagen del motor no válida.");
      var format="[{{json .Id}},{{json (index .Config.Labels \"org.opencontainers.image.version\")}},{{json (index .Config.Labels \"org.opencontainers.image.revision\")}},{{json (index .Config.Labels \"inhouse.runtime.database-schema-sha256\")}}]";
      var text=await Backend.Docker("image inspect --format "+Backend.Argument(format)+" "+image,20);
      var values=Backend.Json.Deserialize<string[]>(text.Trim());
      if(values==null||values.Length!=4||!Regex.IsMatch(values[0]??"","^sha256:[a-f0-9]{64}$"))throw new IOException("No se pudo identificar la imagen del motor.");
      return new RuntimeImageIdentity{ImageId=values[0],Version=values[1],SourceCommit=values[2],SchemaSha256=values[3]};
    }
    static async Task<RuntimeImageIdentity> ReadCurrent(Preferences prefs,bool allowPending=false) {
      if(!allowPending)Backend.ValidateManagedConfiguration(prefs);
      var rows=await Backend.InspectServer(prefs);
      var receipt=Backend.Json.Deserialize<AdoptionReceipt>(File.ReadAllText(prefs.ReceiptPath));
      Backend.AssertManagedIdentity(prefs,receipt.Containers,rows);
      return await ReadImage(rows.Single(row=>row.Service=="immich-server").Image);
    }
    static IEnumerable<string> TransactionFiles(string root) {
      if(!Directory.Exists(root))yield break;
      var pending=new Stack<string>();pending.Push(root);int count=0;
      while(pending.Count!=0) {
        var directory=pending.Pop();Backend.RejectLinks(directory);
        if(++count>1024)throw new IOException("Hay demasiados registros de actualización para comprobarlos automáticamente.");
        var file=Path.Combine(directory,"transaction.json");
        if(File.Exists(file)) {
          if((File.GetAttributes(file)&FileAttributes.ReparsePoint)!=0)throw new IOException("Un registro de actualización no puede ser un enlace.");
          yield return file;
        }
        foreach(var child in Directory.GetDirectories(directory))pending.Push(child);
      }
    }
    internal static bool MatchesRecovery(RuntimeTransaction record,Preferences prefs) {
      return record!=null&&prefs!=null&&record.format==1&&record.sourceCommit==SourceCommit&&record.newImageId==LatestImageId&&
        record.installation==prefs.Installation&&record.project==prefs.ProjectName&&record.receiptPath==prefs.ReceiptPath;
    }
    static string FindPendingTransaction(Preferences prefs) {
      if(prefs==null||!prefs.Managed)return null;
      string found=null;
      foreach(var file in TransactionFiles(Path.Combine(Backend.SettingsDir,"runtime-updates"))) {
        if(new FileInfo(file).Length>256*1024)throw new IOException("Un registro de actualización es demasiado grande.");
        var record=Backend.Json.Deserialize<RuntimeTransaction>(File.ReadAllText(file));
        if(record==null)throw new IOException("Un registro de actualización está incompleto.");
        if(record.status=="completed"||record.status=="rolled-back"||record.status=="aborted")continue;
        if(found!=null||!MatchesRecovery(record,prefs))throw new IOException("Hay una actualización pendiente que necesita comprobarse en el PC antes de continuar.");
        found=file;
      }
      return found;
    }
    public static async Task<RuntimeUpdateStatus> Check(Preferences prefs,bool force=false) {
      await CheckGate.WaitAsync();
      try {
        if(IsApplying)return Status();
        if(!force&&DateTime.UtcNow-checkedAt<TimeSpan.FromSeconds(15))return Status();
        var pending=FindPendingTransaction(prefs);
        // A verified journal is sufficient to offer recovery. Docker may have
        // stopped between removing and recreating the server; the helper must
        // perform its full identity checks before making any change.
        if(pending!=null)lock(StateGate){recoveryRequired=true;compatible=false;phase="error";error="La actualización necesita completarse. Reintenta desde esta pantalla.";}
        RuntimeImageIdentity image;
        try{image=await ReadCurrent(prefs,pending!=null);}
        catch{if(pending==null)throw;lock(StateGate){current="Motor pendiente de recuperación";checkedAt=DateTime.UtcNow;}return Status();}
        var version=KnownVersion(image);
        lock(StateGate) {
          current=version.Length>0?version:"Motor no reconocido";
          compatible=version.Length>0&&version!=LatestVersion;
          recoveryRequired=pending!=null;
          checkedAt=DateTime.UtcNow;
          if(pending!=null){phase="error";error="La actualización necesita completarse. Reintenta desde esta pantalla.";}
          else if(version.Length==0){phase="error";error="La imagen instalada no figura como compatible; no se sustituirá automáticamente.";}
          else if(phase=="idle"&&File.Exists(ErrorPath)){phase="error";error="La actualización anterior no se confirmó. Puedes reintentar.";}
        }
        return Status();
      }finally{CheckGate.Release();}
    }
    public static bool TryBegin() {
      lock(StateGate) {
        if(applying||(!compatible&&!recoveryRequired)||OtherHelperRunning())return false;
        applying=true;phase="downloading";progress=0;error="";return true;
      }
    }
    public static void Fail(Exception failure) {
      lock(StateGate){phase="error";error=failure.Message;applying=false;checkedAt=DateTime.MinValue;}
      try{Backend.PrivateDirectory(Backend.SettingsDir);File.WriteAllText(ErrorPath,"La actualización del motor no se confirmó.");}catch{}
    }
    static async Task DownloadPackage(string target) {
      var partial=target+"."+Guid.NewGuid().ToString("N")+".partial";
      try {
        ServicePointManager.SecurityProtocol|=SecurityProtocolType.Tls12;
        var request=(HttpWebRequest)WebRequest.Create(PackageUrl);
        request.Timeout=15000;request.ReadWriteTimeout=60000;
        using(var deadline=new CancellationTokenSource(TimeSpan.FromMinutes(30)))using(deadline.Token.Register(()=>request.Abort()))
        using(var response=(HttpWebResponse)await request.GetResponseAsync()) {
          var host=response.ResponseUri.Host;
          if(response.StatusCode!=HttpStatusCode.OK||response.ResponseUri.Scheme!="https"||
            (host!="github.com"&&host!="release-assets.githubusercontent.com"&&host!="objects.githubusercontent.com")||
            response.ContentLength>2L*1024*1024*1024)throw new IOException("El paquete del motor no procede de la publicación permitida.");
          using(var input=response.GetResponseStream())using(var output=new FileStream(partial,FileMode.CreateNew,FileAccess.Write,FileShare.None,65536,true)) {
            var buffer=new byte[65536];long total=0;int count;
            while((count=await input.ReadAsync(buffer,0,buffer.Length))>0) {
              total+=count;if(total>2L*1024*1024*1024)throw new IOException("El paquete del motor es demasiado grande.");
              await output.WriteAsync(buffer,0,count);
              if(response.ContentLength>0)State("downloading",(int)Math.Min(99,total*100/response.ContentLength));
            }
          }
        }
        State("verifying",70);
        if(Backend.Hash(partial)!=PackageSha256)throw new IOException("El paquete no coincide con el motor publicado. No se instalará.");
        if(File.Exists(target))File.Delete(target);
        File.Move(partial,target);
      }finally{if(File.Exists(partial))File.Delete(partial);}
    }
    static void Extract(ZipArchive zip,string entryName,string target,long maximum,string expected) {
      var entries=zip.Entries.Where(entry=>entry.FullName==entryName).ToArray();
      if(entries.Length!=1||entries[0].Length>maximum)throw new IOException("Falta un archivo verificado del paquete del motor.");
      var partial=target+"."+Guid.NewGuid().ToString("N")+".partial";
      try {
        using(var input=entries[0].Open())using(var output=new FileStream(partial,FileMode.CreateNew,FileAccess.Write,FileShare.None))input.CopyTo(output);
        if(Backend.Hash(partial)!=expected)throw new IOException("Un archivo del paquete no pasa la comprobación de integridad.");
        if(File.Exists(target))File.Delete(target);File.Move(partial,target);
      }finally{if(File.Exists(partial))File.Delete(partial);}
    }
    static string WriteResource(string directory,string filename) {
      var path=Path.Combine(directory,filename);
      using(var source=typeof(RuntimeUpdates).Assembly.GetManifestResourceStream("InhousePhotos."+filename)) {
        if(source==null)throw new IOException("Falta el actualizador verificado en el gestor.");
        using(var bytes=new MemoryStream()) {
          if(filename.EndsWith(".ps1",StringComparison.Ordinal))bytes.Write(new byte[]{239,187,191},0,3);
          source.CopyTo(bytes);File.WriteAllBytes(path,bytes.ToArray());
        }
      }
      return path;
    }
    static async Task<string> PrepareFiles() {
      await DownloadGate.WaitAsync();
      try {
        Backend.PrivateDirectory(ComponentDir);
        var drive=new DriveInfo(Path.GetPathRoot(ComponentDir));
        if(drive.AvailableFreeSpace<4L*1024*1024*1024)throw new IOException("Necesitas al menos 4 GB libres en el disco del gestor para descargar y preparar el motor.");
        var package=Path.Combine(ComponentDir,PackageFile);
        if(!File.Exists(package)||Backend.Hash(package)!=PackageSha256)await DownloadPackage(package);
        State("verifying",70);
        using(var input=File.OpenRead(package))using(var zip=new ZipArchive(input,ZipArchiveMode.Read)) {
          Extract(zip,"server-runtime-update.json",Path.Combine(ComponentDir,"server-runtime-update.json"),16384,ManifestSha256);
          Extract(zip,ArchiveFile,Path.Combine(ComponentDir,ArchiveFile),2L*1024*1024*1024,ArchiveSha256);
        }
        WriteResource(ComponentDir,"server-runtime-update.ps1");WriteResource(ComponentDir,"server-runtime-queue-handoff.cjs");
        return ComponentDir;
      }finally{DownloadGate.Release();}
    }
    static void HelperPhase(string line) {
      const string prefix="INHOUSE_RUNTIME_PHASE:";
      if(line==null||!line.StartsWith(prefix,StringComparison.Ordinal))return;
      var value=line.Substring(prefix.Length);
      switch(value) {
        case "verifying":State(value,75);break;
        case "installing":State(value,80);break;
        case "waiting":State(value,85);break;
        case "restarting":State(value,95);break;
        // Completion is confirmed again from the real image and receipt below.
      }
    }
    static async Task RunHelper(string directory,string recovery) {
      var key=Guid.NewGuid().ToString("N");var managerPid=Process.GetCurrentProcess().Id;
      using(var operation=new EventWaitHandle(true,EventResetMode.ManualReset,@"Local\InhousePhotosRuntime-"+managerPid+"-"+key)) {
        var script=Path.Combine(directory,"server-runtime-update.ps1");
        var arguments="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "+Backend.Quote(script)+
          " -SettingsDirectory "+Backend.Quote(Backend.SettingsDir)+" -DockerExe "+Backend.Quote(Backend.DockerExe())+
          " -ManagerProcessId "+managerPid+" -ManagerOperationKey "+key+" -Apply";
        arguments+=recovery==null?
          " -ManifestPath "+Backend.Quote(Path.Combine(directory,"server-runtime-update.json"))+" -ManifestSha256 "+ManifestSha256+
          " -ArchivePath "+Backend.Quote(Path.Combine(directory,ArchiveFile)):
          " -ResumeRecord "+Backend.Quote(recovery);
        using(var process=new Process{StartInfo=new ProcessStartInfo(Path.Combine(Environment.SystemDirectory,@"WindowsPowerShell\v1.0\powershell.exe"),arguments) {
          UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden,
          WorkingDirectory=directory,RedirectStandardOutput=true,RedirectStandardError=true
        }}) {
          process.OutputDataReceived+=(sender,e)=>HelperPhase(e.Data);
          process.Start();process.BeginOutputReadLine();var stderr=process.StandardError.ReadToEndAsync();
          if(!await Task.Run(()=>process.WaitForExit(45*60*1000))) {
            try{process.Kill();}catch{}
            throw new IOException("El motor no confirmó la actualización a tiempo. Conserva sus datos y reintenta para recuperar la operación.");
          }
          process.WaitForExit();await stderr;
          if(process.ExitCode!=0)throw new IOException("El motor no confirmó la actualización. Reintenta para recuperar la operación; si la API no responde, comprueba el servidor en el PC.");
        }
      }
    }
    public static async Task Apply(Preferences prefs) {
      try {
        await Backend.WithServerLock(async()=>{
          var recovery=FindPendingTransaction(prefs);
          var directory=recovery==null?await PrepareFiles():ComponentDir;
          if(recovery!=null) {
            Backend.PrivateDirectory(directory);
            WriteResource(directory,"server-runtime-update.ps1");WriteResource(directory,"server-runtime-queue-handoff.cjs");
            State("waiting",85);
          }
          await RunHelper(directory,recovery);
          State("restarting",95);
          var installed=await ReadCurrent(prefs);
          if(KnownVersion(installed)!=LatestVersion||FindPendingTransaction(prefs)!=null||!await Backend.Ping(prefs.LocalEndpoint))
            throw new IOException("El motor instalado todavía necesita comprobarse. Reintenta para recuperar la actualización.");
          lock(StateGate){current=LatestVersion;compatible=false;recoveryRequired=false;phase="completed";progress=100;error="";checkedAt=DateTime.UtcNow;}
          try{if(File.Exists(ErrorPath))File.Delete(ErrorPath);}catch{}
        });
      }catch(Exception ex) {
        try{lock(StateGate)recoveryRequired=FindPendingTransaction(prefs)!=null;}catch{lock(StateGate)recoveryRequired=true;}
        Fail(ex);throw;
      }finally{lock(StateGate)applying=false;}
    }
    public static async Task EnsureImage(Action<string> notify) {
      try{if(KnownVersion(await ReadImage(LatestImage))==LatestVersion)return;}catch{}
      notify("Descargando y comprobando el motor de fotos…");
      var directory=await PrepareFiles();
      notify("Preparando el motor de fotos…");await Backend.Docker("load --input "+Backend.Quote(Path.Combine(directory,ArchiveFile)),900);
      if(KnownVersion(await ReadImage(LatestImage))!=LatestVersion)throw new IOException("El motor descargado no pasa la verificación.");
      State("idle",0);
    }
    public static int VerifyHandoff() {
      // This headless release check exercises real Windows process ownership
      // and the live operation event without touching settings or Docker.
      var directory=Path.Combine(Path.GetTempPath(),"inhouse-runtime-handoff-"+Guid.NewGuid().ToString("N"));
      try {
        Backend.PrivateDirectory(directory);
        var script=WriteResource(directory,"server-runtime-update.ps1");
        var key=Guid.NewGuid().ToString("N");var pid=Process.GetCurrentProcess().Id;
        using(var operation=new EventWaitHandle(true,EventResetMode.ManualReset,@"Local\InhousePhotosRuntime-"+pid+"-"+key)) {
          var command=". '"+script.Replace("'","''")+"' -FunctionsOnly -ManifestPath unused -ManifestSha256 ('a'*64) -ArchivePath unused"+
            " -ManagerProcessId "+pid+" -ManagerOperationKey "+key+"; Assert-NoManager; "+
            "$script:ManagerOperationKey='"+Guid.NewGuid().ToString("N")+"'; $rejected=$false; "+
            "try { Assert-NoManager } catch { $rejected=$true }; if (-not $rejected) { exit 2 }; Write-Output 'INHOUSE_HANDOFF_VERIFIED'";
          var encoded=Convert.ToBase64String(Encoding.Unicode.GetBytes(command));
          using(var process=new Process{StartInfo=new ProcessStartInfo(Path.Combine(Environment.SystemDirectory,@"WindowsPowerShell\v1.0\powershell.exe"),
            "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "+encoded) {
              UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=directory,RedirectStandardOutput=true,RedirectStandardError=true
            }}) {
            process.Start();var output=process.StandardOutput.ReadToEndAsync();var errors=process.StandardError.ReadToEndAsync();
            if(!process.WaitForExit(30000)){try{process.Kill();}catch{}return 1;}
            var body=output.GetAwaiter().GetResult();errors.GetAwaiter().GetResult();
            return process.ExitCode==0&&body.Trim()=="INHOUSE_HANDOFF_VERIFIED"?0:2;
          }
        }
      }catch{return 3;}
      finally{try{if(Directory.Exists(directory))Directory.Delete(directory,true);}catch{}}
    }
    public static int SelfTest() {
      var prefs=new Preferences{Managed=true,Installation=@"D:\photos",ProjectName="inhouse-test",ReceiptPath=@"C:\receipt.json"};
      var transaction=new RuntimeTransaction{format=1,sourceCommit=SourceCommit,newImageId=LatestImageId,installation=prefs.Installation,project=prefs.ProjectName,receiptPath=prefs.ReceiptPath};
      if(!MatchesRecovery(transaction,prefs))return 1;
      transaction.newImageId=OriginalImage;if(MatchesRecovery(transaction,prefs))return 2;
      if(KnownVersion(new RuntimeImageIdentity{ImageId=OriginalConfig})!="3.1.0-pairing-20260929")return 3;
      if(KnownVersion(new RuntimeImageIdentity{ImageId=FastImage})!="3.1.0-storage-saver-20261002")return 4;
      var image=new RuntimeImageIdentity{ImageId=LatestImageId,Version=LatestVersion,SourceCommit=SourceCommit,SchemaSha256=SchemaSha256};
      if(KnownVersion(image)!=LatestVersion)return 5;
      image.SourceCommit=new string('a',40);if(KnownVersion(image)!="")return 6;
      if(!RemoteManagement.Allowed("GET",RemoteManagement.RuntimePath)||!RemoteManagement.Allowed("POST",RemoteManagement.RuntimePath)||
        RemoteManagement.Allowed("POST",RemoteManagement.RuntimePath+"/arbitrary")||
        RemoteManagement.Allowed("POST",RemoteManagement.RuntimePath+"?url=elsewhere")||
        RemoteManagement.ReadOnlyBrowserToken("POST",RemoteManagement.RuntimePath,"immich_access_token="+new string('A',43))!=null)return 7;
      if(!NewServer.ComposeText(false).Contains("image: "+LatestImage))return 9;
      var now=DateTime.UtcNow;
      if(!RemoteManagement.MayReadProgress("GET",RemoteManagement.RuntimePath,true,now.AddMinutes(-4),now)||
        RemoteManagement.MayReadProgress("POST",RemoteManagement.RuntimePath,true,now,now)||
        RemoteManagement.MayReadProgress("GET",RemoteManagement.RuntimePath,false,now,now)||
        RemoteManagement.MayReadProgress("GET",RemoteManagement.RuntimePath,true,now.AddMinutes(-6),now)||
        RemoteManagement.MayReadProgress("GET",RemoteManagement.Path,true,now,now))return 10;
      foreach(var resource in new[]{"server-runtime-update.ps1","server-runtime-queue-handoff.cjs"})
        using(var stream=typeof(RuntimeUpdates).Assembly.GetManifestResourceStream("InhousePhotos."+resource))if(stream==null||stream.Length<100)return 8;
      return 0;
    }
  }
}
