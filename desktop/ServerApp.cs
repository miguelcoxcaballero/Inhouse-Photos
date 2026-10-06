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
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Markup;
using System.Windows.Threading;

[assembly: System.Reflection.AssemblyTitle("Inhouse Photos Server")]
[assembly: System.Reflection.AssemblyVersion("3.1.99.0")]

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
    readonly Dictionary<string,Viewbox> navIcons=new Dictionary<string,Viewbox>();
    readonly TextBlock sidebarLocation=new TextBlock();
    readonly ScrollViewer pageScroll=new ScrollViewer();
    string page="Inicio"; bool busy, refreshing;
    string renderedPage;
    internal bool DisableTransitions {get;set;}
    CancellationTokenSource backupCancellation;
    readonly Brush accent=Ui.Accent;
    readonly Brush muted=Ui.Ink2;
    readonly Brush line=Ui.Hairline;
    public ServerWindow() {
      Ui.Apply(this);
      var workWidth=Math.Max(320,SystemParameters.WorkArea.Width-28);
      var workHeight=Math.Max(320,SystemParameters.WorkArea.Height-28);
      Title="Inhouse Photos Server"; Width=Math.Min(1080,workWidth);Height=Math.Min(760,workHeight);
      MinWidth=Math.Min(820,workWidth);MinHeight=Math.Min(560,workHeight);
      WindowStartupLocation=WindowStartupLocation.CenterScreen;
      var root=new Grid{Background=Ui.Paper}; root.ColumnDefinitions.Add(new ColumnDefinition {Width=new GridLength(240)});root.ColumnDefinitions.Add(new ColumnDefinition());Content=root;
      var sidebarShell=new Border{Background=Ui.Sidebar,BorderBrush=Ui.Hairline,BorderThickness=new Thickness(0,0,1,0)};
      root.Children.Add(sidebarShell);
      var sidebar=new Grid{Margin=new Thickness(12,20,12,16)};sidebar.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});sidebar.RowDefinitions.Add(new RowDefinition());sidebar.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});sidebarShell.Child=sidebar;
      using(var brandStream=typeof(ServerWindow).Assembly.GetManifestResourceStream("InhousePhotos.brand.xaml"))Icon=(ImageSource)XamlReader.Load(brandStream);
      var brandBlock=new Grid{Margin=new Thickness(8,0,8,24)};
      brandBlock.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});brandBlock.ColumnDefinitions.Add(new ColumnDefinition());
      brandBlock.Children.Add(new Image{Source=Icon,Width=32,Height=32,VerticalAlignment=VerticalAlignment.Center});
      var brandWords=new StackPanel{Margin=new Thickness(10,0,0,0),VerticalAlignment=VerticalAlignment.Center};Grid.SetColumn(brandWords,1);
      var wordmark=Ui.Text("Inhouse Photos",15,Ui.Ink,true);wordmark.LineHeight=20;brandWords.Children.Add(wordmark);
      var product=Ui.Caption("Servidor");product.LineHeight=16;brandWords.Children.Add(product);
      brandBlock.Children.Add(brandWords);Grid.SetRow(brandBlock,0);sidebar.Children.Add(brandBlock);
      var navigation=new StackPanel();
      AutomationProperties.SetName(navigation,"Navegación");
      var navScroll=new ScrollViewer{Content=navigation,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled,Focusable=false};
      Grid.SetRow(navScroll,1);sidebar.Children.Add(navScroll);
      var navLabels=new Dictionary<string,string>{{"Inicio","Resumen"},{"Conectar","Conectar móvil"},{"Protección","Copias"},{"Discos","Almacenamiento"},{"Configuración","Ajustes"}};
      var navGlyphs=new Dictionary<string,string>{{"Inicio","home"},{"Conectar","phone"},{"Protección","shield"},{"Discos","drive"},{"Configuración","sliders"}};
      foreach(var name in new[]{"Inicio","Conectar","Protección","Discos","Configuración"}) {
        var captured=name;var row=new Grid{MinHeight=36};
        row.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(3)});row.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});row.ColumnDefinitions.Add(new ColumnDefinition());
        var rail=new Border{Width=3,Height=16,CornerRadius=new CornerRadius(1.5),Background=accent,Visibility=Visibility.Hidden,VerticalAlignment=VerticalAlignment.Center};row.Children.Add(rail);
        var glyph=Ui.Icon(navGlyphs[name],16,Ui.Ink2);glyph.Margin=new Thickness(11,0,12,0);glyph.VerticalAlignment=VerticalAlignment.Center;Grid.SetColumn(glyph,1);row.Children.Add(glyph);
        var title=new TextBlock{Text=navLabels[name],FontSize=14,VerticalAlignment=VerticalAlignment.Center,TextTrimming=TextTrimming.CharacterEllipsis};Grid.SetColumn(title,2);row.Children.Add(title);
        var button=new Button{Content=row,Style=Ui.StyleOf("Nav")};
        AutomationProperties.SetName(button,navLabels[name]);
        button.Click+=async(s,e)=>{if(!busy||backupCancellation!=null){page=captured;notice.Text="";await Render();}};
        tabs[name]=button;navRails[name]=rail;navTitles[name]=title;navIcons[name]=glyph;navigation.Children.Add(button);
      }
      var footer=new StackPanel{Margin=new Thickness(8,0,8,0)};Grid.SetRow(footer,2);sidebar.Children.Add(footer);
      footer.Children.Add(Ui.Divider(new Thickness(0,0,0,12)));
      footer.Children.Add(Ui.Caption("Biblioteca"));
      sidebarLocation.FontSize=13;sidebarLocation.Foreground=Ui.Ink;sidebarLocation.TextTrimming=TextTrimming.CharacterEllipsis;sidebarLocation.Margin=new Thickness(0,2,0,8);footer.Children.Add(sidebarLocation);
      footer.Children.Add(Ui.Caption("Versión "+Backend.Version));
      var right=new DockPanel();Grid.SetColumn(right,1);root.Children.Add(right);
      notice.TextWrapping=TextWrapping.Wrap;notice.Foreground=Ui.Ink;notice.FontSize=14;notice.VerticalAlignment=VerticalAlignment.Center;
      Typography.SetNumeralAlignment(notice,FontNumeralAlignment.Tabular);
      AutomationProperties.SetLiveSetting(notice,AutomationLiveSetting.Polite);
      var noticeRow=new Grid();noticeRow.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});noticeRow.ColumnDefinitions.Add(new ColumnDefinition());
      var noticeIcon=Ui.Icon("info",18,accent);noticeIcon.Margin=new Thickness(0,1,12,0);noticeIcon.VerticalAlignment=VerticalAlignment.Top;noticeRow.Children.Add(noticeIcon);
      Grid.SetColumn(notice,1);noticeRow.Children.Add(notice);
      var noticePanel=new Border{Background=Ui.Surface,BorderBrush=Ui.Stroke,BorderThickness=new Thickness(1),CornerRadius=new CornerRadius(8),Padding=new Thickness(14,11,16,11),Margin=new Thickness(40,0,40,16),Child=noticeRow,Visibility=Visibility.Collapsed};
      DependencyPropertyDescriptor.FromProperty(TextBlock.TextProperty,typeof(TextBlock)).AddValueChanged(notice,(s,e)=>{
        var show=!String.IsNullOrWhiteSpace(notice.Text);
        if(show&&noticePanel.Visibility!=Visibility.Visible&&!DisableTransitions)Ui.Enter(noticePanel,4,140);
        noticePanel.Visibility=show?Visibility.Visible:Visibility.Collapsed;
      });
      DockPanel.SetDock(noticePanel,Dock.Bottom);right.Children.Add(noticePanel);
      content.RenderTransform=contentMotion;
      // Every page shares one measure: left aligned, fluid up to 880 px.
      var measure=Ui.Constrain(content,880);measure.Margin=new Thickness(40,32,40,40);
      pageScroll.Content=measure;pageScroll.VerticalScrollBarVisibility=ScrollBarVisibility.Auto;pageScroll.HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled;pageScroll.Focusable=false;
      right.Children.Add(pageScroll);
      Loaded+=async(s,e)=>await Render();
      Closing+=(s,e)=>{if(busy&&!updateClose){e.Cancel=true;notice.Text="Espera a que termine la operación antes de cerrar.";}};
      // Do not destroy and rebuild a visible page on a timer: it resets scroll
      // position and makes controls disappear while someone is using them.
    }
    TextBlock Label(string text,double size,Brush color=null) {var block=Ui.Text(text,size,color??Ui.Ink);block.Margin=new Thickness(0,0,0,8);return block;}
    // Page header: one display title and, when it earns its place, one line.
    void Heading(string text,string description){
      var title=Ui.Display(text);title.Margin=new Thickness(0,0,0,String.IsNullOrEmpty(description)?24:4);content.Children.Add(title);
      if(!String.IsNullOrEmpty(description)){var line=Ui.Secondary(description);line.Margin=new Thickness(0,0,0,24);content.Children.Add(line);}
    }
    // Section header inside a page.
    TextBlock Section(string text,string caption=null){
      var title=Ui.Subtitle(text);title.Margin=new Thickness(0,36,0,caption==null?4:2);content.Children.Add(title);
      if(caption!=null){var detail=Ui.Secondary(caption);detail.Margin=new Thickness(0,0,0,4);content.Children.Add(detail);}
      return title;
    }
    void Rule(){content.Children.Add(Ui.Divider(new Thickness(0,24,0,24)));}
    Button Action(string title,Func<Task> task,bool primary=false,string icon=null) {
      var button=Ui.Button(title,primary?"Primary":"Secondary",icon);button.Margin=new Thickness(0,16,8,0);
      button.Click+=async(s,e)=>{if(busy||SystemUpdates.BlocksOperations(prefs)||RuntimeUpdates.BlocksOperations(prefs)){notice.Text="Espera a que termine o se recupere la actualización actual.";return;}busy=true;button.IsEnabled=false;notice.Text="Trabajando…";try{await task();if(notice.Text=="Trabajando…")notice.Text="";}catch(Exception ex){notice.Text=ex.Message;}finally{busy=false;button.IsEnabled=true;}};content.Children.Add(button);return button;
    }
    string PickFolder(){using(var dialog=new System.Windows.Forms.FolderBrowserDialog()){dialog.Description="Selecciona una carpeta";return dialog.ShowDialog()==System.Windows.Forms.DialogResult.OK?dialog.SelectedPath:null;}}
    bool Confirm(string message){return MessageBox.Show(this,message,"Inhouse Photos",MessageBoxButton.OKCancel,MessageBoxImage.Warning)==MessageBoxResult.OK;}
    void Open(string url){Process.Start(new ProcessStartInfo(url){UseShellExecute=true});}
    internal void PreviewPage(string target) { if(!tabs.ContainsKey(target))throw new ArgumentException("Unknown preview page");page=target; }
    // Preview only: shows the Copias page mid-copy without starting a copy.
    internal void PreviewBackupRunning() {prefs=Backend.Load();if(String.IsNullOrWhiteSpace(prefs.BackupDestination))prefs.BackupDestination=@"E:\";busy=true;backupCancellation=new CancellationTokenSource();backupProgressText="2 de 3 · Copiando fotos y vídeos nuevos…";page="Protección";}
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
      if(pageChanged)pageScroll.ScrollToTop();
      foreach(var item in tabs) {
        item.Value.IsEnabled=false;
        item.Value.Visibility=prefs.Managed||item.Key=="Inicio"?Visibility.Visible:Visibility.Collapsed;
        var selected=item.Key==page;
        item.Value.Tag=selected?"Selected":null;
        navRails[item.Key].Visibility=selected?Visibility.Visible:Visibility.Hidden;
        navTitles[item.Key].Foreground=selected?Ui.Ink:Ui.Ink2;
        Ui.IconPath(navIcons[item.Key]).Stroke=selected?Ui.Ink:Ui.Ink2;
        if(selected)AutomationProperties.SetItemStatus(item.Value,"Página actual");else AutomationProperties.SetItemStatus(item.Value,"");
      }
      var pageRendered=false;
      try {
        if(prefs.Managed)await RenderManagedPage();
        else await RenderSimpleHome();
        pageRendered=true;
      } catch(Exception ex) {
        content.Children.Add(EmptyState("alert",Tone.Critical,"No se pudo mostrar esta página",ex.Message));
      } finally {
        if(pageRendered&&pageChanged&&!DisableTransitions&&SystemParameters.ClientAreaAnimation){
          var duration=new Duration(TimeSpan.FromMilliseconds(160));
          var easing=new CubicEase{EasingMode=EasingMode.EaseOut};
          content.BeginAnimation(UIElement.OpacityProperty,new DoubleAnimation(0,1,duration){EasingFunction=easing,FillBehavior=FillBehavior.Stop});
          contentMotion.BeginAnimation(TranslateTransform.YProperty,new DoubleAnimation(6,0,duration){EasingFunction=easing,FillBehavior=FillBehavior.Stop});
        }
        renderedPage=page;
        refreshing=false;
        foreach(var item in tabs)item.Value.IsEnabled=prefs.Managed||item.Key=="Inicio";
      }
    }
    // Centred empty or error state: a tinted mark, one sentence, one action.
    StackPanel EmptyState(string icon,Tone tone,string title,string detail) {
      var panel=new StackPanel{Margin=new Thickness(0,8,0,8),MaxWidth=520,HorizontalAlignment=HorizontalAlignment.Left};
      var mark=new Grid{Width=48,Height=48,HorizontalAlignment=HorizontalAlignment.Left,Margin=new Thickness(0,0,0,16)};
      mark.Children.Add(new System.Windows.Shapes.Ellipse{Fill=tone==Tone.Critical?Ui.CriticalTint:tone==Tone.Attention?Ui.AccentTint:tone==Tone.Good?Ui.GoodTint:(Brush)Ui.NeutralTint});
      var glyph=Ui.Icon(icon,24,tone==Tone.Critical?Ui.Critical:tone==Tone.Attention?Ui.Accent:tone==Tone.Good?Ui.Good:(Brush)Ui.Ink2);
      glyph.HorizontalAlignment=HorizontalAlignment.Center;glyph.VerticalAlignment=VerticalAlignment.Center;mark.Children.Add(glyph);
      panel.Children.Add(mark);
      panel.Children.Add(Ui.Title(title));
      if(!String.IsNullOrEmpty(detail)){var line=Ui.Secondary(detail);line.Margin=new Thickness(0,6,0,0);panel.Children.Add(line);}
      return panel;
    }
  }
  public static class Program {
    static double PreviewScale(string value) {
      var scale=Double.Parse(value,System.Globalization.CultureInfo.InvariantCulture);
      if(scale<1||scale>3)throw new ArgumentOutOfRangeException("scale","Escala de vista previa no válida.");
      return scale;
    }
    // Renders a laid-out element at a DPI scale (1 = 100 %, 1.5 = 150 %).
    static void SavePreview(FrameworkElement root,int width,int height,double scale,string path) {
      root.Width=width;root.Height=height;root.Measure(new Size(width,height));root.Arrange(new Rect(0,0,width,height));root.UpdateLayout();
      var bitmap=new RenderTargetBitmap((int)Math.Round(width*scale),(int)Math.Round(height*scale),96*scale,96*scale,PixelFormats.Pbgra32);bitmap.Render(root);
      var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using(var stream=File.Create(path))encoder.Save(stream);
    }
    [STAThread] public static int Main(string[] args){
      PairingClient.RegisterQrAssembly();
      ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;
      if(args.Length==1&&args[0]=="--complete-product-install")return ProductInstallation.Complete();
      if(args.Length==1&&args[0]==UsbNetworkSafety.HelperArgument)return UsbNetworkSafety.RunElevated();
      // Offscreen previews of the secondary windows. They construct the UI
      // only: no window is shown, no installer, disk or server action runs.
      if(args.Length>=2&&args.Length<=4&&args[0]=="--render-setup-preview") {
        Ui.ReduceMotion=true;
        var previewApp=new Application();var setupWindow=new NewServerWindow();
        var setupStep=args.Length>=3?int.Parse(args[2]):0;var setupScale=args.Length>=4?PreviewScale(args[3]):1;
        if(setupStep<0||setupStep>4)throw new ArgumentOutOfRangeException("step");
        previewApp.Dispatcher.BeginInvoke(new Action(()=>{setupWindow.PreviewStep(setupStep);SavePreview((FrameworkElement)setupWindow.Content,700,780,setupScale,args[1]);previewApp.Shutdown();}));return previewApp.Run();
      }
      if(args.Length>=2&&args.Length<=3&&(args[0]=="--render-installer-preview"||args[0]=="--render-storage-preview")) {
        Ui.ReduceMotion=true;
        var previewApp=new Application();var scale=args.Length==3?PreviewScale(args[2]):1;
        Window previewWindow;
        if(args[0]=="--render-installer-preview")previewWindow=new SetupProgram.SetupWindow();
        else {var storage=new StorageWindow();storage.PreviewInventory();previewWindow=storage;}
        previewApp.Dispatcher.BeginInvoke(new Action(()=>{SavePreview((FrameworkElement)previewWindow.Content,(int)previewWindow.Width,(int)previewWindow.Height,scale,args[1]);previewApp.Shutdown();}));return previewApp.Run();
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
      if(args.Contains("--verify-runtime-handoff"))return RuntimeUpdates.VerifyHandoff();
      if(args.Contains("--verify-system-update-intent"))return SystemUpdates.VerifyIntent();
      if(args.Contains("--self-test")){
        try {
          if(RuntimeUpdates.SelfTest()!=0)return 59;
          if(SystemUpdates.SelfTest()!=0)return 60;
          if(UsbNetworkSafety.SelfTest()!=0)return 29;
          if(UsbDeviceMonitor.SelfTest()!=0)return 56;
          var browserToken=new string('A',43);
          if(RemoteManagement.ReadOnlyBrowserToken("GET",RemoteManagement.UsbPath,"other=1; immich_access_token="+browserToken)!=browserToken||
             RemoteManagement.ReadOnlyBrowserToken("GET",RemoteManagement.StatusPath,"immich_access_token="+browserToken)!=browserToken||
             RemoteManagement.ReadOnlyBrowserToken("POST",RemoteManagement.StatusPath+"/backup/start","immich_access_token="+browserToken)!=null||
             RemoteManagement.ReadOnlyBrowserToken("GET",RemoteManagement.Path,"immich_access_token="+browserToken)!=null||
             RemoteManagement.ReadOnlyBrowserToken("GET",RemoteManagement.UsbPath,"immich_access_token="+browserToken+"; immich_access_token="+browserToken)!=null||
             RemoteManagement.ReadOnlyBrowserToken("GET",RemoteManagement.UsbPath,"immich_access_token=bad%0Atoken")!=null||
             !RemoteManagement.Allowed("GET",RemoteManagement.UsbPath)||RemoteManagement.Allowed("POST",RemoteManagement.UsbPath))return 57;
          var downloadsFixture="photos.example.com {\n\thandle_path /descargas/* {\n\t\troot * /data/inhouse-downloads\n\t\tfile_server\n\t}\n\thandle {\n\t\treverse_proxy photos:2283\n\t}\n}\n";
          var browserRoute=RemoteManagement.WithRoute(downloadsFixture,new string('a',64));
          if(!browserRoute.Contains("handle_path /descargas/servidor/*")||!browserRoute.Contains("connect-src 'self'")||
             RemoteManagement.WithRoute(browserRoute,new string('a',64))!=browserRoute||
             !browserRoute.Contains("reverse_proxy photos:2283")||
             System.Text.RegularExpressions.Regex.Matches(browserRoute,"handle_path /descargas/servidor/\\*").Count!=1)return 58;
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
          foreach(var usb in new[]{
            new[]{@"USB\VID_18D1&PID_4EE3\phone","Remote NDIS based Internet Sharing Device"},
            new[]{@"USB\VID_04E8&PID_6863\phone","Samsung Mobile USB RNDIS"},
            new[]{@"USB\VID_18D1&PID_4EE3\phone","USB NCM Host Device"},
            new[]{@"USB\VID_05AC&PID_12A8\phone","Apple Mobile Device Ethernet"}})
            if(!LanRoute.IsPhoneUsbTether(usb[0],usb[1]))return 48;
          foreach(var notUsb in new[]{
            new[]{@"PCI\VEN_10EC&DEV_8168","Realtek PCIe GbE Family Controller"},
            new[]{@"USB\VID_0BDA&PID_8153\dongle","Realtek USB GbE Family Controller"},
            new[]{@"USB\VID_0BDA&PID_8153\dongle","USB NCM Host Device"},
            new[]{@"ROOT\NET\0000","Remote NDIS Internet Sharing Device"},
            new[]{@"USB\VID_18D1&PID_4EE1\phone","Android MTP Device"},
            new[]{"","Apple Mobile Device Ethernet"}})
            if(LanRoute.IsPhoneUsbTether(notUsb[0],notUsb[1]))return 49;
          var ethernetType=System.Net.NetworkInformation.NetworkInterfaceType.Ethernet;
          var lanAdapter=new LanRoute.Adapter{Up=true,Physical=true,HasGateway=true,Type=ethernetType,
            Description="Realtek PCIe GbE Family Controller",PnpDeviceId=@"PCI\VEN_10EC&DEV_8168",
            Speed=100000000L,Addresses=new[]{"192.168.1.237","192.168.1.237","127.0.0.1","8.8.8.8","::1","169.254.1.1"}};
          var usbAdapter=new LanRoute.Adapter{Up=true,Physical=false,HasGateway=false,Type=ethernetType,
            Description="Remote NDIS based Internet Sharing Device",PnpDeviceId=@"USB\VID_18D1&PID_4EE3\phone",
            Speed=480000000L,Addresses=new[]{"192.168.42.2"}};
          var virtualAdapter=new LanRoute.Adapter{Up=true,Physical=false,HasGateway=true,Type=ethernetType,
            Description="Hyper-V Virtual Ethernet Adapter",Speed=10000000000L,Addresses=new[]{"172.20.1.1"}};
          var localCandidates=LanRoute.Candidates(new[]{virtualAdapter,lanAdapter,usbAdapter});
          if(localCandidates.Length!=2||localCandidates[0].kind!="usb"||localCandidates[0].ipv4!="192.168.42.2"||
             localCandidates[1].kind!="lan"||localCandidates[1].linkMbps!=100)return 50;
          usbAdapter.Up=false;lanAdapter.HasGateway=false;
          if(LanRoute.Candidates(new[]{lanAdapter,usbAdapter,virtualAdapter}).Length!=0)return 51;
          usbAdapter.Up=true;lanAdapter.HasGateway=true;
          var manyAddresses=Enumerable.Range(1,20).Select(number=>"10.0.0."+number).ToArray();
          if(LanRoute.Candidates(new[]{new LanRoute.Adapter{Up=true,Physical=true,HasGateway=true,Type=ethernetType,
            Description="Ethernet",Addresses=manyAddresses}}).Length!=LanRoute.MaximumRoutes)return 52;
          var routeDocument=LanRoute.Document("https://photos.example.com",new[]{usbAdapter,lanAdapter});
          var routeFields=Backend.Json.Deserialize<Dictionary<string,object>>(routeDocument);
          var routeRows=((System.Collections.IEnumerable)routeFields["routes"]).Cast<object>().ToArray();
          if((string)routeFields["origin"]!="https://photos.example.com"||(string)routeFields["ipv4"]!="192.168.1.237"||
             Convert.ToInt32(routeFields["port"])!=443||routeRows.Length!=2||
             routeDocument==LanRoute.Document("https://photos.example.com",new[]{lanAdapter}))return 53;
          var emptyRouteFields=Backend.Json.Deserialize<Dictionary<string,object>>(LanRoute.Document("https://photos.example.com",null));
          if(emptyRouteFields["ipv4"]!=null||((System.Collections.IEnumerable)emptyRouteFields["routes"]).Cast<object>().Any())return 54;
          foreach(var invalidOrigin in new[]{null,"","http://photos.example.com","https://user:pass@photos.example.com",
            "https://photos.example.com:444","https://photos.example.com/api","https://photos.example.com?token=secret","https://photos.example.com#secret"})
            if(LanRoute.Document(invalidOrigin,new[]{lanAdapter})!=null)return 55;
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
        window.DisableTransitions=true;Ui.ReduceMotion=true;
        window.DisablePairingRequests=true;
        var previewWidth=args.Length>=5?int.Parse(args[3]):1080;
        var previewHeight=args.Length>=5?int.Parse(args[4]):760;
        var previewScale=args.Length>=6?PreviewScale(args[5]):1;
        if(previewWidth<760||previewHeight<600||previewWidth>2400||previewHeight>1800)throw new ArgumentOutOfRangeException("preview","Tamaño de vista previa no válido.");
        if(args.Length>=3){if(args[2]=="Migracion")window.PreviewMigration();else if(args[2]=="CopiaEnCurso")window.PreviewBackupRunning();else window.PreviewPage(args[2]);}
        app.Dispatcher.BeginInvoke(new Action(async()=>{await window.Render();SavePreview((FrameworkElement)window.Content,previewWidth,previewHeight,previewScale,args[1]);app.Shutdown();}));app.Run();return 0;
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
