using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.ComponentModel;
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
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Markup;
using System.Windows.Threading;

[assembly: System.Reflection.AssemblyTitle("Inhouse Photos Server")]
[assembly: System.Reflection.AssemblyVersion("1.2.13.0")]

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
      throw new InvalidOperationException("Falta el motor del servidor. Abre Crear una biblioteca nueva para preparar este ordenador.");
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
          if (process.ExitCode != 0) {
            try{PrivateDirectory(Path.Combine(SettingsDir,"diagnostics"));File.WriteAllText(Path.Combine(SettingsDir,"diagnostics","last-operation.txt"),details);}catch{}
            throw new InvalidOperationException("El servidor no pudo completar la operación (código " + process.ExitCode + "). No se ha solicitado borrar datos. Puedes reintentarlo; el diagnóstico se guarda solo en este PC.");
          }
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
        var pending=req.GetResponseAsync();
        if(await Task.WhenAny(pending,Task.Delay(5000))!=pending){req.Abort();try{await pending;}catch{}return false;}
        using (var response = await pending) using (var reader=new StreamReader(response.GetResponseStream())) {
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
        throw new InvalidOperationException("Elige otra unidad para la copia. No puede estar dentro de la biblioteca ni en su mismo volumen.");
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
    public static Task<string> Snapshot(Preferences p) { return Snapshot(p,CancellationToken.None); }
    public static async Task<string> Snapshot(Preferences p,CancellationToken cancellation) {
      cancellation.ThrowIfCancellationRequested();
      var directory=Path.Combine(p.Installation,@"operations\backups"); Directory.CreateDirectory(directory);
      var file=Path.Combine(directory,"inhouse-"+DateTime.UtcNow.ToString("yyyyMMdd-HHmmss-fff")+"-"+Guid.NewGuid().ToString("N")+".sql");
      var partial=file+".partial";
      // Shell is inside the selected database container; variables are expanded
      // there, never exposed to this process, UI or the release artifact.
      try {
        await Task.Run(async delegate {
        using(var process=new Process()) {
          var args="compose --project-directory "+Quote(p.Installation)+" -f "+Quote(Path.Combine(p.Installation,"docker-compose.yml"))+" exec -T database sh -c "+Quote("exec pg_dump --username=$POSTGRES_USER --dbname=$POSTGRES_DB --no-owner --no-acl");
          process.StartInfo=new ProcessStartInfo(DockerExe(),args){WorkingDirectory=p.Installation,UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden,RedirectStandardOutput=true,RedirectStandardError=true};
          process.Start();
          using(var stop=cancellation.Register(()=>{try{if(!process.HasExited)process.Kill();}catch{}})) {
            var error=process.StandardError.ReadToEndAsync();
            using(var output=new FileStream(partial,FileMode.CreateNew,FileAccess.Write,FileShare.None,65536,true)) {
              var copy=process.StandardOutput.BaseStream.CopyToAsync(output,65536,cancellation);
              if(await Task.WhenAny(copy,Task.Delay(TimeSpan.FromMinutes(15),cancellation))!=copy){try{process.Kill();}catch{}cancellation.ThrowIfCancellationRequested();throw new TimeoutException("Instantánea incompleta: tiempo agotado.");}
              await copy;
            }
            cancellation.ThrowIfCancellationRequested();
            if(!process.WaitForExit(30000)){try{process.Kill();}catch{}throw new TimeoutException("La base de datos no confirmó el final de la instantánea.");}
            await error;cancellation.ThrowIfCancellationRequested();
            if(process.ExitCode!=0)throw new IOException("La instantánea no se completó. El archivo parcial no es una copia válida.");
          }
        }
        },cancellation);
        cancellation.ThrowIfCancellationRequested();
        using(var reader=new StreamReader(partial)){var header=new char[200];var count=reader.Read(header,0,header.Length);if(!new string(header,0,count).Contains("PostgreSQL database dump"))throw new IOException("La instantánea no es válida.");}
        File.Move(partial,file); return file;
      } catch {
        try{if(File.Exists(partial))File.Delete(partial);}catch{}
        cancellation.ThrowIfCancellationRequested();
        throw;
      }
    }
    public static async Task<string> Backup(Preferences p, Action<string> progress, CancellationToken cancellation) {
      ValidateManagedConfiguration(p);
      var receipt=Json.Deserialize<AdoptionReceipt>(File.ReadAllText(p.ReceiptPath));
      AssertManagedIdentity(p,receipt.Containers,await InspectServer(p));
      var source=Library(p); ValidateBackup(source,p.BackupDestination);
      var target=Path.Combine(p.BackupDestination,"Inhouse Photos backup");
      progress("Comprobando archivos y espacio del disco de copia…");
      var capacity=await Task.Run(()=>EstimateBackupCapacity(source,target,cancellation,
        count=>progress("Comprobando espacio · "+count.ToString("N0")+" archivos revisados…")),cancellation);
      if(!capacity.EnoughSpace)throw new InsufficientBackupSpaceException(capacity);
      await Task.Run(()=>{cancellation.ThrowIfCancellationRequested();RejectNestedLinks(target);Directory.CreateDirectory(target);},cancellation);
      cancellation.ThrowIfCancellationRequested();
      // Database first, media second: if uploads continue, the copied media
      // can contain extra files, but the database should not refer to media
      // that had not yet been copied. This follows Immich's backup ordering.
      progress("1 de 3 · Guardando álbumes y cuentas…");
      var snapshot=await Snapshot(p,cancellation);
      cancellation.ThrowIfCancellationRequested();
      var databaseCopy=Path.Combine(target,Path.GetFileName(snapshot));
      var databasePartial=databaseCopy+".partial";
      try {
        using(var input=new FileStream(snapshot,FileMode.Open,FileAccess.Read,FileShare.Read,65536,true))
        using(var output=new FileStream(databasePartial,FileMode.CreateNew,FileAccess.Write,FileShare.None,65536,true))
          await input.CopyToAsync(output,65536,cancellation);
        cancellation.ThrowIfCancellationRequested();
        File.Move(databasePartial,databaseCopy);
      } catch {
        try{if(File.Exists(databasePartial))File.Delete(databasePartial);}catch{}
        cancellation.ThrowIfCancellationRequested();
        throw;
      }
      cancellation.ThrowIfCancellationRequested();
      progress("2 de 3 · Copiando fotos y vídeos nuevos…");
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
      if(code>=4) throw new IOException("Algunos archivos no se copiaron o no coinciden. La copia no está completa. Revisa el disco de destino y vuelve a intentarlo.");
      cancellation.ThrowIfCancellationRequested();
      progress("3 de 3 · Comprobando los archivos de la copia…");
      await Task.Run(()=>VerifyPendingBackupFiles(capacity,cancellation,
        count=>progress("3 de 3 · "+count.ToString("N0")+" archivos comprobados…")),cancellation);
      cancellation.ThrowIfCancellationRequested();
      SaveFullBackupSuccess(p,target,databaseCopy);
      return target;
    }
  }
  public sealed partial class ServerWindow : Window {
    Preferences prefs=Backend.Load();
    readonly StackPanel content=new StackPanel();
    readonly TranslateTransform contentMotion=new TranslateTransform();
    readonly TextBlock notice=new TextBlock();
    readonly Dictionary<string,Button> tabs=new Dictionary<string,Button>();
    readonly Dictionary<string,Border> navRails=new Dictionary<string,Border>();
    readonly Dictionary<string,TextBlock> navTitles=new Dictionary<string,TextBlock>();
    readonly TextBlock sidebarLocation=new TextBlock();
    string page="Inicio"; bool busy, refreshing;
    string renderedPage;
    internal bool DisableTransitions {get;set;}
    CancellationTokenSource backupCancellation;
    readonly Brush accent=new SolidColorBrush(Color.FromRgb(169,71,18));
    readonly Brush muted=new SolidColorBrush(Color.FromRgb(104,95,85));
    readonly Brush line=new SolidColorBrush(Color.FromRgb(220,213,203));
    public ServerWindow() {
      var workWidth=Math.Max(320,SystemParameters.WorkArea.Width-28);
      var workHeight=Math.Max(320,SystemParameters.WorkArea.Height-28);
      Title="Inhouse Photos Server"; Width=Math.Min(1080,workWidth);Height=Math.Min(760,workHeight);
      MinWidth=Math.Min(760,workWidth);MinHeight=Math.Min(500,workHeight);
      Background=new SolidColorBrush(Color.FromRgb(246,243,238));Foreground=new SolidColorBrush(Color.FromRgb(32,28,24));FontFamily=new FontFamily("Segoe UI");FontSize=14;WindowStartupLocation=WindowStartupLocation.CenterScreen;
      Resources.Add(typeof(Button),XamlReader.Parse(@"<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='Button'><Setter Property='Background' Value='#FFFCF8'/><Setter Property='Foreground' Value='#201C18'/><Setter Property='BorderBrush' Value='#DCD5CB'/><Setter Property='BorderThickness' Value='1'/><Setter Property='Padding' Value='16,9'/><Setter Property='Margin' Value='0,5,8,5'/><Setter Property='MinHeight' Value='38'/><Setter Property='FontWeight' Value='SemiBold'/><Setter Property='Cursor' Value='Hand'/><Setter Property='HorizontalContentAlignment' Value='Left'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Button'><Border x:Name='bg' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' Padding='{TemplateBinding Padding}' CornerRadius='8'><ContentPresenter HorizontalAlignment='{TemplateBinding HorizontalContentAlignment}' VerticalAlignment='Center'/></Border><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='bg' Property='BorderBrush' Value='#A94712'/></Trigger><Trigger Property='IsPressed' Value='True'><Setter TargetName='bg' Property='Opacity' Value='0.72'/></Trigger><Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='bg' Property='BorderBrush' Value='#A94712'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter TargetName='bg' Property='Opacity' Value='0.4'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>"));
      var root=new Grid{Background=Background}; root.ColumnDefinitions.Add(new ColumnDefinition {Width=new GridLength(236)});root.ColumnDefinitions.Add(new ColumnDefinition());Content=root;
      var sidebarShell=new Border{Background=new SolidColorBrush(Color.FromRgb(239,234,227)),BorderBrush=line,BorderThickness=new Thickness(0,0,1,0)};
      root.Children.Add(sidebarShell);
      var sidebar=new Grid{Margin=new Thickness(20,27,18,22)};sidebar.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});sidebar.RowDefinitions.Add(new RowDefinition());sidebar.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});sidebarShell.Child=sidebar;
      var brandBlock=new StackPanel();Grid.SetRow(brandBlock,0);sidebar.Children.Add(brandBlock);
      using(var brandStream=typeof(ServerWindow).Assembly.GetManifestResourceStream("InhousePhotos.brand.xaml"))Icon=(ImageSource)XamlReader.Load(brandStream);
      brandBlock.Children.Add(new Image{Source=Icon,Width=44,Height=44,HorizontalAlignment=HorizontalAlignment.Left,Margin=new Thickness(3,0,0,9)});
      brandBlock.Children.Add(Label("inhouse photos",20,Foreground));
      var navigation=new StackPanel{Margin=new Thickness(0,26,0,0)};
      var navScroll=new ScrollViewer{Content=navigation,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};
      Grid.SetRow(navScroll,1);sidebar.Children.Add(navScroll);
      var navLabels=new Dictionary<string,string>{{"Inicio","Resumen"},{"Conectar","Conectar móvil"},{"Protección","Copias"},{"Discos","Almacenamiento"},{"Configuración","Ajustes"}};
      foreach(var name in new[]{"Inicio","Conectar","Protección","Discos","Configuración"}) {
        var captured=name;var row=new Grid();row.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(4)});row.ColumnDefinitions.Add(new ColumnDefinition());
        var rail=new Border{Width=3,Height=22,CornerRadius=new CornerRadius(2),Background=accent,Visibility=Visibility.Hidden,VerticalAlignment=VerticalAlignment.Center};row.Children.Add(rail);
        var title=new TextBlock{Text=navLabels[name],FontSize=14,VerticalAlignment=VerticalAlignment.Center,Margin=new Thickness(12,0,0,0)};Grid.SetColumn(title,1);row.Children.Add(title);
        var button=new Button{Content=row,Background=Brushes.Transparent,BorderBrush=Brushes.Transparent,BorderThickness=new Thickness(1),Padding=new Thickness(12,8,8,8),Margin=new Thickness(0,2,0,2),HorizontalContentAlignment=HorizontalAlignment.Stretch};
        button.Click+=async(s,e)=>{if(!busy||backupCancellation!=null){page=captured;notice.Text="";await Render();}};
        tabs[name]=button;navRails[name]=rail;navTitles[name]=title;navigation.Children.Add(button);
      }
      var footer=new StackPanel();Grid.SetRow(footer,2);sidebar.Children.Add(footer);
      footer.Children.Add(new Border{Height=1,Background=line,Margin=new Thickness(0,0,0,14)});
      footer.Children.Add(Label("Biblioteca en este PC",12,muted));
      sidebarLocation.FontSize=12;sidebarLocation.Foreground=Foreground;sidebarLocation.TextTrimming=TextTrimming.CharacterEllipsis;sidebarLocation.Margin=new Thickness(0,0,0,7);footer.Children.Add(sidebarLocation);
      footer.Children.Add(Label("Versión "+Backend.Version,11,muted));
      var right=new DockPanel{Margin=new Thickness(32,29,36,24)};Grid.SetColumn(right,1);root.Children.Add(right);
      notice.TextWrapping=TextWrapping.Wrap;notice.Foreground=Foreground;notice.FontSize=14;
      var noticePanel=new Border{Background=new SolidColorBrush(Color.FromRgb(246,231,216)),BorderBrush=accent,BorderThickness=new Thickness(3,0,0,0),CornerRadius=new CornerRadius(6),Padding=new Thickness(14,10,14,10),Margin=new Thickness(0,10,0,0),Child=notice,Visibility=Visibility.Collapsed};
      DependencyPropertyDescriptor.FromProperty(TextBlock.TextProperty,typeof(TextBlock)).AddValueChanged(notice,(s,e)=>noticePanel.Visibility=String.IsNullOrWhiteSpace(notice.Text)?Visibility.Collapsed:Visibility.Visible);
      DockPanel.SetDock(noticePanel,Dock.Bottom);right.Children.Add(noticePanel);
      content.RenderTransform=contentMotion;
      right.Children.Add(new ScrollViewer{Content=content,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled});
      Loaded+=async(s,e)=>await Render();
      Closing+=(s,e)=>{if(busy){e.Cancel=true;notice.Text="Espera a que termine la operación antes de cerrar.";}};
      // Do not destroy and rebuild a visible page on a timer: it resets scroll
      // position and makes controls disappear while someone is using them.
    }
    TextBlock Label(string text,double size,Brush color=null) {return new TextBlock{Text=text,FontSize=size,Foreground=color??Foreground,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,10)};}
    void Heading(string text,string description){var title=Label(text,30);title.FontWeight=FontWeights.SemiBold;title.Margin=new Thickness(0,0,0,5);content.Children.Add(title);content.Children.Add(Label(description,14,muted));content.Children.Add(new Border{Height=18});}
    void Rule(){content.Children.Add(new Border{Height=1,Background=line,Margin=new Thickness(0,18,0,20)});}
    Button Action(string title,Func<Task> task,bool primary=false) {
      var button=new Button{Content=title,HorizontalAlignment=HorizontalAlignment.Left};if(primary){button.Background=accent;button.BorderBrush=accent;button.Foreground=Brushes.White;}
      button.Click+=async(s,e)=>{if(busy)return;busy=true;button.IsEnabled=false;notice.Text="Trabajando…";try{await task();if(notice.Text=="Trabajando…")notice.Text="";}catch(Exception ex){notice.Text=ex.Message;}finally{busy=false;button.IsEnabled=true;}};content.Children.Add(button);return button;
    }
    string PickFolder(){using(var dialog=new System.Windows.Forms.FolderBrowserDialog()){dialog.Description="Selecciona una carpeta";return dialog.ShowDialog()==System.Windows.Forms.DialogResult.OK?dialog.SelectedPath:null;}}
    bool Confirm(string message){return MessageBox.Show(this,message,"Inhouse Photos",MessageBoxButton.OKCancel,MessageBoxImage.Warning)==MessageBoxResult.OK;}
    void Open(string url){Process.Start(new ProcessStartInfo(url){UseShellExecute=true});}
    internal void PreviewPage(string target) { if(!tabs.ContainsKey(target))throw new ArgumentException("Unknown preview page");page=target; }
    internal void PreviewMigration() {prefs=new Preferences{Installation=@"D:\Immich",Managed=false,Endpoint="",LocalEndpoint="http://127.0.0.1:2283"};busy=true;page="Inicio";}
    public async Task Render(){
      if(refreshing)return;
      if(!busy)prefs=Backend.Load();
      if(!prefs.Managed)page="Inicio";
      var pageChanged=renderedPage!=null&&!String.Equals(renderedPage,page,StringComparison.Ordinal);
      try{
        var library=prefs.Managed?Backend.Library(prefs):null;
        sidebarLocation.Text=prefs.Managed?"Fotos en "+Path.GetPathRoot(library).TrimEnd('\\'):"Aún sin conectar";
        sidebarLocation.ToolTip=library??sidebarLocation.Text;
      }
      catch{sidebarLocation.Text="Biblioteca no disponible";sidebarLocation.ToolTip=null;}
      refreshing=true;
      // A refresh must never inherit an unfinished page animation.
      content.BeginAnimation(UIElement.OpacityProperty,null);
      contentMotion.BeginAnimation(TranslateTransform.YProperty,null);
      content.Opacity=1;
      contentMotion.Y=0;
      content.Children.Clear();
      foreach(var item in tabs) {
        item.Value.IsEnabled=false;
        item.Value.Visibility=prefs.Managed||item.Key=="Inicio"?Visibility.Visible:Visibility.Collapsed;
        var selected=item.Key==page;
        item.Value.Foreground=selected?Foreground:muted;
        item.Value.Background=selected?new SolidColorBrush(Color.FromRgb(240,225,211)):Brushes.Transparent;
        navRails[item.Key].Visibility=selected?Visibility.Visible:Visibility.Hidden;
        navTitles[item.Key].Foreground=selected?Foreground:muted;
      }
      var pageRendered=false;
      try {
        if(prefs.Managed)await RenderManagedPage();
        else await RenderSimpleHome();
        pageRendered=true;
      } catch(Exception ex) {
        content.Children.Add(Label(ex.Message,16,accent));
      } finally {
        if(pageRendered&&pageChanged&&!DisableTransitions&&SystemParameters.ClientAreaAnimation){
          var duration=new Duration(TimeSpan.FromMilliseconds(160));
          var easing=new QuadraticEase{EasingMode=EasingMode.EaseOut};
          content.BeginAnimation(UIElement.OpacityProperty,new DoubleAnimation(0,1,duration){EasingFunction=easing,FillBehavior=FillBehavior.Stop});
          contentMotion.BeginAnimation(TranslateTransform.YProperty,new DoubleAnimation(7,0,duration){EasingFunction=easing,FillBehavior=FillBehavior.Stop});
        }
        renderedPage=page;
        refreshing=false;
        foreach(var item in tabs)item.Value.IsEnabled=prefs.Managed||item.Key=="Inicio";
      }
    }
  }
  public static class Program {
    [STAThread] public static int Main(string[] args){
      PairingClient.RegisterQrAssembly();
      ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;
      if(args.Length==2&&args[0]=="--render-setup-preview") {
        var previewApp=new Application();var setupWindow=new NewServerWindow();
        previewApp.Dispatcher.BeginInvoke(new Action(()=>{var root=(FrameworkElement)setupWindow.Content;root.Width=660;root.Height=1000;root.Measure(new Size(660,1000));root.Arrange(new Rect(0,0,660,1000));root.UpdateLayout();var bmp=new RenderTargetBitmap(660,1000,96,96,PixelFormats.Pbgra32);bmp.Render(root);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bmp));using(var stream=File.Create(args[1]))encoder.Save(stream);previewApp.Shutdown();}));return previewApp.Run();
      }
      if(args.Length==3&&args[0]=="--verify-recovery") {
        try{Backend.VerifyRestore(args[1],"sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23",args[2],Console.WriteLine).GetAwaiter().GetResult();return 0;}catch(Exception ex){Console.Error.WriteLine(ex.Message);return 22;}
      }
      if(args.Length==2&&args[0]=="--new-server-smoke") {
        try {
          var leaf=Path.GetFileName(args[1].TrimEnd('\\'));
          if(!System.Text.RegularExpressions.Regex.IsMatch(leaf,"^Inhouse-Setup-Test-[a-f0-9]{8}$"))throw new ArgumentException("Use an isolated Inhouse-Setup-Test-xxxxxxxx directory.");
          var secretDirectory=Path.Combine(Backend.SettingsDir,"test-secrets");Backend.PrivateDirectory(secretDirectory);var secretPath=Path.Combine(secretDirectory,leaf+".dpapi");
          string secret;
          if(File.Exists(secretPath))secret=Encoding.UTF8.GetString(System.Security.Cryptography.ProtectedData.Unprotect(File.ReadAllBytes(secretPath),null,System.Security.Cryptography.DataProtectionScope.CurrentUser));
          else {secret=Backend.RandomHex(24);File.WriteAllBytes(secretPath,System.Security.Cryptography.ProtectedData.Protect(Encoding.UTF8.GetBytes(secret),null,System.Security.Cryptography.DataProtectionScope.CurrentUser));}
          var p=NewServer.Create(args[1],"setup-check@example.invalid",secret,"Setup validation","",Console.WriteLine,false).GetAwaiter().GetResult();
          File.WriteAllText(Path.Combine(p.Installation,"test-result.json"),Backend.Json.Serialize(p));
          Console.WriteLine("Nueva biblioteca verificada: "+p.ProjectName);return 0;
        }catch(Exception ex){Console.Error.WriteLine(ex.Message);return 21;}
      }
      if(args.Contains("--storage")){return new Application().Run(new StorageWindow());}
      if(args.Contains("--adopt-current")||args.Contains("--reverify-current")||args.Contains("--verify-installation")||args.Contains("--start-once")||args.Contains("--enable-startup")||args.Contains("--disable-startup")) {
        try {
          var prefs=Backend.Load();
          if(args.Contains("--adopt-current"))Backend.Adopt(prefs,Console.WriteLine).GetAwaiter().GetResult();
          else if(args.Contains("--reverify-current"))Backend.ReverifyExisting(prefs,Console.WriteLine).GetAwaiter().GetResult();
          else if(args.Contains("--start-once"))Backend.StartManaged(prefs,Console.WriteLine).GetAwaiter().GetResult();
          else if(args.Contains("--enable-startup")||args.Contains("--disable-startup"))Startup.SetEnabled(prefs,args.Contains("--enable-startup")).GetAwaiter().GetResult();
          else {Backend.ValidateManagedConfiguration(prefs);var receipt=Backend.Json.Deserialize<AdoptionReceipt>(File.ReadAllText(prefs.ReceiptPath));Backend.AssertManagedIdentity(prefs,receipt.Containers,Backend.InspectServer(prefs).GetAwaiter().GetResult());if(Backend.Hash(receipt.Snapshot)!=receipt.SnapshotSha256)throw new IOException("La instantánea ha cambiado.");}
          Console.WriteLine("Verificado: "+prefs.ReceiptPath);return 0;
        }catch(Exception ex){Console.Error.WriteLine(ex.Message);return 20;}
      }
      if(args.Contains("--self-test")){
        try {
          var sample=Path.Combine(Path.GetTempPath(),"inhouse-validation-only");
          NewServer.Validate(sample,"test@example.com","test-password-long","Test","");
          foreach(var bad in new[]{"https://photos.example.com","a.example.com/route","a.example.com\nextra",""}) {
            if(bad=="")continue;
            try{NewServer.Validate(sample,"test@example.com","test-password-long","Test",bad);return 13;}catch(ArgumentException){}
          }
          try{NewServer.Validate(Path.GetPathRoot(sample),"test@example.com","test-password-long","Test","");return 14;}catch(ArgumentException){}
          if(NewServer.ComposeText(false).Contains("container_name:")||NewServer.ComposeText(false).Contains("443:443"))return 15;
          var mountA=new ServerMount{Type="bind",Source="D:/library",Destination="/data",RW=true};
          var mountB=new ServerMount{Type="volume",Name="database",Source="/volumes/db",Destination="/var/lib/postgresql/data",RW=true};
          var firstIdentity=new List<ServerContainer>{new ServerContainer{Id="same",Image="image",Service="server",Project="photos",Mounts=new[]{mountA,mountB}}};
          var reorderedIdentity=new List<ServerContainer>{new ServerContainer{Id="same",Image="image",Service="server",Project="photos",Mounts=new[]{mountB,mountA}}};
          Backend.AssertIdentity(firstIdentity,reorderedIdentity);
          reorderedIdentity[0].Id="replacement";
          try{Backend.AssertIdentity(firstIdentity,reorderedIdentity);return 11;}catch(InvalidOperationException){}
          reorderedIdentity[0].Id="same";
          reorderedIdentity[0].Mounts=new[]{new ServerMount{Type="bind",Source="D:/different",Destination="/data",RW=true},mountB};
          try{Backend.AssertIdentity(firstIdentity,reorderedIdentity);return 12;}catch(InvalidOperationException){}
          var managed=new Preferences{ProjectName="photos"};
          var adopted=new List<ServerContainer>{
            new ServerContainer{Id="server-old",Image="web-old",Service="immich-server",Project="photos",Mounts=new[]{mountA}},
            new ServerContainer{Id="db-old",Image="postgres-stable",Service="database",Project="photos",Mounts=new[]{mountB}},
            new ServerContainer{Id="redis-old",Image="redis-old",Service="redis",Project="photos",Mounts=new ServerMount[0]},
            new ServerContainer{Id="ml-old",Image="ml-old",Service="immich-machine-learning",Project="photos",Mounts=new ServerMount[0]},
            new ServerContainer{Id="caddy-old",Image="caddy-old",Service="caddy",Project="photos",Mounts=new ServerMount[0]}};
          var replaced=Backend.Json.Deserialize<List<ServerContainer>>(Backend.Json.Serialize(adopted));
          foreach(var container in replaced){container.Id+="-new";if(container.Service!="database")container.Image+="-new";}
          Backend.AssertManagedIdentity(managed,adopted,replaced);
          try{Backend.AssertIdentity(adopted,replaced);return 17;}catch(InvalidOperationException){}
          replaced[0].Project="other";
          try{Backend.AssertManagedIdentity(managed,adopted,replaced);return 18;}catch(InvalidOperationException){}
          replaced[0].Project="photos";replaced[0].Mounts[0].Source="D:/different";
          try{Backend.AssertManagedIdentity(managed,adopted,replaced);return 19;}catch(InvalidOperationException){}
          replaced[0].Mounts[0].Source="D:/library";replaced[1].Mounts[0].Source="/volumes/other-db";
          try{Backend.AssertManagedIdentity(managed,adopted,replaced);return 25;}catch(InvalidOperationException){}
          replaced[1].Mounts[0].Source="/volumes/db";replaced[1].Image="postgres-other";
          try{Backend.AssertManagedIdentity(managed,adopted,replaced);return 23;}catch(InvalidOperationException){}
          replaced[1].Image="postgres-stable";replaced.RemoveAt(2);
          try{Backend.AssertManagedIdentity(managed,adopted,replaced);return 24;}catch(InvalidOperationException){}
          replaced.Add(Backend.Json.Deserialize<ServerContainer>(Backend.Json.Serialize(adopted[2])));
          adopted[1].Mounts=new ServerMount[0];replaced[1].Mounts=new ServerMount[0];
          try{Backend.AssertManagedIdentity(managed,adopted,replaced);return 26;}catch(InvalidOperationException){}
          var badDatabaseMount=new ServerMount{Type="tmpfs",Source="/volumes/db",Destination="/var/lib/postgresql/data",RW=true};
          adopted[1].Mounts=new[]{badDatabaseMount};replaced[1].Mounts=new[]{badDatabaseMount};
          try{Backend.AssertManagedIdentity(managed,adopted,replaced);return 27;}catch(InvalidOperationException){}
          badDatabaseMount.Type="volume";badDatabaseMount.Destination="/wrong-db-path";
          try{Backend.AssertManagedIdentity(managed,adopted,replaced);return 28;}catch(InvalidOperationException){}
          badDatabaseMount.Destination="/var/lib/postgresql/data";badDatabaseMount.RW=false;
          try{Backend.AssertManagedIdentity(managed,adopted,replaced);return 29;}catch(InvalidOperationException){}
          adopted[1].Mounts=new[]{mountB};replaced[1].Mounts=new[]{mountB};
          adopted[0].Mounts=new ServerMount[0];replaced[0].Mounts=new ServerMount[0];
          try{Backend.AssertManagedIdentity(managed,adopted,replaced);return 30;}catch(InvalidOperationException){}
          var badMediaMount=new ServerMount{Type="tmpfs",Source="D:/library",Destination="/data",RW=true};
          adopted[0].Mounts=new[]{badMediaMount};replaced[0].Mounts=new[]{badMediaMount};
          try{Backend.AssertManagedIdentity(managed,adopted,replaced);return 31;}catch(InvalidOperationException){}
          badMediaMount.Type="bind";badMediaMount.Destination="/wrong-media-path";
          try{Backend.AssertManagedIdentity(managed,adopted,replaced);return 32;}catch(InvalidOperationException){}
          badMediaMount.Destination="/data";badMediaMount.RW=false;
          try{Backend.AssertManagedIdentity(managed,adopted,replaced);return 33;}catch(InvalidOperationException){}
          if(Backend.CanonicalEndpoint("https://example.com/")!="https://example.com")return 1;
          foreach(var bad in new[]{null,"","http://example.com","https://user:password@example.com","file:///D:/Immich","https://example.com?key=secret"}){try{Backend.CanonicalEndpoint(bad);return 2;}catch(ArgumentException){}}
          var sampleInvite=new string('A',43);
          var pairingLink=PairingClient.Link("https://photos.example.com/",sampleInvite);
          if(pairingLink!="https://fotos.miguelcoxcaballero.com/vincular#origin=https%3A%2F%2Fphotos.example.com&invite="+sampleInvite||new Uri(pairingLink).Query!="")return 34;
          var qrPng=PairingClient.QrPng(pairingLink);
          if(qrPng.Length<500||qrPng[0]!=137||qrPng[1]!=80||qrPng[2]!=78||qrPng[3]!=71)return 35;
          if(!PairingClient.QrLicense().Contains("The MIT License"))return 38;
          foreach(var bad in new[]{"http://photos.example.com","https://user:pass@photos.example.com","https://photos.example.com?secret=1"}){
            try{PairingClient.Link(bad,sampleInvite);return 36;}catch(ArgumentException){}
          }
          try{PairingClient.Link("https://photos.example.com","short");return 37;}catch(ArgumentException){}
          if(ManagerUpdates.Compare("1.2.12","1.2.11")<=0||ManagerUpdates.Compare("1.2.12","1.2.12")!=0)return 39;
          var sampleCaddy="photos.example.com {\n handle /descargas/* {\n  file_server\n }\n handle {\n  reverse_proxy server:2283\n }\n}\n";
          var managerKey=new string('a',64);
          var withManager=RemoteManagement.WithRoute(sampleCaddy,managerKey);
          if(withManager==sampleCaddy||!withManager.Contains("reverse_proxy host.docker.internal:52187")||
             !withManager.Contains("header_up X-Inhouse-Bridge "+managerKey)||RemoteManagement.WithRoute(withManager,managerKey)!=withManager)return 40;
          try{RemoteManagement.WithRoute(sampleCaddy,"short");return 41;}catch(ArgumentException){}
          var rotatedKey=new string('b',64);
          if(RemoteManagement.WithRoute(withManager,rotatedKey)!=withManager.Replace(managerKey,rotatedKey))return 43;
          var windowsCaddy=sampleCaddy.Replace("\n","\r\n");
          var windowsRoute=RemoteManagement.WithRoute(windowsCaddy,managerKey);
          if(windowsRoute.Replace("\r\n","").Contains("\n")||RemoteManagement.WithRoute(windowsRoute,managerKey)!=windowsRoute)return 44;
          foreach(var malformed in new[]{
            sampleCaddy+"# INHOUSE-MANAGER-ROUTE-BEGIN\n",
            sampleCaddy+"# INHOUSE-MANAGER-ROUTE-END\n",
            withManager+"# INHOUSE-MANAGER-ROUTE-BEGIN\n# INHOUSE-MANAGER-ROUTE-END\n",
            sampleCaddy.Replace(" handle {"," handle {\n }\n handle {")}) {
            try{RemoteManagement.WithRoute(malformed,managerKey);return 45;}catch(IOException){}
          }
          foreach(var missing in new[]{null,"","   ","relative-backups","\0"})
            if(ServerWindow.OptionalDriveRoot(missing)!=null)return 46;
          if(ServerWindow.OptionalDriveRoot(@"E:\backups")!=@"E:\"||ServerWindow.OptionalDriveRoot(@"D:\")!=@"D:\")return 47;
          if(!RemoteManagement.Allowed("GET",RemoteManagement.StatusPath)||
             !RemoteManagement.Allowed("POST",RemoteManagement.StatusPath+"/backup/start")||
             !RemoteManagement.Allowed("POST",RemoteManagement.StatusPath+"/backup/destination/E")||
             RemoteManagement.Allowed("POST",RemoteManagement.StatusPath+"/backup/destination/../../C")||
             RemoteManagement.Allowed("GET",RemoteManagement.StatusPath+"/backup/start"))return 42;
          foreach(var bad in new[]{@"D:\photos\backup",@"D:\other",@"D:\"}){try{Backend.ValidateBackup(@"D:\photos",bad);return 3;}catch(InvalidOperationException){}}
          Backend.ValidateBackup(@"D:\photos",@"E:\backups");
          var due=DateTime.SpecifyKind(new DateTime(2026,9,27,3,0,0),DateTimeKind.Utc);
          var schedule=new BackupSchedule{Enabled=true,NextDueUtc=due.ToString("o")};
          if(Backend.IsBackupDue(schedule,due.AddTicks(-1))||!Backend.IsBackupDue(schedule,due))return 16;
          if(Backend.Quote(@"E:\")!="\"E:\\\\\"")return 4;
          foreach(var bad in new[]{null,"","folder\"name","folder\nname"}){try{Backend.Quote(bad);return 5;}catch(ArgumentException){}}
          return 0;
        }catch{return 10;}
      }
      bool first;
      bool preview=args.Length>=2&&args[0]=="--render-preview";
      using(var singleInstance=new Mutex(true,preview?@"Local\InhousePhotosPreview-"+Guid.NewGuid().ToString("N"):@"Local\InhousePhotosServer",out first)) {
      if(!first){if(!args.Contains("--startup")){try{using(var activate=EventWaitHandle.OpenExisting(@"Local\InhousePhotosServer.Activate"))activate.Set();}catch{}}return 0;}
      var app=new Application();var window=new ServerWindow();
      if(preview){
        window.DisableTransitions=true;
        window.DisablePairingRequests=true;
        var previewWidth=args.Length>=5?int.Parse(args[3]):1080;
        var previewHeight=args.Length>=5?int.Parse(args[4]):760;
        if(previewWidth<760||previewHeight<600||previewWidth>2400||previewHeight>1800)throw new ArgumentOutOfRangeException("preview","Tamaño de vista previa no válido.");
        if(args.Length>=3){if(args[2]=="Migracion")window.PreviewMigration();else window.PreviewPage(args[2]);}
        app.Dispatcher.BeginInvoke(new Action(async()=>{await window.Render();var root=(FrameworkElement)window.Content;root.Width=previewWidth;root.Height=previewHeight;root.Measure(new Size(previewWidth,previewHeight));root.Arrange(new Rect(0,0,previewWidth,previewHeight));root.UpdateLayout();var bmp=new RenderTargetBitmap(previewWidth,previewHeight,96,96,PixelFormats.Pbgra32);bmp.Render(root);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bmp));using(var stream=File.Create(args[1]))encoder.Save(stream);app.Shutdown();}));app.Run();return 0;
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
