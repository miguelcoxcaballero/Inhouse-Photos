using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Diagnostics;
using System.Management;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Markup;
using System.Windows.Threading;

[assembly: System.Reflection.AssemblyTitle("Inhouse Photos Server")]
[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]

namespace InhousePhotos {
  public sealed class Preferences {
    public string Installation { get; set; }
    public string Endpoint { get; set; }
    public string BackupDestination { get; set; }
    public string ProjectName { get; set; }
    public string LocalEndpoint { get; set; }
    public string ReceiptPath { get; set; }
    public bool Managed { get; set; }
  }
  public sealed class DiskInfo {
    public string Root, Name;
    public long Total, Free;
  }
  public static partial class Backend {
    public static readonly string SettingsDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Inhouse Photos Server");
    public static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    public static string Quote(string s) {
      if (String.IsNullOrWhiteSpace(s) || s.IndexOfAny(new [] {'"', '\r', '\n', '\0'}) >= 0) throw new ArgumentException("Ruta no válida.");
      // Windows command line quoting: double trailing slashes before the quote.
      return "\"" + s.TrimEnd('\\') + new string('\\', (s.Length - s.TrimEnd('\\').Length) * 2) + "\"";
    }
    public static string CanonicalEndpoint(string value) {
      Uri uri;
      if (String.IsNullOrWhiteSpace(value) || !Uri.TryCreate(value.Trim(), UriKind.Absolute, out uri) || !String.IsNullOrEmpty(uri.UserInfo) ||
          !String.IsNullOrEmpty(uri.Query) || !String.IsNullOrEmpty(uri.Fragment) ||
          (uri.Scheme != "https" && !(uri.Scheme == "http" && uri.IsLoopback)))
        throw new ArgumentException("Usa una dirección HTTPS sin contraseña ni parámetros. HTTP solo se admite en este PC.");
      return uri.GetLeftPart(UriPartial.Path).TrimEnd('/');
    }
    public static Preferences Load() {
      var p = new Preferences { Installation = "", Endpoint = "", BackupDestination = "" };
      try { var saved = Json.Deserialize<Preferences>(File.ReadAllText(Path.Combine(SettingsDir,"settings.json"))); if(saved!=null)p=saved; } catch { }
      if (String.IsNullOrEmpty(p.Installation) && File.Exists(@"D:\Immich\docker-compose.yml")) p.Installation = @"D:\Immich";
      if (String.IsNullOrEmpty(p.Endpoint) && Directory.Exists(p.Installation)) {
        var caddy = Path.Combine(p.Installation,"Caddyfile");
        if (File.Exists(caddy)) {
          var first = File.ReadLines(caddy).FirstOrDefault(x => x.TrimEnd().EndsWith("{"));
          if (first != null) { try { p.Endpoint = CanonicalEndpoint("https://" + first.Split('{')[0].Trim()); } catch { } }
        }
      }
      if(String.IsNullOrEmpty(p.LocalEndpoint))p.LocalEndpoint="http://127.0.0.1:2283";
      return p;
    }
    public static void Save(Preferences p) {
      PrivateDirectory(SettingsDir);
      var path = Path.Combine(SettingsDir,"settings.json");
      var temp = path + ".new";
      File.WriteAllText(temp,Json.Serialize(p),new UTF8Encoding(false));
      if (File.Exists(path)) File.Replace(temp,path,null); else File.Move(temp,path);
    }
    public static string DockerExe() {
      foreach (var root in new [] {
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),@"Programs\DockerDesktop"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),@"Docker\Docker")}) {
        var file = Path.Combine(root,@"resources\bin\docker.exe"); if (File.Exists(file)) return file;
      }
      throw new InvalidOperationException("Este equipo todavía no tiene el motor del servidor. Esta versión puede vincular instalaciones existentes; no prepara un servidor nuevo.");
    }
    public static Task<string> Run(string exe, string args, string cwd, int seconds) {
      return Task.Run(async delegate {
        using (var process = new Process()) {
          process.StartInfo = new ProcessStartInfo(exe,args) { UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden,RedirectStandardOutput=true,RedirectStandardError=true,WorkingDirectory=cwd };
          process.Start();
          var output = process.StandardOutput.ReadToEndAsync();
          var error = process.StandardError.ReadToEndAsync();
          if (!process.WaitForExit(seconds * 1000)) { try { process.Kill(); } catch {} throw new TimeoutException("La operación está tardando demasiado. Comprueba el estado antes de repetirla."); }
          var text = await output; var details = await error;
          if (process.ExitCode != 0) throw new InvalidOperationException("El servidor no pudo completar la operación (código " + process.ExitCode + "). No se ha solicitado borrar datos.");
          return text;
        }
      });
    }
    public static Task<string> Compose(Preferences p, string args, int seconds) {
      if (String.IsNullOrEmpty(p.Installation) || !File.Exists(Path.Combine(p.Installation,"docker-compose.yml"))) throw new InvalidOperationException("Selecciona la carpeta de tu servidor existente.");
      return Run(DockerExe(),ComposeArgs(p,args),p.Installation,seconds);
    }
    public static async Task<bool> Ping(string endpoint) {
      try {
        var uri = CanonicalEndpoint(endpoint) + "/api/server/ping";
        var req = (HttpWebRequest)WebRequest.Create(uri);
        req.Timeout=5000; req.ReadWriteTimeout=5000; req.AllowAutoRedirect=false;
        using (var response = await req.GetResponseAsync()) using (var reader=new StreamReader(response.GetResponseStream())) {
          var result=Json.Deserialize<Dictionary<string,object>>(await reader.ReadToEndAsync());
          return result.ContainsKey("res") && (string)result["res"]=="pong";
        }
      } catch { return false; }
    }
    public static List<DiskInfo> Disks() {
      return DriveInfo.GetDrives().Where(d=>d.IsReady && (d.DriveType==DriveType.Fixed || d.DriveType==DriveType.Removable)).Select(d=>new DiskInfo { Root=d.RootDirectory.FullName,Name=d.VolumeLabel,Total=d.TotalSize,Free=d.AvailableFreeSpace }).ToList();
    }
    public static string PhysicalDisks() {
      var lines=new List<string>();
      using (var query=new ManagementObjectSearcher("SELECT Model,Size,Status FROM Win32_DiskDrive"))
      using (var results=query.Get()) foreach (ManagementObject d in results) lines.Add(Convert.ToString(d["Model"])+" · "+Size(Convert.ToInt64(d["Size"] ?? 0))+" · "+Convert.ToString(d["Status"]));
      return String.Join("\n",lines);
    }
    public static string Size(long bytes) { return (bytes / 1073741824.0).ToString("0.0")+" GiB"; }
    public static string Library(Preferences p) {
      var env=Path.Combine(p.Installation,".env");
      if (!File.Exists(env)) throw new InvalidOperationException("No se encuentra la configuración del servidor.");
      var line=File.ReadLines(env).FirstOrDefault(l=>l.StartsWith("UPLOAD_LOCATION="));
      if (line==null) throw new InvalidOperationException("No se encuentra la ubicación de la biblioteca.");
      var path=line.Substring("UPLOAD_LOCATION=".Length).Trim().Trim('"','\'');
      if (!Path.IsPathRooted(path)) path=Path.Combine(p.Installation,path);
      path=Path.GetFullPath(path);
      if (!Directory.Exists(path) || path==Path.GetPathRoot(path)) throw new InvalidOperationException("La ruta de la biblioteca no es segura o no está disponible.");
      return path;
    }
    public static void ValidateBackup(string source,string destination) {
      source=Path.GetFullPath(source).TrimEnd('\\')+"\\";
      destination=Path.GetFullPath(destination).TrimEnd('\\')+"\\";
      if (destination.StartsWith(source,StringComparison.OrdinalIgnoreCase) || source.StartsWith(destination,StringComparison.OrdinalIgnoreCase) ||
          String.Equals(Path.GetPathRoot(source),Path.GetPathRoot(destination),StringComparison.OrdinalIgnoreCase))
        throw new InvalidOperationException("Elige otro disco para la copia. No puede estar dentro de la biblioteca ni en su mismo volumen.");
      RejectLinks(source); RejectLinks(destination);
    }
    public static void RejectLinks(string path) {
      for(var dir=new DirectoryInfo(path);dir!=null;dir=dir.Parent) {
        if(dir.Exists && (dir.Attributes & FileAttributes.ReparsePoint)!=0)
          throw new InvalidOperationException("No se permiten enlaces o carpetas redirigidas como destino de copia.");
      }
    }
    public static void RejectNestedLinks(string path) {
      RejectLinks(path);
      if(!Directory.Exists(path))return;
      foreach(var child in Directory.EnumerateDirectories(path))RejectNestedLinks(child);
    }
    public static async Task<string> Snapshot(Preferences p) {
      var directory=Path.Combine(p.Installation,@"operations\backups"); Directory.CreateDirectory(directory);
      var file=Path.Combine(directory,"inhouse-"+DateTime.UtcNow.ToString("yyyyMMdd-HHmmss-fff")+".sql");
      // Shell is inside the selected database container; variables are expanded
      // there, never exposed to this process, UI or the release artifact.
      await Task.Run(async delegate {
        using(var process=new Process()) {
          var args="compose --project-directory "+Quote(p.Installation)+" -f "+Quote(Path.Combine(p.Installation,"docker-compose.yml"))+" exec -T database sh -c "+Quote("exec pg_dump --username=$POSTGRES_USER --dbname=$POSTGRES_DB --no-owner --no-acl");
          process.StartInfo=new ProcessStartInfo(DockerExe(),args){WorkingDirectory=p.Installation,UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden,RedirectStandardOutput=true,RedirectStandardError=true};
          process.Start();var error=process.StandardError.ReadToEndAsync();
          using(var output=new FileStream(file+".partial",FileMode.CreateNew,FileAccess.Write,FileShare.None,65536,true)) {
            var copy=process.StandardOutput.BaseStream.CopyToAsync(output);
            if(await Task.WhenAny(copy,Task.Delay(TimeSpan.FromMinutes(15)))!=copy){try{process.Kill();}catch{}throw new TimeoutException("Instantánea incompleta: tiempo agotado.");}
            await copy;
          }
          if(!process.WaitForExit(30000)){try{process.Kill();}catch{}throw new TimeoutException("La base de datos no confirmó el final de la instantánea.");}
          await error;if(process.ExitCode!=0)throw new IOException("La instantánea no se completó. El archivo parcial no es una copia válida.");
        }
      });
      using(var reader=new StreamReader(file+".partial")){var header=new char[200];var count=reader.Read(header,0,header.Length);if(!new string(header,0,count).Contains("PostgreSQL database dump"))throw new IOException("La instantánea no es válida.");}
      File.Move(file+".partial",file); return file;
    }
    public static async Task<string> Backup(Preferences p, Action<string> progress, CancellationToken cancellation) {
      var source=Library(p); ValidateBackup(source,p.BackupDestination);
      var target=Path.Combine(p.BackupDestination,"Inhouse Photos backup");
      progress("Comprobando el destino de la copia…");
      await Task.Run(()=>{cancellation.ThrowIfCancellationRequested();RejectNestedLinks(target);Directory.CreateDirectory(target);},cancellation);
      cancellation.ThrowIfCancellationRequested();
      progress("Copiando archivos nuevos. No se borran ni se sobrescriben los existentes…");
      // No /MIR, /PURGE, /MOVE: a removed source photo must survive in the backup.
      var code=await Task.Run(delegate {
        using(var process=new Process()) {
          process.StartInfo=new ProcessStartInfo(Path.Combine(Environment.SystemDirectory,"robocopy.exe"),Quote(source)+" "+Quote(Path.Combine(target,"library"))+" /E /XC /XN /XO /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP") {UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden};
          process.Start();
          while(!process.WaitForExit(1000)) {
            if(cancellation.IsCancellationRequested){try{process.Kill();}catch{}throw new OperationCanceledException("Copia detenida. Los archivos ya copiados se conservan, pero la copia no está completa.");}
          }
          cancellation.ThrowIfCancellationRequested();return process.ExitCode;
        }
      });
      if(code>=8) throw new IOException("Algunos archivos no se copiaron. La copia no está completa. Revisa espacio y conexión del disco y vuelve a intentarlo.");
      cancellation.ThrowIfCancellationRequested();
      progress("Guardando la base de datos…");
      var snapshot=await Snapshot(p); File.Copy(snapshot,Path.Combine(target,Path.GetFileName(snapshot)),false);
      return target;
    }
  }
  public sealed partial class ServerWindow : Window {
    readonly Preferences prefs=Backend.Load();
    readonly StackPanel content=new StackPanel();
    readonly TextBlock notice=new TextBlock();
    readonly Dictionary<string,Button> tabs=new Dictionary<string,Button>();
    string page="Inicio"; bool busy, refreshing;
    CancellationTokenSource backupCancellation;
    readonly Brush accent=new SolidColorBrush(Color.FromRgb(237,153,90));
    readonly Brush muted=new SolidColorBrush(Color.FromRgb(185,178,169));
    public ServerWindow() {
      Title="Inhouse Photos Server"; Width=1080;Height=760;MinWidth=760;MinHeight=600;Background=new SolidColorBrush(Color.FromRgb(19,17,14));Foreground=Brushes.White;FontFamily=new FontFamily("Segoe UI");FontSize=15;WindowStartupLocation=WindowStartupLocation.CenterScreen;
      Resources.Add(typeof(Button),XamlReader.Parse(@"<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='Button'><Setter Property='Background' Value='#2C251F'/><Setter Property='Foreground' Value='#F4F1EC'/><Setter Property='BorderThickness' Value='0'/><Setter Property='Padding' Value='18,12'/><Setter Property='Margin' Value='0,6,8,6'/><Setter Property='Cursor' Value='Hand'/><Setter Property='HorizontalContentAlignment' Value='Left'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Button'><Border x:Name='bg' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' Background='{TemplateBinding Background}' Padding='{TemplateBinding Padding}' CornerRadius='10'><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='bg' Property='Opacity' Value='0.8'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter TargetName='bg' Property='Opacity' Value='0.45'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>"));
      var root=new Grid{Background=Background}; root.ColumnDefinitions.Add(new ColumnDefinition {Width=new GridLength(215)});root.ColumnDefinitions.Add(new ColumnDefinition());Content=root;
      var sidebar=new StackPanel {Margin=new Thickness(24,32,14,20)};root.Children.Add(sidebar);
      using(var brand=typeof(ServerWindow).Assembly.GetManifestResourceStream("InhousePhotos.brand.xaml"))Icon=(ImageSource)XamlReader.Load(brand);
      sidebar.Children.Add(new Image{Source=Icon,Width=52,Height=52,HorizontalAlignment=HorizontalAlignment.Left,Margin=new Thickness(0,0,0,8)});
      sidebar.Children.Add(Label("inhouse photos",22,accent));sidebar.Children.Add(Label("SERVER · WINDOWS",12,muted));
      sidebar.Children.Add(new Border{Height=36});
      foreach(var name in new[]{"Inicio","Discos","Protección","Conectar","Configuración"}) {var captured=name;var button=new Button{Content=name};button.Click+=async(s,e)=>{if(!busy){page=captured;await Render();}};tabs[name]=button;sidebar.Children.Add(button);}
      var right=new DockPanel{Margin=new Thickness(26,35,34,24)};Grid.SetColumn(right,1);root.Children.Add(right);
      notice.TextWrapping=TextWrapping.Wrap;notice.Foreground=accent;notice.Margin=new Thickness(0,12,0,0);DockPanel.SetDock(notice,Dock.Bottom);right.Children.Add(notice);
      right.Children.Add(new ScrollViewer{Content=content,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled});
      Loaded+=async(s,e)=>await Render();
      Closing+=(s,e)=>{if(busy){e.Cancel=true;notice.Text="Espera a que termine la operación antes de cerrar.";}};
      var timer=new DispatcherTimer{Interval=TimeSpan.FromSeconds(30)};timer.Tick+=async(s,e)=>{if(IsVisible&&!busy&&!refreshing&&page=="Inicio")await Render();};timer.Start();Closed+=(s,e)=>timer.Stop();
    }
    TextBlock Label(string text,double size,Brush color=null) {return new TextBlock{Text=text,FontSize=size,Foreground=color??Foreground,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,10)};}
    void Heading(string text,string description){content.Children.Add(Label(text,34));content.Children.Add(Label(description,15,muted));content.Children.Add(new Border{Height=18});}
    void Rule(){content.Children.Add(new Border{Height=1,Background=new SolidColorBrush(Color.FromRgb(61,52,43)),Margin=new Thickness(0,18,0,20)});}
    void Action(string title,Func<Task> task,bool primary=false) {
      var button=new Button{Content=title,HorizontalAlignment=HorizontalAlignment.Left};if(primary){button.Background=accent;button.Foreground=Background;}
      button.Click+=async(s,e)=>{if(busy)return;busy=true;button.IsEnabled=false;notice.Text="Trabajando…";try{await task();}catch(Exception ex){notice.Text=ex.Message;}finally{busy=false;button.IsEnabled=true;}};content.Children.Add(button);
    }
    string PickFolder(){using(var dialog=new System.Windows.Forms.FolderBrowserDialog()){dialog.Description="Selecciona una carpeta";return dialog.ShowDialog()==System.Windows.Forms.DialogResult.OK?dialog.SelectedPath:null;}}
    bool Confirm(string message){return MessageBox.Show(this,message,"Inhouse Photos",MessageBoxButton.OKCancel,MessageBoxImage.Warning)==MessageBoxResult.OK;}
    void Open(string url){Process.Start(new ProcessStartInfo(url){UseShellExecute=true});}
    public async Task Render(){
      if(refreshing)return;refreshing=true;content.Children.Clear();
      foreach(var tab in tabs.Values)tab.IsEnabled=false;
      foreach(var item in tabs)item.Value.Foreground=item.Key==page?accent:muted;
      try {
        if(page=="Inicio") {
          Heading("Tu servidor","Tus fotos permanecen en este equipo. Cerrar esta ventana no detiene el servidor.");
          var health=Label("Comprobando conexión…",22,muted);content.Children.Add(health);
          var pingTask=String.IsNullOrEmpty(prefs.Endpoint)?Task.FromResult(false):Backend.Ping(prefs.Endpoint);
          var local=await Backend.Ping(prefs.LocalEndpoint);var remote=await pingTask;
          health.Text=local?"●  Servidor en funcionamiento":"○  Servidor no disponible";health.Foreground=local?new SolidColorBrush(Color.FromRgb(160,201,145)):accent;
          content.Children.Add(Label(remote?"Acceso por internet disponible":"No se ha podido verificar el acceso por internet",15,muted));
          if(!String.IsNullOrEmpty(prefs.Endpoint))Action("Abrir mi biblioteca ↗",()=>{Open(Backend.CanonicalEndpoint(prefs.Endpoint));return Task.FromResult(0);},true);
          Rule();content.Children.Add(Label("Servicios",20));
          try {
            var data=await Backend.Compose(prefs,"ps --format json",12);
            foreach(var line in data.Split(new[]{'\r','\n'},StringSplitOptions.RemoveEmptyEntries)){
              var row=Backend.Json.Deserialize<Dictionary<string,object>>(line);var service=Convert.ToString(row.ContainsKey("Service")?row["Service"]:"");var names=new Dictionary<string,string>{{"immich-server","Biblioteca"},{"immich-machine-learning","Análisis de fotos"},{"database","Base de datos"},{"redis","Cola de tareas"},{"caddy","Conexión segura"}};var state=Convert.ToString(row.ContainsKey("State")?row["State"]:"");content.Children.Add(Label((names.ContainsKey(service)?names[service]:service)+"   ·   "+(state=="running"?"Activo":state),15,muted));
            }
          }catch(Exception ex){content.Children.Add(Label(ex.Message,15,muted));}
          Action("Encender servidor",async()=>{
            await Backend.StartManaged(prefs,text=>Dispatcher.Invoke(()=>notice.Text=text));notice.Text="Biblioteca disponible.";
          });
          Action("Actualizar estado",async()=>{notice.Text="";await Render();});
        } else if(page=="Discos") {
          Heading("Almacenamiento","Espacio real de los volúmenes conectados a este PC.");
          foreach(var disk in await Task.Run(()=>Backend.Disks())){
            content.Children.Add(Label(disk.Root+"  "+disk.Name,22));
            content.Children.Add(Label(Backend.Size(disk.Total-disk.Free)+" usados   /   "+Backend.Size(disk.Total)+" totales",15,muted));
            content.Children.Add(new ProgressBar{Minimum=0,Maximum=disk.Total,Value=disk.Total-disk.Free,Height=7,Foreground=accent,Background=new SolidColorBrush(Color.FromRgb(49,42,35)),BorderThickness=new Thickness(0),Margin=new Thickness(0,4,0,12)});
            content.Children.Add(Label(Backend.Size(disk.Free)+" disponibles",14,muted));Rule();
          }
          content.Children.Add(Label("Discos físicos",20));content.Children.Add(Label(await Task.Run(()=>Backend.PhysicalDisks()),14,muted));
          content.Children.Add(Label("Espacio protegido / RAID",20));content.Children.Add(Label("Crea un espejo o un grupo de paridad, o añade discos vacíos a un grupo de Inhouse Photos. Los discos con datos no son seleccionables.",15,muted));
          Action("Configurar discos protegidos",()=>{Process.Start(new ProcessStartInfo(typeof(Program).Assembly.Location,"--storage"){UseShellExecute=true,Verb="runas",WindowStyle=ProcessWindowStyle.Normal});return Task.FromResult(0);});
        } else if(page=="Protección") {
          Heading("Copia de seguridad","Conserva una segunda copia. RAID no protege frente a borrados accidentales.");
          content.Children.Add(Label("Biblioteca + base de datos",22));content.Children.Add(Label("Copia los archivos nuevos a otro disco sin replicar borrados ni sobrescribir archivos. Al finalizar guarda una copia de la base de datos. Evita editar o subir fotos mientras se ejecuta esta primera copia.",15,muted));
          var destination=Label(String.IsNullOrEmpty(prefs.BackupDestination)?"Ningún destino seleccionado":prefs.BackupDestination,15,accent);content.Children.Add(destination);
          Action("Elegir disco de copia",()=>{var path=PickFolder();if(path!=null){Backend.ValidateBackup(Backend.Library(prefs),path);prefs.BackupDestination=path;Backend.Save(prefs);destination.Text=path;notice.Text="Destino guardado. No se ha movido ni borrado ningún archivo.";}return Task.FromResult(0);});
          Action("Crear copia ahora",async()=>{if(!Confirm("Se copiarán archivos a otro disco y la base de datos. Puede tardar bastante. No se eliminará ni sobrescribirá nada. Evita editar la biblioteca durante la copia. ¿Continuar?")){notice.Text="Cancelado.";return;}backupCancellation=new CancellationTokenSource();try{var result=await Backend.Backup(prefs,text=>Dispatcher.Invoke(()=>notice.Text=text),backupCancellation.Token);notice.Text="Copia terminada en "+result+". Conserva este disco separado del servidor.";}finally{backupCancellation.Dispose();backupCancellation=null;}},true);
          var cancelBackup=new Button{Content="Detener copia",HorizontalAlignment=HorizontalAlignment.Left};cancelBackup.Click+=(s,e)=>{if(backupCancellation!=null){backupCancellation.Cancel();notice.Text="Deteniendo la copia sin borrar lo que ya se ha copiado…";}};content.Children.Add(cancelBackup);
          Rule();content.Children.Add(Label("Solo base de datos",20));content.Children.Add(Label("Guarda álbumes y metadatos, pero no las fotos ni los vídeos. No basta para recuperar la biblioteca.",15,muted));
          Action("Guardar instantánea",async()=>{notice.Text="Instantánea guardada: "+await Backend.Snapshot(prefs);});
          content.Children.Add(Label("Protecciones activas",20));content.Children.Add(Label("Sin botones para borrar la biblioteca, formatear discos o eliminar volúmenes. Las copias no propagan borrados. Cambiar la configuración no mueve tus fotos.",15,muted));
        } else if(page=="Conectar") {
          Heading("Tu móvil, conectado","Usa la misma dirección y cuenta de tu biblioteca actual.");
          content.Children.Add(Label(String.IsNullOrEmpty(prefs.Endpoint)?"Configura primero la dirección del servidor.":prefs.Endpoint,23,accent));
          Action("Copiar dirección",()=>{Clipboard.SetText(Backend.CanonicalEndpoint(prefs.Endpoint));notice.Text="Dirección copiada. Pégala en la pantalla de conexión de Inhouse Photos.";return Task.FromResult(0);},true);
          Action("Abrir descargas",()=>{Open(Backend.CanonicalEndpoint(prefs.Endpoint)+"/descargas/");return Task.FromResult(0);});
          Rule();content.Children.Add(Label("1. Instala Inhouse Photos en el móvil.\n2. Introduce la dirección de arriba.\n3. Inicia sesión con tu cuenta existente.\n4. Elige los álbumes que quieres respaldar.",17));
          content.Children.Add(Label("El instalador no contiene contraseñas. No se cambia ninguna cuenta ni se publica acceso a tus fotos.",15,muted));
        } else {
          Heading("Configuración","Vincula una instalación existente sin cambiar sus datos.");
          content.Children.Add(Label("Carpeta del servidor",18));var folder=Label(prefs.Installation??"",15,accent);content.Children.Add(folder);
          Action("Seleccionar instalación",()=>{var path=PickFolder();if(path!=null){if(!File.Exists(Path.Combine(path,"docker-compose.yml")))throw new InvalidOperationException("Esta carpeta no contiene docker-compose.yml.");if(Confirm("¿Confiar en esta instalación? Inhouse ejecutará sus servicios cuando pulses Encender servidor.")){prefs.Installation=path;Backend.Save(prefs);folder.Text=path;}}return Task.FromResult(0);});
          content.Children.Add(Label("Dirección de la biblioteca",18));var endpoint=new TextBox{Text=prefs.Endpoint??"",Padding=new Thickness(12),FontSize=16,Margin=new Thickness(0,4,0,10)};content.Children.Add(endpoint);
          Action("Comprobar y guardar dirección",async()=>{var url=Backend.CanonicalEndpoint(endpoint.Text);if(!await Backend.Ping(url))throw new InvalidOperationException("No responde un servidor compatible en esa dirección. No se ha guardado.");prefs.Endpoint=url;Backend.Save(prefs);notice.Text="Conexión verificada y guardada.";},true);
          await RenderManagement();
          Rule();content.Children.Add(Label("Inhouse Photos Server "+Backend.Version,16));
        }
      }catch(Exception ex){content.Children.Add(Label(ex.Message,16,accent));}finally{refreshing=false;foreach(var tab in tabs.Values)tab.IsEnabled=true;}
    }
  }
  public static class Program {
    [STAThread] public static int Main(string[] args){
      ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;
      if(args.Contains("--storage")){return new Application().Run(new StorageWindow());}
      if(args.Contains("--adopt-current")||args.Contains("--verify-installation")||args.Contains("--start-once")||args.Contains("--enable-startup")||args.Contains("--disable-startup")) {
        try {
          var prefs=Backend.Load();
          if(args.Contains("--adopt-current"))Backend.Adopt(prefs,Console.WriteLine).GetAwaiter().GetResult();
          else if(args.Contains("--start-once"))Backend.StartManaged(prefs,Console.WriteLine).GetAwaiter().GetResult();
          else if(args.Contains("--enable-startup")||args.Contains("--disable-startup"))Startup.SetEnabled(prefs,args.Contains("--enable-startup")).GetAwaiter().GetResult();
          else {Backend.ValidateManagedConfiguration(prefs);var receipt=Backend.Json.Deserialize<AdoptionReceipt>(File.ReadAllText(prefs.ReceiptPath));Backend.AssertIdentity(receipt.Containers,Backend.InspectServer(prefs).GetAwaiter().GetResult());if(Backend.Hash(receipt.Snapshot)!=receipt.SnapshotSha256)throw new IOException("La instantánea ha cambiado.");}
          Console.WriteLine("Verificado: "+prefs.ReceiptPath);return 0;
        }catch(Exception ex){Console.Error.WriteLine(ex.Message);return 20;}
      }
      if(args.Contains("--self-test")){
        try {
          var mountA=new ServerMount{Type="bind",Source="D:/library",Destination="/data",RW=true};
          var mountB=new ServerMount{Type="volume",Name="database",Source="/volumes/db",Destination="/db",RW=true};
          var firstIdentity=new List<ServerContainer>{new ServerContainer{Id="same",Image="image",Service="server",Project="photos",Mounts=new[]{mountA,mountB}}};
          var reorderedIdentity=new List<ServerContainer>{new ServerContainer{Id="same",Image="image",Service="server",Project="photos",Mounts=new[]{mountB,mountA}}};
          Backend.AssertIdentity(firstIdentity,reorderedIdentity);
          reorderedIdentity[0].Id="replacement";
          try{Backend.AssertIdentity(firstIdentity,reorderedIdentity);return 11;}catch(InvalidOperationException){}
          reorderedIdentity[0].Id="same";
          reorderedIdentity[0].Mounts=new[]{new ServerMount{Type="bind",Source="D:/different",Destination="/data",RW=true},mountB};
          try{Backend.AssertIdentity(firstIdentity,reorderedIdentity);return 12;}catch(InvalidOperationException){}
          if(Backend.CanonicalEndpoint("https://example.com/")!="https://example.com")return 1;
          foreach(var bad in new[]{null,"","http://example.com","https://user:password@example.com","file:///D:/Immich","https://example.com?key=secret"}){try{Backend.CanonicalEndpoint(bad);return 2;}catch(ArgumentException){}}
          foreach(var bad in new[]{@"D:\photos\backup",@"D:\other",@"D:\"}){try{Backend.ValidateBackup(@"D:\photos",bad);return 3;}catch(InvalidOperationException){}}
          Backend.ValidateBackup(@"D:\photos",@"E:\backups");
          if(Backend.Quote(@"E:\")!="\"E:\\\\\"")return 4;
          foreach(var bad in new[]{null,"","folder\"name","folder\nname"}){try{Backend.Quote(bad);return 5;}catch(ArgumentException){}}
          return 0;
        }catch{return 10;}
      }
      bool first;
      using(var singleInstance=new Mutex(true,@"Local\InhousePhotosServer",out first)) {
      if(!first){if(!args.Contains("--startup")){try{using(var activate=EventWaitHandle.OpenExisting(@"Local\InhousePhotosServer.Activate"))activate.Set();}catch{}}return 0;}
      var app=new Application();var window=new ServerWindow();
      if(args.Length==2&&args[0]=="--render-preview"){
        app.Dispatcher.BeginInvoke(new Action(async()=>{await window.Render();var root=(FrameworkElement)window.Content;root.Width=1080;root.Height=760;root.Measure(new Size(1080,760));root.Arrange(new Rect(0,0,1080,760));root.UpdateLayout();var bmp=new RenderTargetBitmap(1080,760,96,96,PixelFormats.Pbgra32);bmp.Render(root);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bmp));using(var stream=File.Create(args[1]))encoder.Save(stream);app.Shutdown();}));app.Run();return 0;
      }
      app.DispatcherUnhandledException+=(s,e)=>{MessageBox.Show("No se pudo completar la operación. Reinicia la aplicación; no se ha solicitado borrar datos.","Inhouse Photos");e.Handled=true;};
      var hidden=args.Contains("--startup");window.InitializeLifecycle(hidden);
      using(var activate=new EventWaitHandle(false,EventResetMode.AutoReset,@"Local\InhousePhotosServer.Activate")) {
        var registration=ThreadPool.RegisterWaitForSingleObject(activate,(s,t)=>app.Dispatcher.BeginInvoke(new Action(window.BringToFront)),null,-1,false);
        try{app.ShutdownMode=ShutdownMode.OnMainWindowClose;app.MainWindow=window;if(!hidden)window.Show();return app.Run();}finally{registration.Unregister(null);}
      }
      }
    }
  }
}
