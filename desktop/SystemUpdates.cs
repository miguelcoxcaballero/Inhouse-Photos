using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace InhousePhotos {
  public sealed class SystemUpdateStatus {
    public string CurrentVersion {get;set;}
    public string LatestVersion {get;set;}
    public bool Available {get;set;}
    public string Phase {get;set;}
    public int Progress {get;set;}
    public string Error {get;set;}
    public string Notes {get;set;}
    public bool RecoveryRequired {get;set;}
    public bool Busy {get;set;}
    public bool RequiresLocalRecovery {get;set;}
  }
  public sealed class SystemUpdateIntent {
    public int Format {get;set;}
    public string TargetVersion {get;set;}
    public string Installation {get;set;}
    public string Project {get;set;}
    public string ReceiptPath {get;set;}
    public string State {get;set;}
    public int Attempts {get;set;}
    public string NextAttemptUtc {get;set;}
    public string Error {get;set;}
    public bool RequiresLocalRecovery {get;set;}
  }
  /// A product update survives the installer hand-off, a disconnected phone
  /// and manager restarts. Only the locally pinned engine can be installed.
  public static class SystemUpdates {
    const int MaximumAutomaticAttempts=3;
    const string Notes="Actualiza Inhouse Photos y continúa en el ordenador aunque cierres la app. Conserva tus fotos y los trabajos pendientes.";
    static readonly object Gate=new object();
    static readonly SemaphoreSlim CheckGate=new SemaphoreSlim(1,1);
    static bool applying,confirmed,requiresLocal;
    static string phase="idle",error="",latest=Backend.Version;
    static int progress;
    static DateTime checkedAt=DateTime.MinValue;
    static Task<SystemUpdateStatus> checking;
    static string IntentPath {get{return Path.Combine(Backend.SettingsDir,"system-update.json");}}
    public static bool IsApplying {get{lock(Gate)return applying;}}
    public static bool IsBusy {get{return IsApplying||ManagerUpdates.IsApplying||RuntimeUpdates.IsBusy;}}
    static bool ProductVersion(string value) {
      Version parsed;return Regex.IsMatch(value??"","^[0-9]+\\.[0-9]+\\.[0-9]+$")&&Version.TryParse(value,out parsed);
    }
    internal static bool Matches(SystemUpdateIntent intent,Preferences prefs) {
      return intent!=null&&prefs!=null&&prefs.Managed&&intent.Format==1&&
        ProductVersion(intent.TargetVersion)&&
        intent.Installation==prefs.Installation&&intent.Project==prefs.ProjectName&&intent.ReceiptPath==prefs.ReceiptPath&&
        intent.Attempts>=0&&intent.Attempts<=MaximumAutomaticAttempts&&
        (intent.State=="pending"||intent.State=="running"||intent.State=="error"||intent.State=="completed");
    }
    internal static bool Due(SystemUpdateIntent intent,DateTime now) {
      if(intent==null||intent.State=="completed"||intent.RequiresLocalRecovery||intent.Attempts>=MaximumAutomaticAttempts)return false;
      DateTime next;
      return String.IsNullOrEmpty(intent.NextAttemptUtc)||
        (DateTime.TryParse(intent.NextAttemptUtc,null,System.Globalization.DateTimeStyles.RoundtripKind,out next)&&next.ToUniversalTime()<=now);
    }
    static bool Exhausted(SystemUpdateIntent intent) {
      if(intent==null||intent.State=="completed"||intent.Attempts<MaximumAutomaticAttempts||intent.State=="error")return false;
      intent.State="error";intent.Error="La actualización no se completó automáticamente. Pulsa Actualizar para reintentar; tus fotos y el trabajo pendiente se conservan.";
      return true;
    }
    static SystemUpdateIntent Read(Preferences prefs) {return ReadAt(prefs,IntentPath);}
    static SystemUpdateIntent ReadAt(Preferences prefs,string path) {
      Backend.RejectLinks(Path.GetDirectoryName(path));
      if(!File.Exists(path))return null;
      if((File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0||new FileInfo(path).Length>16384)
        throw new IOException("La actualización pendiente necesita revisarse en el ordenador.");
      var intent=Backend.Json.Deserialize<SystemUpdateIntent>(File.ReadAllText(path));
      // A finished update does not bind a future library to this old intent.
      // Active records must still match the exact managed installation.
      if(intent!=null&&intent.Format==1&&intent.State=="completed"&&
        ProductVersion(intent.TargetVersion)&&
        intent.Attempts>=0&&intent.Attempts<=MaximumAutomaticAttempts&&!Matches(intent,prefs))return null;
      if(!Matches(intent,prefs))throw new IOException("La actualización pendiente pertenece a otra configuración. Compruébala en el ordenador.");
      if(!String.IsNullOrEmpty(intent.NextAttemptUtc)) {
        DateTime next;if(!DateTime.TryParse(intent.NextAttemptUtc,null,System.Globalization.DateTimeStyles.RoundtripKind,out next))
          throw new IOException("El registro de actualización pendiente está incompleto. Compruébalo en el ordenador.");
      }
      return intent;
    }
    static void Write(SystemUpdateIntent intent) {WriteAt(intent,IntentPath);}
    static void WriteAt(SystemUpdateIntent intent,string path) {
      Backend.PrivateDirectory(Path.GetDirectoryName(path));
      if(File.Exists(path)&&(File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0)
        throw new IOException("El registro de actualización no puede ser un enlace.");
      var temporary=path+"."+Guid.NewGuid().ToString("N")+".new";
      try {
        var bytes=new UTF8Encoding(false).GetBytes(Backend.Json.Serialize(intent));
        using(var output=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {
          output.Write(bytes,0,bytes.Length);output.Flush(true);
        }
        if(File.Exists(path))File.Replace(temporary,path,null);else File.Move(temporary,path);
      }finally{if(File.Exists(temporary))File.Delete(temporary);}
    }
    static SystemUpdateIntent NewIntent(Preferences prefs,string version) {
      if(prefs==null||!prefs.Managed||String.IsNullOrWhiteSpace(prefs.Installation)||
        String.IsNullOrWhiteSpace(prefs.ProjectName)||String.IsNullOrWhiteSpace(prefs.ReceiptPath))
        throw new IOException("Conecta y verifica tu biblioteca en el ordenador antes de actualizar.");
      return new SystemUpdateIntent{Format=1,TargetVersion=version,Installation=prefs.Installation,
        Project=prefs.ProjectName,ReceiptPath=prefs.ReceiptPath,State="pending",Attempts=0,NextAttemptUtc="",Error=""};
    }
    // Called by the new installer for both legacy remote upgrades and manual
    // repair. This durable intent precedes switching or launching the manager.
    public static void QueueFromInstaller(Preferences prefs) {
      if(prefs==null||!prefs.Managed)return;
      lock(Gate) {
        var old=Read(prefs);
        if(old!=null&&old.TargetVersion==Backend.Version&&(old.State=="pending"||old.State=="running")&&!old.RequiresLocalRecovery) {
          old.State="pending";old.NextAttemptUtc="";Write(old);return;
        }
        Write(NewIntent(prefs,Backend.Version));
      }
    }
    public static void ManagerInstalled(Preferences prefs) {
      if(prefs==null||!prefs.Managed)return;
      lock(Gate) {
        var intent=Read(prefs);
        if(intent==null||intent.TargetVersion!=Backend.Version)throw new IOException("Falta la continuación guardada de Inhouse Photos.");
        // Reset the retry budget only after the installer verified the new
        // active pointer. Failed manager swaps cannot reset their own budget.
        intent.State="pending";intent.Attempts=0;intent.NextAttemptUtc="";intent.Error="";intent.RequiresLocalRecovery=false;Write(intent);
      }
    }
    public static bool BlocksOperations(Preferences prefs) {
      if(IsBusy)return true;
      try{var intent=Read(prefs);return intent!=null&&intent.State!="completed";}catch{return true;}
    }
    public static SystemUpdateStatus Status() {
      lock(Gate) {
        var engine=RuntimeUpdates.Status();var manager=ManagerUpdates.Status();
        var visiblePhase=phase;var visibleProgress=progress;
        if(applying&&ManagerUpdates.IsApplying) {
          visiblePhase=manager.Phase=="ready"?"installing":manager.Phase;
          visibleProgress=Math.Max(1,Math.Min(20,manager.Progress/5));
        } else if(applying&&RuntimeUpdates.IsApplying) {
          visiblePhase=engine.Phase;visibleProgress=20+Math.Min(79,engine.Progress*79/100);
        }
        return new SystemUpdateStatus{CurrentVersion=confirmed?Backend.Version:"",LatestVersion=latest,
          Available=!requiresLocal&&(!confirmed||ManagerUpdates.Compare(latest,Backend.Version)>0),
          Phase=visiblePhase,Progress=visibleProgress,Error=error,Notes=Notes,
          RecoveryRequired=!confirmed&&(phase=="error"||phase=="waiting"),
          Busy=applying||ManagerUpdates.IsApplying||RuntimeUpdates.IsBusy,RequiresLocalRecovery=requiresLocal};
      }
    }
    public static async Task<SystemUpdateStatus> Check(Preferences prefs,bool force=false) {
      await CheckGate.WaitAsync();
      try {
        if(IsApplying)return Status();
        if(!force&&DateTime.UtcNow-checkedAt<TimeSpan.FromSeconds(15))return Status();
        SystemUpdateIntent intent;
        try{intent=Read(prefs);}catch(Exception ex){lock(Gate){confirmed=false;requiresLocal=true;phase="error";error=ex.Message;}return Status();}
        var manager=ManagerUpdates.Status();
        try{manager=await ManagerUpdates.Check(force);}catch{ /* The pinned engine can still complete during a catalogue outage. */ }
        bool installed=false;
        try{installed=await RuntimeUpdates.ConfirmInstalled(prefs);}catch{}
        RuntimeUpdateStatus engine=null;
        if(!installed)try{engine=await RuntimeUpdates.Check(prefs,force);}catch{}
        lock(Gate) {
          if(applying)return Status();
          latest=manager.Available?manager.LatestVersion:Backend.Version;confirmed=installed;
          checkedAt=DateTime.UtcNow;
          if(installed&&intent!=null&&intent.State!="completed"&&ManagerUpdates.Compare(intent.TargetVersion,Backend.Version)<=0) {
            intent.State="completed";intent.Error="";intent.NextAttemptUtc="";intent.RequiresLocalRecovery=false;Write(intent);
          }
          else if(Exhausted(intent))Write(intent);
          requiresLocal=intent!=null&&intent.RequiresLocalRecovery;
          if(installed&&(intent==null||intent.State=="completed")) {phase="idle";progress=100;error="";}
          else if(intent!=null&&intent.State!="completed") {
            phase=intent.State=="error"?"error":"waiting";error=intent.Error??"";
          } else if(!installed) {
            phase=engine!=null&&engine.RecoveryRequired?"waiting":"idle";
            error="";
          }
        }
        return Status();
      }finally{CheckGate.Release();}
    }
    public static async Task<SystemUpdateStatus> CheckSoon(Preferences prefs) {
      Task<SystemUpdateStatus> pending;
      lock(Gate) {
        if(checking==null||checking.IsCompleted) {
          checking=Task.Run(()=>Check(prefs));
          // Observe even when the HTTP client leaves before the full check.
          _=checking.ContinueWith(failed=>{
            var failure=failed.Exception;
            lock(Gate){if(!applying){phase="error";error="No se pudo completar la comprobación. Reintenta o comprueba Inhouse Photos en el ordenador.";}}
          },TaskContinuationOptions.OnlyOnFaulted);
        }
        pending=checking;
      }
      if(await Task.WhenAny(pending,Task.Delay(1500))==pending) {
        try{return await pending;}catch{return Status();}
      }
      return Status();
    }
    public static bool TryBegin(Preferences prefs,bool automatic=false) {
      lock(Gate) {
        if(applying||ManagerUpdates.IsApplying||RuntimeUpdates.IsBusy)return false;
        var intent=Read(prefs);
        if(automatic) {if(!Due(intent,DateTime.UtcNow))return false;}
        else {
          if(requiresLocal||(intent!=null&&intent.RequiresLocalRecovery))return false;
          if(confirmed&&ManagerUpdates.Compare(latest,Backend.Version)<=0&&(intent==null||intent.State=="completed"))return false;
          var target=intent!=null&&intent.State!="completed"&&ManagerUpdates.Compare(intent.TargetVersion,latest)>0?intent.TargetVersion:latest;
          intent=NewIntent(prefs,target);
        }
        intent.State="running";intent.Attempts++;
        intent.NextAttemptUtc=DateTime.UtcNow.AddSeconds(intent.Attempts==1?15:60).ToString("o");intent.Error="";
        Write(intent);applying=true;confirmed=false;phase="verifying";progress=0;error="";requiresLocal=false;checkedAt=DateTime.MinValue;return true;
      }
    }
    public static async Task Apply(Preferences prefs,Func<Task> installManager) {
      try {
        var manager=ManagerUpdates.Status();
        try{manager=await ManagerUpdates.Check(true);}catch{ /* Resume the locally pinned product when GitHub is temporarily unavailable. */ }
        if(manager.Available) {
          if(!ManagerUpdates.TryBegin())throw new IOException("Ya hay otra actualización en curso.");
          // The installer persists the continuation again before pointer swap.
          await installManager();return;
        }
        var intent=Read(prefs);
        if(intent!=null&&ManagerUpdates.Compare(intent.TargetVersion,Backend.Version)>0)
          throw new IOException("No se pudo comprobar la versión solicitada. La actualización queda guardada para reintentar.");
        if(!await RuntimeUpdates.ConfirmInstalled(prefs)) {
          var engine=await RuntimeUpdates.Check(prefs,true);
          if(!engine.Available) {
            lock(Gate)requiresLocal=true;
            throw new IOException("No se pudo verificar una actualización segura para esta biblioteca. Comprueba Inhouse Photos en el ordenador.");
          }
          if(!RuntimeUpdates.TryBegin())throw new IOException("El ordenador está terminando otra actualización. Vuelve a intentarlo.");
          await RuntimeUpdates.Apply(prefs);
        }
        if(!await RuntimeUpdates.ConfirmInstalled(prefs))
          throw new IOException("La actualización sigue pendiente de comprobarse. Tus fotos y el trabajo pendiente se conservan.");
        lock(Gate) {
          intent=Read(prefs);if(intent==null)throw new IOException("Falta la continuación guardada de la actualización.");
          intent.State="completed";intent.Error="";intent.NextAttemptUtc="";intent.RequiresLocalRecovery=false;Write(intent);
          confirmed=true;phase="completed";progress=100;error="";requiresLocal=false;
        }
      }catch(Exception ex) {
        lock(Gate) {
          phase="error";error=ex.Message;
          try{var intent=Read(prefs);if(intent!=null){intent.State="error";intent.Error=error;intent.RequiresLocalRecovery=requiresLocal;Write(intent);}}
          catch{requiresLocal=true;}
        }
        throw;
      }finally{lock(Gate)applying=false;}
    }
    public static int SelfTest() {
      var prefs=new Preferences{Managed=true,Installation=@"D:\photos",ProjectName="inhouse",ReceiptPath=@"C:\receipt.json"};
      var intent=NewIntent(prefs,Backend.Version);
      if(!Matches(intent,prefs)||!Due(intent,DateTime.UtcNow))return 1;
      intent.Installation=@"E:\photos";if(Matches(intent,prefs))return 2;intent.Installation=prefs.Installation;
      intent.Attempts=MaximumAutomaticAttempts;if(Due(intent,DateTime.UtcNow))return 3;
      intent.Attempts=0;intent.RequiresLocalRecovery=true;if(Due(intent,DateTime.UtcNow))return 4;
      intent.RequiresLocalRecovery=false;intent.State="completed";if(Due(intent,DateTime.UtcNow))return 5;
      intent.State="running";intent.NextAttemptUtc=DateTime.UtcNow.AddMinutes(1).ToString("o");if(Due(intent,DateTime.UtcNow))return 6;
      intent.NextAttemptUtc=DateTime.UtcNow.AddMinutes(-1).ToString("o");if(!Due(intent,DateTime.UtcNow))return 7;
      if(!RemoteManagement.Allowed("GET",RemoteManagement.SystemPath)||!RemoteManagement.Allowed("POST",RemoteManagement.SystemPath)||
        RemoteManagement.Allowed("POST",RemoteManagement.SystemPath+"?version=other")||
        RemoteManagement.ReadOnlyBrowserToken("POST",RemoteManagement.SystemPath,"immich_access_token="+new string('A',43))!=null)return 8;
      return 0;
    }
    public static int VerifyIntent() {
      var directory=Path.Combine(Path.GetTempPath(),"inhouse-system-intent-"+Guid.NewGuid().ToString("N"));
      try {
        var path=Path.Combine(directory,"system-update.json");
        var prefs=new Preferences{Managed=true,Installation=@"D:\photos",ProjectName="inhouse",ReceiptPath=@"C:\receipt.json"};
        WriteAt(NewIntent(prefs,Backend.Version),path);
        var pending=ReadAt(prefs,path);
        if(!Due(pending,DateTime.UtcNow)||pending.TargetVersion!=Backend.Version)return 1;
        pending.State="running";pending.Attempts=1;pending.NextAttemptUtc=DateTime.UtcNow.AddMinutes(-1).ToString("o");WriteAt(pending,path);
        // Reloading a running record models restart after receipt loss: the
        // intent remains eligible, with the previous attempt still counted.
        var restarted=ReadAt(prefs,path);
        if(!Due(restarted,DateTime.UtcNow)||restarted.Attempts!=1)return 2;
        restarted.Attempts=MaximumAutomaticAttempts;restarted.State="running";WriteAt(restarted,path);
        if(Due(ReadAt(prefs,path),DateTime.UtcNow))return 3;
        if(!Exhausted(restarted)||restarted.State!="error"||String.IsNullOrEmpty(restarted.Error))return 7;
        WriteAt(restarted,path);
        var changed=new Preferences{Managed=true,Installation=@"E:\other",ProjectName=prefs.ProjectName,ReceiptPath=prefs.ReceiptPath};
        try{ReadAt(changed,path);return 4;}catch(IOException){}
        restarted.State="completed";WriteAt(restarted,path);
        if(Due(ReadAt(prefs,path),DateTime.UtcNow)||Directory.GetFiles(directory,"*.new").Length!=0)return 5;
        return 0;
      }catch(Exception ex){Console.Error.WriteLine(ex.Message);return 6;}
      finally{try{if(Directory.Exists(directory))Directory.Delete(directory,true);}catch{}}
    }
  }
}
