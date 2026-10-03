using System;
using System.Collections.Generic;
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
  internal sealed class PublicWindowsDownload {
    public string Version {get;set;}
    public string InstallerUrl {get;set;}
    public string Sha256 {get;set;}
    public string FullInstallerUrl {get;set;}
    public string FullInstallerSha256 {get;set;}
  }
  internal sealed class PublicAndroidDownload {
    public string version {get;set;}
    public string apkUrl {get;set;}
    public string sha256 {get;set;}
  }
  internal sealed class PublicDownloadCatalogue {
    public PublicWindowsDownload windows {get;set;}
    public PublicAndroidDownload android {get;set;}
  }
  /// Publish public download resources to the existing, verified Caddy storage.
  /// This never changes Compose, Caddy configuration, the library or accounts.
  public static class PublicDownloads {
    internal const string Root="/data/inhouse-downloads";
    internal const string Callback="window.InhousePhotosDownloads.applyLatest(";
    const string Repository="https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/";
    const string ManifestRoot="https://raw.githubusercontent.com/miguelcoxcaballero/Inhouse-Photos/main/";
    static readonly Dictionary<string,string> OriginalHashes=new Dictionary<string,string>(StringComparer.Ordinal) {
      {"index.html","721352063b63598ec4973fc06e40775e16bdacfed1009d110ae5de78bf76967f"},
      {"style.css","e49cfe1d9a82f1d13263101ab11cd3b5f1f5d469da6d8ee4038f6fdbaa372bca"},
      {"mark.svg","786d5f0e5a9b494be006eaaeb8bf835a6e55136ea807e6bd2aabed332b9f1596"},
      {"privacidad/index.html","323cacff53829024b3a7aeb4e7ba8508079b7014b9b5a9339ccc4ae544b6928a"},
      {"servidor/index.html","1291ecbdf40ee73dfaa84b83ae932183b2e9563b75e013576405eb07f9a3bce5"},
      {"servidor/usb.css","90b4b1a5650c3d956bc8d71f49a624a382cfc4e82dc3d32b1c7e1a07a3993e4d"},
      {"servidor/usb.js","9c0b3915bfe0f0d865ca766c3bca579e16fa38e6395cc3111b676db858a31f79"}
    };
    internal static readonly string[] OwnedFiles={"index.html","style.css","mark.svg","downloads.js","download-catalogue.js","privacidad/index.html","servidor/index.html","servidor/usb.css","servidor/usb.js"};
    static readonly SemaphoreSlim Gate=new SemaphoreSlim(1,1);
    static string lastKey;
    static DateTime nextCheckUtc=DateTime.MinValue;
    static string StateDirectory {get{return Path.Combine(Backend.SettingsDir,"public-downloads");}}

    public static async Task Publish(Preferences prefs,bool force=false) {
      if(prefs==null||!prefs.Managed||String.IsNullOrWhiteSpace(prefs.Installation))return;
      var snapshot=Backend.Json.Deserialize<Preferences>(Backend.Json.Serialize(prefs));
      await Gate.WaitAsync();
      try {
        var key=snapshot.Installation+"\n"+snapshot.ProjectName+"\n"+snapshot.ReceiptPath;
        if(!force&&key==lastKey&&DateTime.UtcNow<nextCheckUtc)return;
        lastKey=key;nextCheckUtc=DateTime.UtcNow.AddMinutes(1);
        using(var resource=Assembly.GetExecutingAssembly().GetManifestResourceStream("InhousePhotos.public-downloads.zip")) {
          if(resource==null)throw new IOException("Falta el paquete público de descargas.");
          var bundle=ReadBundle(resource);
          var catalogue=ParseCatalogue(Encoding.UTF8.GetString(bundle["download-catalogue.js"]));
          var caddy=await CheckedCaddy(snapshot);
          if(caddy==null)return; // No recognised public route: do not create one.
          Backend.PrivateDirectory(StateDirectory);
          var stateKey=Digest(Encoding.UTF8.GetBytes(key));
          var cache=Path.Combine(StateDirectory,stateKey+"-catalogue.js");
          if(File.Exists(cache)&&(File.GetAttributes(cache)&FileAttributes.ReparsePoint)==0&&new FileInfo(cache).Length<=16384)
            try{catalogue=Merge(catalogue,ParseCatalogue(File.ReadAllText(cache)));}catch(IOException){}
          try {
            var published=await ReadPublicFile(caddy.Id,"download-catalogue.js",16384);
            if(published!=null)catalogue=Merge(catalogue,ParseCatalogue(published));
          }catch(IOException) { /* An old page may not have a catalogue yet. */ }
          var refreshed=await Task.WhenAll(FetchManifest("windows-server-update.json"),FetchManifest("android-update.json"));
          var latest=new PublicDownloadCatalogue();
          if(refreshed[0]!=null)try{latest.windows=Backend.Json.Deserialize<PublicWindowsDownload>(refreshed[0]);}catch{}
          if(refreshed[1]!=null)try{latest.android=Backend.Json.Deserialize<PublicAndroidDownload>(refreshed[1]);}catch{}
          if(Valid(latest.windows))catalogue.windows=Newer(catalogue.windows,latest.windows);
          if(Valid(latest.android))catalogue.android=Newer(catalogue.android,latest.android);
          bundle["download-catalogue.js"]=Encoding.UTF8.GetBytes(Document(catalogue));
          bundle["index.html"]=Encoding.UTF8.GetBytes(RefreshHtml(Encoding.UTF8.GetString(bundle["index.html"]),catalogue,true));
          bundle["servidor/index.html"]=Encoding.UTF8.GetBytes(RefreshHtml(Encoding.UTF8.GetString(bundle["servidor/index.html"]),catalogue,false));
          var preserved=await PublishBundle(snapshot,caddy,bundle,stateKey);
          SaveAtomic(cache,Document(catalogue));
          nextCheckUtc=DateTime.UtcNow.AddMinutes(10);
          RecordDiagnostic(preserved==0?"files-verified":"files-verified-custom-files-preserved");
        }
      }catch {
        // Diagnostics are intentionally fixed, public-safe codes. Docker output
        // and exceptions can contain paths/configuration and are never saved.
        RecordDiagnostic("publication-unconfirmed");
        throw;
      }finally {Gate.Release();}
    }

    internal static Dictionary<string,byte[]> ReadBundle(Stream input) {
      var result=new Dictionary<string,byte[]>(StringComparer.Ordinal);long total=0;
      using(var zip=new ZipArchive(input,ZipArchiveMode.Read,true)) {
        foreach(var entry in zip.Entries) {
          if(!OwnedFiles.Contains(entry.FullName,StringComparer.Ordinal)||result.ContainsKey(entry.FullName)||
             entry.Length<=0||entry.Length>131072)throw new IOException("El paquete público no es válido.");
          total+=entry.Length;if(total>524288)throw new IOException("El paquete público es demasiado grande.");
          using(var stream=entry.Open())using(var output=new MemoryStream()) {
            var buffer=new byte[4096];int count;
            while((count=stream.Read(buffer,0,buffer.Length))>0) {
              if(output.Length+count>131072)throw new IOException("El recurso público es demasiado grande.");
              output.Write(buffer,0,count);
            }
            if(output.Length!=entry.Length)throw new IOException("El recurso público está incompleto.");
            result.Add(entry.FullName,output.ToArray());
          }
        }
      }
      if(result.Count!=OwnedFiles.Length)throw new IOException("El paquete público está incompleto.");
      return result;
    }
    internal static bool ValidVersion(string value) {
      Version parsed;return Regex.IsMatch(value??"",@"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")&&Version.TryParse(value,out parsed);
    }
    internal static bool Valid(PublicWindowsDownload value) {
      return value!=null&&ValidVersion(value.Version)&&Regex.IsMatch(value.Sha256??"","^[a-f0-9]{64}$")&&
        value.InstallerUrl==Repository+"server-v"+value.Version+"/Inhouse-Photos-Server-Setup.exe"&&
        ((value.FullInstallerUrl==null&&value.FullInstallerSha256==null)||
         (value.FullInstallerUrl==Repository+"server-v"+value.Version+"/Inhouse-Photos-Server-Full-Setup.exe"&&
          Regex.IsMatch(value.FullInstallerSha256??"",@"\A[a-f0-9]{64}\z")));
    }
    internal static string PreferredWindowsUrl(PublicWindowsDownload value) {
      if(!Valid(value))throw new IOException("La descarga de Windows no es válida.");
      return value.FullInstallerUrl??value.InstallerUrl;
    }
    internal static bool Valid(PublicAndroidDownload value) {
      return value!=null&&ValidVersion(value.version)&&Regex.IsMatch(value.sha256??"","^[a-f0-9]{64}$")&&
        Regex.IsMatch(value.apkUrl??"","^"+Regex.Escape(Repository+"v"+value.version)+@"(?:-[A-Za-z0-9._-]+)?/Inhouse-Photos\.apk$");
    }
    internal static PublicDownloadCatalogue ParseCatalogue(string text) {
      text=(text??"").Trim();
      if(text.Length>16384||!text.StartsWith(Callback,StringComparison.Ordinal)||!text.EndsWith(");",StringComparison.Ordinal))
        throw new IOException("El catálogo público no es válido.");
      PublicDownloadCatalogue result;
      try{result=Backend.Json.Deserialize<PublicDownloadCatalogue>(text.Substring(Callback.Length,text.Length-Callback.Length-2));}
      catch{throw new IOException("El catálogo público no es válido.");}
      if(result==null||!Valid(result.windows)||!Valid(result.android))throw new IOException("El catálogo público no es válido.");
      return result;
    }
    internal static string Document(PublicDownloadCatalogue value) {
      if(value==null||!Valid(value.windows)||!Valid(value.android))throw new IOException("El catálogo público no es válido.");
      return Callback+Backend.Json.Serialize(value)+");\n";
    }
    static PublicWindowsDownload Newer(PublicWindowsDownload a,PublicWindowsDownload b) {
      var comparison=Version.Parse(b.Version).CompareTo(Version.Parse(a.Version));
      // A newly verified full installer may enrich a catalogue at the same
      // product version. An old compact catalogue must not undo that choice.
      return comparison>0||(comparison==0&&a.FullInstallerUrl==null&&b.FullInstallerUrl!=null)?b:a;
    }
    static PublicAndroidDownload Newer(PublicAndroidDownload a,PublicAndroidDownload b) {return Version.Parse(b.version)>Version.Parse(a.version)?b:a;}
    internal static PublicDownloadCatalogue Merge(PublicDownloadCatalogue a,PublicDownloadCatalogue b) {
      return new PublicDownloadCatalogue{windows=Newer(a.windows,b.windows),android=Newer(a.android,b.android)};
    }
    internal static string RefreshHtml(string html,PublicDownloadCatalogue catalogue,bool landing) {
      if(catalogue==null||!Valid(catalogue.windows)||!Valid(catalogue.android))throw new IOException("El catálogo público no es válido.");
      foreach(var platform in new[]{"windows","android"}) {
        if(!landing&&platform=="android")continue;
        var url=platform=="windows"?PreferredWindowsUrl(catalogue.windows):catalogue.android.apkUrl;
        var version=platform=="windows"?catalogue.windows.Version:catalogue.android.version;
        var anchor=new Regex("(<a\\b[^>]*\\bdata-download=\""+platform+"\"[^>]*\\bhref=\")[^\"]*(\")");
        if(anchor.Matches(html).Count!=1)throw new IOException("Falta el enlace de descarga verificado.");
        html=anchor.Replace(html,m=>m.Groups[1].Value+url+m.Groups[2].Value);
        html=Regex.Replace(html,"(<a\\b[^>]*\\bdata-download=\""+platform+"\"[^>]*\\bdata-version=\")[^\"]*(\")",m=>m.Groups[1].Value+version+m.Groups[2].Value);
        if(!landing)continue;
        html=Regex.Replace(html,"(<small\\b[^>]*\\bdata-download-version=\""+platform+"\"[^>]*>)[^<]*(</small>)",m=>m.Groups[1].Value+
          (platform=="windows"?"Windows 10 y 11 · Versión ":"Android 8 o posterior · ARM64 · Versión ")+version+
          (platform=="windows"&&catalogue.windows.FullInstallerUrl!=null?" · Instalación completa":"")+m.Groups[2].Value);
        var checksum=url.Substring(0,url.LastIndexOf('/')+1)+"SHA256SUMS.txt";
        html=Regex.Replace(html,"(<a\\b[^>]*\\bdata-download-checksum=\""+platform+"\"[^>]*\\bhref=\")[^\"]*(\")",m=>m.Groups[1].Value+checksum+m.Groups[2].Value);
      }
      return html;
    }
    static async Task<string> FetchManifest(string name) {
      try {
        ServicePointManager.SecurityProtocol|=SecurityProtocolType.Tls12;
        var url=ManifestRoot+name;var request=(HttpWebRequest)WebRequest.Create(url);
        request.Method="GET";request.Timeout=8000;request.ReadWriteTimeout=8000;request.AllowAutoRedirect=false;
        request.Headers[HttpRequestHeader.CacheControl]="no-cache";
        using(var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(8)))using(deadline.Token.Register(()=>request.Abort()))
        using(var response=(HttpWebResponse)await request.GetResponseAsync()) {
          if(response.StatusCode!=HttpStatusCode.OK||response.ResponseUri.AbsoluteUri!=url||response.ContentLength>16384)return null;
          using(var input=response.GetResponseStream())using(var output=new MemoryStream()) {
            var buffer=new byte[4096];int count;
            while((count=await input.ReadAsync(buffer,0,buffer.Length))>0){if(output.Length+count>16384)return null;output.Write(buffer,0,count);}
            return Encoding.UTF8.GetString(output.ToArray());
          }
        }
      }catch {return null;} // Verified embedded/cached catalogue stays available offline.
    }
    internal static bool HasDownloadsRoute(string source) {
      if(source==null)return false;
      // Ignore comment-only lines and locate the one already configured route.
      var text=Regex.Replace(source,@"(?m)^\s*#[^\r\n]*","");
      var matches=Regex.Matches(text,@"(?m)^[ \t]*handle_path[ \t]+/descargas/\*[ \t]*\{");
      if(matches.Count!=1)return false;
      var start=matches[0].Index+matches[0].Length;int depth=1;bool quoted=false,escaped=false,comment=false;int end=start;
      for(;end<text.Length;end++) {
        var c=text[end];
        if(comment){if(c=='\n')comment=false;continue;}
        if(quoted){if(escaped)escaped=false;else if(c=='\\')escaped=true;else if(c=='"')quoted=false;continue;}
        if(c=='#'){comment=true;continue;}if(c=='"'){quoted=true;continue;}
        if(c=='{')depth++;else if(c=='}'&&--depth==0)break;
      }
      if(depth!=0)return false;
      var block=text.Substring(start,end-start);
      return Regex.Matches(block,@"(?m)^[ \t]*root[ \t]+\*[ \t]+/data/inhouse-downloads[ \t]*\r?$").Count==1&&
        Regex.Matches(block,@"(?m)^[ \t]*root[ \t]+").Count==1&&
        Regex.IsMatch(block,@"(?m)^[ \t]*file_server[ \t]*\r?$")&&
        !Regex.IsMatch(block,@"(?m)^[ \t]*(rewrite|reverse_proxy|redir|handle|handle_path|route|import|uri|try_files)[ \t]+");
    }
    internal static bool WritablePath(ServerContainer caddy,string path) {
      if(caddy==null||caddy.Mounts==null)return false;
      var mount=caddy.Mounts.Where(m=>m!=null&&!String.IsNullOrEmpty(m.Destination)&&
        (path==m.Destination||path.StartsWith(m.Destination.TrimEnd('/')+"/",StringComparison.Ordinal)))
        .OrderByDescending(m=>m.Destination.Length).FirstOrDefault();
      return mount!=null&&mount.RW&&(mount.Type=="volume"||mount.Type=="bind")&&!String.IsNullOrEmpty(mount.Source);
    }
    internal static void ValidatePublicConfiguration(Preferences prefs) {
      if(prefs==null||!prefs.Managed||String.IsNullOrEmpty(prefs.ReceiptPath))throw new IOException("La instalación pública no está verificada.");
      Backend.RejectLinks(Path.GetDirectoryName(prefs.ReceiptPath));
      if((File.GetAttributes(prefs.ReceiptPath)&FileAttributes.ReparsePoint)!=0)throw new IOException("La vinculación no es un archivo normal.");
      var receipt=Backend.Json.Deserialize<AdoptionReceipt>(File.ReadAllText(prefs.ReceiptPath));
      if(receipt==null||!receipt.RestoreVerified||!Regex.IsMatch(receipt.SnapshotSha256??"","^[a-f0-9]{64}$")||receipt.ConfigurationHashes==null)
        throw new IOException("La vinculación pública no está verificada.");
      var actual=Backend.ConfigurationHashes(prefs);
      if(actual.Count!=receipt.ConfigurationHashes.Count)throw new IOException("La configuración pública cambió.");
      foreach(var expected in receipt.ConfigurationHashes) {
        string hash;if(!actual.TryGetValue(expected.Key,out hash))throw new IOException("La configuración pública cambió.");
        if(hash==expected.Value)continue;
        // Only the coordinator's validated, installation-scoped transaction
        // may account for an in-flight Compose image change. Caddy, .env and
        // storage identity remain strict while downloads are repaired.
        if(expected.Key=="docker-compose.yml"&&RuntimeUpdates.HasRecognizedPendingTransaction(prefs))continue;
        throw new IOException("La configuración pública cambió.");
      }
      if(!actual.ContainsKey("Caddyfile")||!actual.ContainsKey(".env")||!actual.ContainsKey("docker-compose.yml"))
        throw new IOException("Falta la configuración pública verificada.");
    }
    static async Task<ServerContainer> CheckedCaddy(Preferences prefs) {
      ValidatePublicConfiguration(prefs);
      var receipt=Backend.Json.Deserialize<AdoptionReceipt>(File.ReadAllText(prefs.ReceiptPath));
      var rows=await Backend.InspectServer(prefs);Backend.AssertManagedIdentity(prefs,receipt.Containers,rows);
      var caddy=rows.SingleOrDefault(r=>r.Service=="caddy");
      if(caddy==null)return null;
      var adopted=receipt.Containers.SingleOrDefault(r=>r.Service=="caddy");
      if(!Regex.IsMatch(caddy.Id??"","^[a-f0-9]{64}$")||caddy.Project!=prefs.ProjectName||adopted==null||caddy.Image!=adopted.Image)
        throw new IOException("El proxy público no está verificado.");
      var configuration=Path.Combine(prefs.Installation,"Caddyfile");
      if(!File.Exists(configuration))return null;
      var source=File.ReadAllText(configuration);if(!HasDownloadsRoute(source))return null;
      foreach(var file in OwnedFiles)if(!WritablePath(caddy,Root+"/"+file))throw new IOException("La página no tiene almacenamiento persistente verificable.");
      var mounted=await Backend.Docker("exec "+caddy.Id+" cat /etc/caddy/Caddyfile",15);
      if(mounted!=source)throw new IOException("La configuración pública no coincide con la verificada.");
      return caddy;
    }
    static Task<string> Shell(string id,string script,params string[] arguments) {
      if(!Regex.IsMatch(id??"","^[a-f0-9]{64}$"))throw new IOException("El proxy público no está verificado.");
      return Backend.Docker("exec "+id+" sh -c "+Backend.Argument(script)+" inhouse-downloads "+String.Join(" ",arguments.Select(Backend.Argument)),20);
    }
    const string SafeTarget="p=\"$1\"; while [ \"$p\" != / ]; do [ ! -L \"$p\" ] || exit 31; p=${p%/*}; [ -n \"$p\" ] || p=/; done; ";
    static async Task<string> ReadPublicFile(string id,string relative,int maximum) {
      if(!OwnedFiles.Contains(relative,StringComparer.Ordinal))throw new IOException("Recurso público no reconocido.");
      var value=await Shell(id,SafeTarget+"if [ -f \"$1\" ]; then [ $(wc -c < \"$1\") -le \"$2\" ] || exit 32; cat \"$1\"; fi",Root+"/"+relative,maximum.ToString());
      return String.IsNullOrEmpty(value)?null:value;
    }
    static string Digest(byte[] bytes) {using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-","").ToLowerInvariant();}
    static void SaveAtomic(string path,string value) {
      Backend.RejectLinks(Path.GetDirectoryName(path));var temp=path+"."+Guid.NewGuid().ToString("N")+".new";
      try{File.WriteAllText(temp,value,new UTF8Encoding(false));if(File.Exists(path))File.Replace(temp,path,null);else File.Move(temp,path);}
      finally{if(File.Exists(temp))File.Delete(temp);}
    }
    static void RecordDiagnostic(string code) {
      try{Backend.PrivateDirectory(StateDirectory);SaveAtomic(Path.Combine(StateDirectory,"last-publication.txt"),DateTime.UtcNow.ToString("o")+" "+code+"\n");}catch{}
    }

    internal static async Task<int> PublishBundle(Preferences prefs,ServerContainer caddy,Dictionary<string,byte[]> bundle,string stateKey) {
      var token=Guid.NewGuid().ToString("N");var work=Path.Combine(StateDirectory,token);Backend.PrivateDirectory(work);
      var stage="/tmp/inhouse-downloads-"+token;
      var ownedCache=Path.Combine(StateDirectory,stateKey+"-owned.json");
      var owned=new Dictionary<string,string>(StringComparer.Ordinal);
      if(File.Exists(ownedCache)&&(File.GetAttributes(ownedCache)&FileAttributes.ReparsePoint)==0&&new FileInfo(ownedCache).Length<16384)
        try{owned=Backend.Json.Deserialize<Dictionary<string,string>>(File.ReadAllText(ownedCache))??owned;}catch{}
      var preserved=0;
      try {
        await Shell(caddy.Id,"[ ! -e \"$1\" ] && [ ! -L \"$1\" ] && mkdir -m 700 \"$1\"",stage);
        // Supporting files first; the landing HTML is the final publication.
        foreach(var relative in OwnedFiles.OrderBy(f=>f=="index.html"?2:f.EndsWith(".html",StringComparison.Ordinal)?1:0)) {
          var bytes=bundle[relative];var hash=Digest(bytes);var target=Root+"/"+relative;
          var current=(await Shell(caddy.Id,SafeTarget+"if [ -e \"$1\" ]; then [ -f \"$1\" ] || exit 33; sha256sum \"$1\" | cut -d ' ' -f 1; fi",target)).Trim();
          if(current==hash){owned[relative]=hash;continue;}
          // Existing custom public files and authenticated status panels are
          // preserved. Replace only recognised originals or our own recorded
          // hashes; a valid existing catalogue is merged before this stage.
          if(current!="") {
            string original,previous;
            var recognised=(OriginalHashes.TryGetValue(relative,out original)&&current==original)||
              (owned.TryGetValue(relative,out previous)&&current==previous);
            if(!recognised&&relative=="download-catalogue.js") {
              try{ParseCatalogue(await ReadPublicFile(caddy.Id,relative,16384));recognised=true;}catch(IOException){}
            }
            if(!recognised){preserved++;continue;}
          }
          if(current!=""&&relative.EndsWith(".html",StringComparison.Ordinal)) {
            var backup=Path.Combine(work,relative.Replace('/','-')+".before");
            await Backend.Docker("cp "+Backend.Quote(caddy.Id+":"+target)+" "+Backend.Quote(backup),20);
            if(Backend.Hash(backup)!=current)throw new IOException("La página cambió durante la comprobación.");
          }
          var local=Path.Combine(work,relative.Replace('/','-'));File.WriteAllBytes(local,bytes);
          var inside=stage+"/"+relative.Replace('/','-');
          await Backend.Docker("cp "+Backend.Quote(local)+" "+Backend.Quote(caddy.Id+":"+inside),20);
          ValidatePublicConfiguration(prefs);
          // Verify storage identity again before the first persistent write.
          var receipt=Backend.Json.Deserialize<AdoptionReceipt>(File.ReadAllText(prefs.ReceiptPath));
          var rows=await Backend.InspectServer(prefs);Backend.AssertManagedIdentity(prefs,receipt.Containers,rows);
          if(!rows.Any(r=>r.Service=="caddy"&&r.Id==caddy.Id))throw new IOException("El proxy cambió durante la publicación.");
          var temporary=target+".inhouse-"+token;
          await Shell(caddy.Id,SafeTarget+
            "[ ! -e \"$2\" ] && [ ! -L \"$2\" ] || exit 34; "+
            "actual=''; if [ -f \"$1\" ]; then actual=$(sha256sum \"$1\" | cut -d ' ' -f 1); fi; "+
            "[ \"$actual\" = \"$5\" ] || exit 35; [ $(sha256sum \"$3\" | cut -d ' ' -f 1) = \"$4\" ] || exit 36; "+
            "mkdir -p \"${1%/*}\"; umask 022; cat \"$3\" > \"$2\"; "+
            "[ $(sha256sum \"$2\" | cut -d ' ' -f 1) = \"$4\" ] || exit 37; mv -f \"$2\" \"$1\"; "+
            "[ $(sha256sum \"$1\" | cut -d ' ' -f 1) = \"$4\" ] || exit 38",target,temporary,inside,hash,current);
          owned[relative]=hash;
          SaveAtomic(ownedCache,Backend.Json.Serialize(owned));
        }
        SaveAtomic(ownedCache,Backend.Json.Serialize(owned));
        return preserved;
      }finally {
        try{await Shell(caddy.Id,"[ ! -L \"$1\" ] || exit 39; rm -rf \"$1\"",stage);}catch{}
        // Keep only private HTML backups, never put historical pages or settings
        // beneath the public Caddy root.
        foreach(var file in Directory.GetFiles(work))if(!file.EndsWith(".before",StringComparison.Ordinal))try{File.Delete(file);}catch{}
        if(Directory.GetFiles(work).Length==0)try{Directory.Delete(work);}catch{}
      }
    }
  }
}
