using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Collections.Generic;
using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace InhousePhotos {
  public sealed class ServerContainer {
    public string Id {get;set;}
    public string Image {get;set;}
    public string Service {get;set;}
    public string Project {get;set;}
    public ServerMount[] Mounts {get;set;}
  }
  public sealed class ServerMount {
    public string Type {get;set;}
    public string Name {get;set;}
    public string Source {get;set;}
    public string Destination {get;set;}
    public string Driver {get;set;}
    public string Mode {get;set;}
    public bool RW {get;set;}
    public string Propagation {get;set;}
  }
  public sealed class AdoptionReceipt {
    public string Version {get;set;}
    public string CompletedUtc {get;set;}
    public string Snapshot {get;set;}
    public string SnapshotSha256 {get;set;}
    public string Counts {get;set;}
    public bool RestoreVerified {get;set;}
    public Preferences PreviousPreferences {get;set;}
    public List<ServerContainer> Containers {get;set;}
    public Dictionary<string,string> ConfigurationHashes {get;set;}
  }
  public static partial class Backend {
    public const string Version="1.0.1";
    public const string DockerContext="--context desktop-linux ";
    static readonly SemaphoreSlim ServerLock=new SemaphoreSlim(1,1);
    public static readonly string InstallDir=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),@"Programs\Inhouse Photos Server");
    public static string Launcher {get{return Path.Combine(InstallDir,"Inhouse Photos.exe");}}
    public static void PrivateDirectory(string path) {
      RejectLinks(path);
      Directory.CreateDirectory(path);
      var acl=new DirectorySecurity();acl.SetAccessRuleProtection(true,false);
      foreach(var sid in new[]{WindowsIdentity.GetCurrent().User,new SecurityIdentifier(WellKnownSidType.LocalSystemSid,null),new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid,null)})
        acl.AddAccessRule(new FileSystemAccessRule(sid,FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
      new DirectoryInfo(path).SetAccessControl(acl);
    }
    public static string Hash(string path) {using(var s=File.OpenRead(path))using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(s)).Replace("-","").ToLowerInvariant();}
    public static string RandomHex(int bytes) {var data=new byte[bytes];using(var rng=RandomNumberGenerator.Create())rng.GetBytes(data);return BitConverter.ToString(data).Replace("-","").ToLowerInvariant();}
    public static string ComposeArgs(Preferences p,string args) {
      if(!String.IsNullOrEmpty(p.ProjectName)&&!Regex.IsMatch(p.ProjectName,"^[a-z0-9][a-z0-9_-]*$"))throw new InvalidOperationException("Identidad del servidor no válida.");
      return DockerContext+"compose --project-directory "+Quote(p.Installation)+" -f "+Quote(Path.Combine(p.Installation,"docker-compose.yml"))+
        (String.IsNullOrEmpty(p.ProjectName)?"":" --project-name "+p.ProjectName)+" "+args;
    }
    public static Task<string> Docker(string args,int seconds) {return Run(DockerExe(),DockerContext+args,Environment.SystemDirectory,seconds);}
    public static Task<string> PowerShell(string script,int seconds) {
      return Run(Path.Combine(Environment.SystemDirectory,@"WindowsPowerShell\v1.0\powershell.exe"),"-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand "+Convert.ToBase64String(Encoding.Unicode.GetBytes("$ErrorActionPreference='Stop'; "+script)),Environment.SystemDirectory,seconds);
    }
    public static string PsString(string value) {return "'"+value.Replace("'","''")+"'";}
    public static string Argument(string value) {
      var result=new StringBuilder("\"");var slashes=0;
      foreach(var c in value){if(c=='\\'){slashes++;continue;}if(c=='"'){result.Append('\\',slashes*2+1);result.Append(c);}else{result.Append('\\',slashes);result.Append(c);}slashes=0;}
      result.Append('\\',slashes*2);result.Append('"');return result.ToString();
    }
    public static Dictionary<string,string> ConfigurationHashes(Preferences p) {
      var hashes=new Dictionary<string,string>();
      foreach(var name in new[]{"docker-compose.yml",".env","Caddyfile"}) {var path=Path.Combine(p.Installation,name);if(File.Exists(path)){RejectLinks(Path.GetDirectoryName(path));if((File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0)throw new IOException("La configuración no puede ser un enlace.");hashes[name]=Hash(path);}}
      if(!hashes.ContainsKey("docker-compose.yml")||!hashes.ContainsKey(".env"))throw new IOException("Falta la configuración del servidor.");
      return hashes;
    }
    public static async Task<List<ServerContainer>> InspectServer(Preferences p) {
      var ids=(await Compose(p,"ps -a -q",20)).Split(new[]{'\r','\n'},StringSplitOptions.RemoveEmptyEntries);
      if(ids.Length==0||ids.Any(id=>!Regex.IsMatch(id,"^[a-f0-9]{64}$")))throw new InvalidOperationException("No se encuentran los contenedores existentes. No se creará una biblioteca vacía.");
      // Restrict inspect to identity and mounts: never serialize container Env.
      var format="{\"Id\":{{json .Id}},\"Image\":{{json .Image}},\"Service\":{{json (index .Config.Labels \"com.docker.compose.service\")}},\"Project\":{{json (index .Config.Labels \"com.docker.compose.project\")}},\"Mounts\":{{json .Mounts}}}";
      var lines=await Docker("inspect "+String.Join(" ",ids)+" --format "+Argument(format),25);
      var rows=lines.Split(new[]{'\r','\n'},StringSplitOptions.RemoveEmptyEntries).Select(line=>Json.Deserialize<ServerContainer>(line)).OrderBy(r=>r.Service).ToList();
      if(!rows.Any(r=>r.Service=="immich-server")||!rows.Any(r=>r.Service=="database")||rows.Select(r=>r.Project).Distinct().Count()!=1)throw new InvalidOperationException("La instalación no contiene una biblioteca y base de datos compatibles.");
      return rows;
    }
    public static void AssertIdentity(List<ServerContainer> before,List<ServerContainer> after) {
      // Docker does not guarantee mount enumeration order. Compare canonical
      // typed records, retaining all storage identity and access attributes.
      var left=before.OrderBy(r=>r.Id,StringComparer.Ordinal).ToArray();
      var right=after.OrderBy(r=>r.Id,StringComparer.Ordinal).ToArray();
      bool equal=left.Length==right.Length;
      for(int i=0;equal&&i<left.Length;i++) {
        var a=left[i];var b=right[i];
        equal=a.Id==b.Id&&a.Image==b.Image&&a.Service==b.Service&&a.Project==b.Project;
        var am=(a.Mounts??new ServerMount[0]).OrderBy(m=>m.Destination,StringComparer.Ordinal).ToArray();
        var bm=(b.Mounts??new ServerMount[0]).OrderBy(m=>m.Destination,StringComparer.Ordinal).ToArray();
        equal=equal&&am.Length==bm.Length;
        for(int j=0;equal&&j<am.Length;j++) {
          var x=am[j];var y=bm[j];
          equal=x.Type==y.Type&&x.Name==y.Name&&x.Source==y.Source&&x.Destination==y.Destination&&x.Driver==y.Driver&&x.Mode==y.Mode&&x.RW==y.RW&&x.Propagation==y.Propagation;
        }
      }
      if(!equal)throw new InvalidOperationException("La identidad o los discos del servidor han cambiado. Se ha detenido la vinculación para proteger la biblioteca.");
    }
    public static void ValidateManagedConfiguration(Preferences p) {
      Library(p);
      if(!p.Managed||String.IsNullOrEmpty(p.ReceiptPath))throw new InvalidOperationException("Completa primero la vinculación segura del servidor.");
      var receipt=Json.Deserialize<AdoptionReceipt>(File.ReadAllText(p.ReceiptPath));
      if(!receipt.RestoreVerified)throw new InvalidOperationException("La copia de migración no está verificada.");
      var hashes=ConfigurationHashes(p);
      if(receipt.ConfigurationHashes.Count!=hashes.Count||receipt.ConfigurationHashes.Any(x=>!hashes.ContainsKey(x.Key)||hashes[x.Key]!=x.Value))
        throw new InvalidOperationException("La configuración ha cambiado desde la vinculación. Vuelve a verificarla antes de iniciar servicios.");
    }
    static Process StartIo(string args,bool input,bool output) {
      var process=new Process {StartInfo=new ProcessStartInfo(DockerExe(),DockerContext+args) {UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden,RedirectStandardInput=input,RedirectStandardOutput=output,RedirectStandardError=true,WorkingDirectory=Environment.SystemDirectory}};
      process.Start();return process;
    }
    static async Task FinishProcess(Process process,Task<string> error,int seconds) {
      if(!await Task.Run(()=>process.WaitForExit(seconds*1000))){try{process.Kill();}catch{}throw new TimeoutException("La operación no confirmó su final. Se conserva el archivo parcial para diagnóstico.");}
      await error;if(process.ExitCode!=0)throw new IOException("La operación de base de datos no se completó; la copia no se considera válida.");
    }
    const string CountSql="SELECT (SELECT count(*) FROM public.asset)::text || '|' || (SELECT count(*) FROM public.\"user\")::text || '|' || (SELECT count(*) FROM public.album)::text;";
    static string PsqlArgs(string id) {return "exec -i "+id+" sh -c "+Quote("exec psql --username=$POSTGRES_USER --dbname=$POSTGRES_DB --no-psqlrc -qAt -v ON_ERROR_STOP=1");}
    public static async Task<string> ExportConsistentSnapshot(string databaseId,string file) {
      using(var session=StartIo(PsqlArgs(databaseId),true,true)) {
        var error=session.StandardError.ReadToEndAsync();session.StandardInput.AutoFlush=true;
        try {
          await session.StandardInput.WriteLineAsync("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; SELECT pg_export_snapshot();");
          var snapshot=await ReadLineDeadline(session.StandardOutput,30);
          if(!Regex.IsMatch(snapshot??"","^[A-Fa-f0-9-]+$"))throw new IOException("No se pudo fijar una instantánea coherente.");
          await session.StandardInput.WriteLineAsync(CountSql);
          var counts=await ReadLineDeadline(session.StandardOutput,30);
          if(!Regex.IsMatch(counts??"","^[0-9]+\\|[0-9]+\\|[0-9]+$"))throw new IOException("No se pudo verificar el inventario.");
          using(var dump=StartIo("exec "+databaseId+" sh -c "+Quote("exec pg_dump --username=$POSTGRES_USER --dbname=$POSTGRES_DB --format=custom --no-owner --no-acl --snapshot="+snapshot),false,true)) {
            var dumpError=dump.StandardError.ReadToEndAsync();
            using(var output=new FileStream(file+".partial",FileMode.CreateNew,FileAccess.Write,FileShare.None,65536,true)) {
              var copy=dump.StandardOutput.BaseStream.CopyToAsync(output);
              if(await Task.WhenAny(copy,Task.Delay(TimeSpan.FromMinutes(15)))!=copy){try{dump.Kill();}catch{}throw new TimeoutException("La copia de migración no terminó a tiempo.");}
              await copy;
            }
            await FinishProcess(dump,dumpError,30);
          }
          File.Move(file+".partial",file);return counts;
        } finally {
          try{await session.StandardInput.WriteLineAsync("ROLLBACK;");session.StandardInput.Close();await FinishProcess(session,error,10);}catch{try{session.Kill();}catch{}}
        }
      }
    }
    static async Task<string> ReadLineDeadline(StreamReader reader,int seconds) {var read=reader.ReadLineAsync();if(await Task.WhenAny(read,Task.Delay(seconds*1000))!=read)throw new TimeoutException("La base de datos no respondió a tiempo.");return await read;}
    public static async Task VerifyRestore(string dump,string image,string expectedCounts,Action<string> progress) {
      var token=Guid.NewGuid().ToString("N");var name="inhouse-restore-check-"+token;var volume=name+"-data";
      var envDir=Path.Combine(SettingsDir,"verification",token);PrivateDirectory(envDir);var envFile=Path.Combine(envDir,"database.env");
      File.WriteAllText(envFile,"POSTGRES_USER=postgres\nPOSTGRES_DB=immich\nPOSTGRES_PASSWORD="+RandomHex(24)+"\n",new UTF8Encoding(false));
      string id=null;bool volumeCreated=false;
      try {
        await Docker("volume create --label inhouse.restore-test="+token+" "+volume,20);volumeCreated=true;
        id=(await Docker("run -d --name "+name+" --label inhouse.restore-test="+token+" --network none --memory 2g --cpus 2 --mount type=volume,source="+volume+",destination=/var/lib/postgresql/data --env-file "+Quote(envFile)+" "+image,60)).Trim();
        if(!Regex.IsMatch(id,"^[a-f0-9]{64}$"))throw new IOException("No se pudo identificar la instancia de prueba.");
        bool ready=false;
        for(int i=0;i<60;i++){try{await Docker("exec "+id+" pg_isready -U postgres -d immich",8);ready=true;break;}catch{await Task.Delay(2000);}}
        if(!ready)throw new IOException("La base de datos de prueba no está lista.");
        progress("Restaurando la copia en una base de datos aislada…");
        await Docker("cp "+Quote(dump)+" "+id+":/tmp/inhouse.dump",120);
        await Docker("exec "+id+" pg_restore -U postgres -d immich --no-owner --no-acl --exit-on-error --jobs=2 /tmp/inhouse.dump",900);
        using(var query=StartIo(PsqlArgs(id),true,true)) {
          var error=query.StandardError.ReadToEndAsync();var result=query.StandardOutput.ReadToEndAsync();
          await query.StandardInput.WriteLineAsync(CountSql);query.StandardInput.Close();await FinishProcess(query,error,30);
          if((await result).Trim()!=expectedCounts)throw new IOException("El inventario restaurado no coincide con la instantánea original.");
        }
      } finally {
        // Only these labelled, randomly named test resources can be removed.
        // No production volume, image, container or library path is deleted.
        if(id!=null&&Regex.IsMatch(id,"^[a-f0-9]{64}$")) {
          var actual=(await Docker("inspect --format "+Quote("{{index .Config.Labels `inhouse.restore-test`}}")+" "+id,15)).Trim();
          if(actual==token)await Docker("rm --force "+id,30);
        }
        if(volumeCreated) {
          var actual=(await Docker("volume inspect --format "+Quote("{{index .Labels `inhouse.restore-test`}}")+" "+volume,15)).Trim();
          if(actual==token)await Docker("volume rm "+volume,30);
        }
        if(File.Exists(envFile))File.Delete(envFile);
      }
    }
    public static async Task<AdoptionReceipt> Adopt(Preferences p,Action<string> progress) {
      await ServerLock.WaitAsync();
      try {
        await EnsureEngine(progress);
        if(p.Managed) {
          progress("Comprobando tu conexión guardada…");
          ValidateManagedConfiguration(p);
          var existing=Json.Deserialize<AdoptionReceipt>(File.ReadAllText(p.ReceiptPath));
          AssertIdentity(existing.Containers,await InspectServer(p));
          if(!File.Exists(existing.Snapshot)||Hash(existing.Snapshot)!=existing.SnapshotSha256)throw new IOException("La copia de verificación no está disponible. Revisa el disco donde se guardó.");
          progress("Tu servidor ya está vinculado. No hace falta volver a migrarlo.");
          return existing;
        }
        progress("Comprobando biblioteca, cuentas y discos actuales…");Library(p);
        var previous=Json.Deserialize<Preferences>(Json.Serialize(p));var hashes=ConfigurationHashes(p);var before=await InspectServer(p);
        var project=before[0].Project;if(!Regex.IsMatch(project??"","^[a-z0-9][a-z0-9_-]*$"))throw new IOException("Identidad del servidor no válida.");
        var directory=Path.Combine(SettingsDir,"migrations",DateTime.UtcNow.ToString("yyyyMMdd-HHmmss")+"-"+RandomHex(4));PrivateDirectory(directory);
        foreach(var file in hashes.Keys)File.WriteAllBytes(Path.Combine(directory,file+".dpapi"),ProtectedData.Protect(File.ReadAllBytes(Path.Combine(p.Installation,file)),null,DataProtectionScope.CurrentUser));
        var dump=Path.Combine(directory,"library.dump");var db=before.Single(r=>r.Service=="database");
        progress("Guardando una instantánea coherente sin detener las subidas…");
        var counts=await ExportConsistentSnapshot(db.Id,dump);
        await VerifyRestore(dump,db.Image,counts,progress);
        var after=await InspectServer(p);
        File.WriteAllText(Path.Combine(directory,"identity-before.json"),Json.Serialize(before));
        File.WriteAllText(Path.Combine(directory,"identity-after.json"),Json.Serialize(after));
        AssertIdentity(before,after);
        var afterHashes=ConfigurationHashes(p);if(hashes.Any(x=>!afterHashes.ContainsKey(x.Key)||afterHashes[x.Key]!=x.Value))throw new IOException("La configuración cambió durante la comprobación. Vuelve a intentarlo.");
        var receipt=new AdoptionReceipt{Version=Version,CompletedUtc=DateTime.UtcNow.ToString("o"),Snapshot=dump,SnapshotSha256=Hash(dump),Counts=counts,RestoreVerified=true,PreviousPreferences=previous,Containers=before,ConfigurationHashes=hashes};
        var path=Path.Combine(directory,"receipt.json");File.WriteAllText(path,Json.Serialize(receipt),new UTF8Encoding(false));
        p.ProjectName=project;p.ReceiptPath=path;p.Managed=true;Save(p);
        progress("Vinculación verificada. Se conservan las fotos, cuentas y dirección del servidor.");return receipt;
      } finally {ServerLock.Release();}
    }
    public static async Task StartManaged(Preferences p,Action<string> progress) {
      await ServerLock.WaitAsync();
      try {
        ValidateManagedConfiguration(p);
        var receipt=Json.Deserialize<AdoptionReceipt>(File.ReadAllText(p.ReceiptPath));
        await EnsureEngine(progress);
        AssertIdentity(receipt.Containers,await InspectServer(p));
        if(await Ping(p.LocalEndpoint))return;
        progress("Iniciando la biblioteca existente…");
        await Compose(p,"start",180);
        for(int i=0;i<60;i++){if(await Ping(p.LocalEndpoint))return;await Task.Delay(3000);}
        throw new IOException("El motor está disponible, pero la biblioteca no responde todavía. No se han recreado contenedores ni discos.");
      } finally {ServerLock.Release();}
    }
    public static async Task EnsureEngine(Action<string> progress) {
      try{await Docker("info",10);return;}catch{}
      var engine=Path.GetFullPath(Path.Combine(Path.GetDirectoryName(DockerExe()),@"..\..\Docker Desktop.exe"));
      if(!File.Exists(engine))throw new IOException("Falta el motor del servidor.");
      progress("Preparando el motor en segundo plano…");
      Process.Start(new ProcessStartInfo(engine,"--minimized"){UseShellExecute=true,WindowStyle=ProcessWindowStyle.Hidden});
      for(int i=0;i<60;i++){await Task.Delay(3000);try{await Docker("info",8);return;}catch{}}
      throw new IOException("El motor no ha arrancado. Comprueba si Windows solicita un reinicio.");
    }
  }
}
