using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Net.Mail;
using System.Text;
using System.Threading.Tasks;
using System.Text.RegularExpressions;
using System.Collections.Generic;

namespace InhousePhotos {
  public sealed class SetupState {
    public string Project {get;set;} public int Port {get;set;} public string Domain {get;set;}
    public Dictionary<string,string> Hashes {get;set;}
  }
  public static class NewServer {
    public const string ImageName="inhouse-photos-server:v3.1.0-storage-saver";
    public const string ImageId="sha256:c4d5d8b8751deac177e4f5f3cdbeee21e6ff38f77046405032e90587b3df90bd";
    public const string BundleHash="aad723cdc100ca0b5beb204c004307ffd7c17e4dbda3c0cfb53c5eebc983c70f";
    static readonly System.Threading.SemaphoreSlim Gate=new System.Threading.SemaphoreSlim(1,1);
    public static string PendingFile {get{return Path.Combine(Backend.SettingsDir,"setup-pending.json");}}
    public static void Validate(string folder,string email,string password,string name,string domain) {
      if(String.IsNullOrWhiteSpace(folder)||!Path.IsPathRooted(folder)||folder.StartsWith(@"\\")||Path.GetFullPath(folder).TrimEnd('\\')==Path.GetPathRoot(folder).TrimEnd('\\'))throw new ArgumentException("Elige una carpeta local vacía, no un disco entero ni una carpeta de red.");
      Backend.RejectLinks(folder);
      if(String.IsNullOrWhiteSpace(name)||name.Length>100)throw new ArgumentException("Escribe tu nombre.");
      MailAddress address;try{address=new MailAddress(email);}catch{throw new ArgumentException("Escribe un correo válido.");}
      if(address.Address!=email||password==null||password.Length<12)throw new ArgumentException("Utiliza un correo válido y una contraseña de al menos 12 caracteres.");
      if(!String.IsNullOrEmpty(domain)&&(!Regex.IsMatch(domain,"^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$")||domain=="localhost"))throw new ArgumentException("Escribe solo el dominio, por ejemplo fotos.ejemplo.com, sin https:// ni rutas.");
    }
    public static async Task Download(string url,string path,string expected,Action<string> progress) {
      Backend.PrivateDirectory(Path.GetDirectoryName(path));
      if(File.Exists(path)&&expected!=null&&Backend.Hash(path)==expected)return;
      var part=path+"."+Guid.NewGuid().ToString("N")+".partial";
      using(var client=new WebClient()) {
        int previous=-1;
        client.DownloadProgressChanged+=(s,e)=>{if(e.ProgressPercentage!=previous){previous=e.ProgressPercentage;progress("Descargando componentes · "+e.ProgressPercentage+" %");}};
        var transfer=client.DownloadFileTaskAsync(new Uri(url),part);
        if(await Task.WhenAny(transfer,Task.Delay(TimeSpan.FromMinutes(30)))!=transfer){client.CancelAsync();try{await transfer;}catch{}throw new TimeoutException("La descarga no terminó a tiempo. Reintenta cuando la conexión esté disponible.");}
        await transfer;
      }
      if(expected!=null&&Backend.Hash(part)!=expected)throw new IOException("La descarga está incompleta o no coincide con la versión esperada. No se ejecutará.");
      if(File.Exists(path))File.Replace(part,path,null);else File.Move(part,path);
    }
    static async Task EnsureImage(Action<string> progress) {
      try{if((await Backend.Docker("image inspect "+ImageName+" --format {{.Id}}",15)).Trim()==ImageId)return;}catch{}
      var archive=Path.Combine(Backend.SettingsDir,"components","inhouse-server-3.1.0.tar.gz");
      await Download("https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/server-v1.1.0/inhouse-server-3.1.0.tar.gz",archive,BundleHash,progress);
      progress("Preparando los componentes descargados…");
      await Backend.Docker("load --input "+Backend.Quote(archive),900);
      if((await Backend.Docker("image inspect "+ImageName+" --format {{.Id}}",15)).Trim()!=ImageId)throw new IOException("El componente del servidor no pasa la verificación.");
    }
    public static string ComposeText(bool remote) {
      return @"services:
  immich-server:
    image: inhouse-photos-server:v3.1.0-storage-saver
    platform: linux/amd64
    env_file: .env
    volumes:
      - ./library:/data
    ports:
      - '127.0.0.1:${INHOUSE_PORT}:2283'
    environment:
      INHOUSE_STORAGE_SAVER_CONCURRENCY: '2'
    depends_on: [database, redis]
    restart: unless-stopped
  immich-machine-learning:
    image: ghcr.io/immich-app/immich-machine-learning@sha256:5a0839dc5303cd7215bcd2180a26aed3af41675aefb3e75e5157e9f10ad16e6e
    volumes:
      - model-cache:/cache
    restart: unless-stopped
  redis:
    image: docker.io/valkey/valkey:9@sha256:8e8d64b405ce18f41b8e5ee20aa4687a8ed0022d1298f2ce31cdcf3a76e09411
    restart: unless-stopped
  database:
    image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23
    environment:
      POSTGRES_USER: postgres
      POSTGRES_DB: immich
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_INITDB_ARGS: '--data-checksums'
    volumes:
      - pgdata:/var/lib/postgresql/data
    shm_size: 128mb
    restart: unless-stopped
"+(remote?@"  caddy:
    image: caddy@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648
    ports: ['80:80', '443:443', '443:443/udp']
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    restart: unless-stopped
":"")+@"volumes:
  pgdata:
  model-cache:
  caddy-data:
  caddy-config:
";
    }
    public static async Task<Dictionary<string,object>> Post(string endpoint,string route,object body) {
      var uri=new Uri(endpoint);if(!uri.IsLoopback)throw new IOException("La creación de cuentas solo se realiza en este PC.");
      var request=(HttpWebRequest)WebRequest.Create(endpoint+route);request.Method="POST";request.ContentType="application/json";request.AllowAutoRedirect=false;
      var bytes=Encoding.UTF8.GetBytes(Backend.Json.Serialize(body));request.ContentLength=bytes.Length;
      using(var deadline=new System.Threading.CancellationTokenSource(30000))using(deadline.Token.Register(()=>request.Abort())) {
        using(var stream=await request.GetRequestStreamAsync())await stream.WriteAsync(bytes,0,bytes.Length);
        using(var response=await request.GetResponseAsync())using(var reader=new StreamReader(response.GetResponseStream()))return Backend.Json.Deserialize<Dictionary<string,object>>(await reader.ReadToEndAsync());
      }
    }
    public static async Task<Preferences> Create(string folder,string email,string password,string name,string domain,Action<string> progress,bool persist=true) {
      Validate(folder,email,password,name,domain);await Gate.WaitAsync();
      try {
        folder=Path.GetFullPath(folder);var stateFile=Path.Combine(folder,"inhouse-setup.json");SetupState state;
        if(Directory.Exists(folder)&&Directory.EnumerateFileSystemEntries(folder).Any()&&!File.Exists(stateFile))throw new IOException("La carpeta contiene archivos. Elige una carpeta vacía; no se ha sobrescrito nada.");
        var drive=new DriveInfo(Path.GetPathRoot(folder));if(drive.AvailableFreeSpace<10L*1024*1024*1024)throw new IOException("Necesitas al menos 10 GB libres para preparar el servidor.");
        await Backend.EnsureEngine(progress);await EnsureImage(progress);
        if(File.Exists(stateFile)) {
          state=Backend.Json.Deserialize<SetupState>(File.ReadAllText(stateFile));
          if(state==null||!Regex.IsMatch(state.Project??"","^inhouse-[a-f0-9]{16}$")||state.Port<1024||state.Port>65535||state.Domain!=domain)throw new IOException("No se puede reanudar esta instalación con esos datos.");
          var check=new Preferences{Installation=folder};var hashes=Backend.ConfigurationHashes(check);
          if(state.Hashes==null||state.Hashes.Count!=hashes.Count||state.Hashes.Any(x=>!hashes.ContainsKey(x.Key)||hashes[x.Key]!=x.Value))throw new IOException("La configuración de esta instalación ha cambiado. No se modificará automáticamente.");
        } else {
          Backend.PrivateDirectory(folder);Directory.CreateDirectory(Path.Combine(folder,"library"));
          var listener=new TcpListener(IPAddress.Loopback,0);listener.Start();int port=((IPEndPoint)listener.LocalEndpoint).Port;listener.Stop();
          state=new SetupState{Project="inhouse-"+Backend.RandomHex(8),Port=port,Domain=domain};
          File.WriteAllText(Path.Combine(folder,"docker-compose.yml"),ComposeText(!String.IsNullOrEmpty(domain)),new UTF8Encoding(false));
          File.WriteAllText(Path.Combine(folder,".env"),"UPLOAD_LOCATION=./library\nINHOUSE_PORT="+port+"\nDB_HOSTNAME=database\nDB_USERNAME=postgres\nDB_DATABASE_NAME=immich\nREDIS_HOSTNAME=redis\nDB_PASSWORD="+Backend.RandomHex(32)+"\n",new UTF8Encoding(false));
          if(!String.IsNullOrEmpty(domain))File.WriteAllText(Path.Combine(folder,"Caddyfile"),domain+" {\n reverse_proxy immich-server:2283\n}\n",new UTF8Encoding(false));
          state.Hashes=Backend.ConfigurationHashes(new Preferences{Installation=folder});File.WriteAllText(stateFile,Backend.Json.Serialize(state));
        }
        if(persist){Backend.PrivateDirectory(Backend.SettingsDir);File.WriteAllText(PendingFile,Backend.Json.Serialize(new{Folder=folder,Domain=domain,Email=email,Name=name}));}
        var p=new Preferences{Installation=folder,ProjectName=state.Project,LocalEndpoint="http://127.0.0.1:"+state.Port,Endpoint=String.IsNullOrEmpty(domain)?"http://127.0.0.1:"+state.Port:"https://"+domain};
        progress("Creando tu biblioteca privada…");
        // No fixed container names, shared volumes or public ports before the
        // administrator exists. Never run down, remove, prune or overwrite data.
        await Backend.Compose(p,"up -d immich-server immich-machine-learning redis database",1200);
        bool ready=false;for(int i=0;i<120;i++){if(await Backend.Ping(p.LocalEndpoint)){ready=true;break;}await Task.Delay(2000);}
        if(!ready)throw new IOException("El servidor todavía no responde. Puedes reanudar en la misma carpeta; no borres sus archivos.");
        progress("Creando y comprobando tu cuenta…");
        try {await Post(p.LocalEndpoint,"/api/auth/admin-sign-up",new{email=email,password=password,name=name});}
        catch(WebException){ /* A previous attempt may have already created it. */ }
        var login=await Post(p.LocalEndpoint,"/api/auth/login",new{email=email,password=password});
        if(!login.ContainsKey("isAdmin")||!(bool)login["isAdmin"])throw new IOException("No se ha podido verificar la cuenta administradora.");
        if(!String.IsNullOrEmpty(domain))await Backend.Compose(p,"up -d caddy",300);
        progress("Verificando la copia de recuperación…");await Backend.Adopt(p,progress,persist);
        if(persist&&File.Exists(PendingFile))File.Delete(PendingFile);
        return p;
      } finally {Gate.Release();}
    }
  }
}
