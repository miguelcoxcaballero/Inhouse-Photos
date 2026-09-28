using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Diagnostics;
using System.Threading.Tasks;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Markup;
using Microsoft.Win32;

namespace InhousePhotos {
  public sealed class InstalledApplication {
    public string Version {get;set;}
    public string Sha256 {get;set;}
    public string RelativePath {get;set;}
  }
  public static class SetupProgram {
    static string Pointer {get{return Path.Combine(Backend.InstallDir,"current.json");}}
    public static InstalledApplication ReadInstalled() {
      var app=Backend.Json.Deserialize<InstalledApplication>(File.ReadAllText(Pointer));
      if(app==null||!Regex.IsMatch(app.Version??"","^[0-9]+\\.[0-9]+\\.[0-9]+$")||!Regex.IsMatch(app.Sha256??"","^[a-f0-9]{64}$"))throw new IOException("La instalación no es válida.");
      var relative=@"versions\"+app.Version+"-"+app.Sha256.Substring(0,12)+@"\Inhouse-Photos-Server.exe";
      if(app.RelativePath!=relative)throw new IOException("La ruta del programa no es válida.");
      var path=Path.Combine(Backend.InstallDir,relative);Backend.RejectLinks(Path.GetDirectoryName(path));
      if(!File.Exists(path)||(File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0||Backend.Hash(path)!=app.Sha256)throw new IOException("El programa no pasa la comprobación de integridad. Vuelve a instalarlo desde la web.");
      return app;
    }
    public static void Install() {
      // Never swap the active version while its manager may be backing up or
      // verifying storage. Closing the manager does not stop the photo server.
      try {
        using(var running=System.Threading.Mutex.OpenExisting(@"Local\InhousePhotosServer"))
          throw new ManagerRunningException();
      }catch(System.Threading.WaitHandleCannotBeOpenedException){}
      Backend.PrivateDirectory(Backend.InstallDir);
      var assembly=Assembly.GetExecutingAssembly();
      string expected;
      using(var resource=assembly.GetManifestResourceStream("InhousePhotos.payload.sha256"))using(var reader=new StreamReader(resource))expected=reader.ReadToEnd().Trim().ToLowerInvariant();
      if(!Regex.IsMatch(expected,"^[a-f0-9]{64}$"))throw new IOException("El instalador está incompleto.");
      var app=new InstalledApplication{Version=Backend.Version,Sha256=expected,RelativePath=@"versions\"+Backend.Version+"-"+expected.Substring(0,12)+@"\Inhouse-Photos-Server.exe"};
      var target=Path.Combine(Backend.InstallDir,app.RelativePath);Backend.PrivateDirectory(Path.GetDirectoryName(target));
      if(!File.Exists(target)) {
        var partial=target+"."+Guid.NewGuid().ToString("N")+".partial";
        using(var payload=assembly.GetManifestResourceStream("InhousePhotos.payload.exe"))using(var output=File.Create(partial))payload.CopyTo(output);
        if(Backend.Hash(partial)!=expected)throw new IOException("La copia del programa no es válida.");
        File.Move(partial,target);
      } else if(Backend.Hash(target)!=expected)throw new IOException("Hay un archivo inesperado en la carpeta de instalación. No se ha sobrescrito.");
      // The stable launcher is deliberately immutable while it supervises an
      // older version. It resolves the validated pointer on the next launch.
      if(!File.Exists(Backend.Launcher))File.Copy(assembly.Location,Backend.Launcher,false);
      var temporary=Pointer+"."+Guid.NewGuid().ToString("N")+".new";File.WriteAllText(temporary,Backend.Json.Serialize(app));
      if(File.Exists(Pointer))File.Replace(temporary,Pointer,Path.Combine(Backend.InstallDir,"previous.json"));else File.Move(temporary,Pointer);
      var shortcut=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs),"Inhouse Photos Server.lnk");
      dynamic shell=Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));dynamic link=shell.CreateShortcut(shortcut);
      link.TargetPath=Backend.Launcher;link.Arguments="--launch";link.WorkingDirectory=Backend.InstallDir;link.IconLocation=target+",0";link.Description="Administra tu biblioteca Inhouse Photos";link.Save();
      using(var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\App Paths\Inhouse Photos.exe"))key.SetValue("",Backend.Launcher);
      ReadInstalled();
    }
    public static void VerifyPayload() {
      var assembly=Assembly.GetExecutingAssembly();
      string expected;
      using(var hash=assembly.GetManifestResourceStream("InhousePhotos.payload.sha256"))
      using(var reader=new StreamReader(hash??throw new IOException("Falta la suma de comprobación del programa.")))expected=reader.ReadToEnd().Trim().ToLowerInvariant();
      if(!Regex.IsMatch(expected,"^[a-f0-9]{64}$"))throw new IOException("La suma de comprobación del programa no es válida.");
      using(var payload=assembly.GetManifestResourceStream("InhousePhotos.payload.exe")) {
        if(payload==null)throw new IOException("Falta el programa en el instalador.");
        using(var sha=System.Security.Cryptography.SHA256.Create()) {
          var actual=BitConverter.ToString(sha.ComputeHash(payload)).Replace("-","").ToLowerInvariant();
          if(actual!=expected)throw new IOException("El programa descargado no pasa la comprobación de integridad.");
        }
      }
    }
    static int Launch(bool startup) {
      var record=ReadInstalled();var path=Path.Combine(Backend.InstallDir,record.RelativePath);
      using(var child=Process.Start(new ProcessStartInfo(path,startup?"--startup":""){UseShellExecute=false,CreateNoWindow=true,WindowStyle=startup?ProcessWindowStyle.Hidden:ProcessWindowStyle.Normal,WorkingDirectory=Backend.InstallDir})) {
        if(startup){child.WaitForExit();return child.ExitCode;}return 0;
      }
    }
    [STAThread] public static int Main(string[] args) {
      try {
        if(args.Contains("--launch")||args.Contains("--startup"))return Launch(args.Contains("--startup"));
        if(args.Contains("--verify-payload")){VerifyPayload();Console.WriteLine("Contenido verificado.");return 0;}
        if(args.Contains("--install-current")){Install();Console.WriteLine("Instalación verificada en "+Backend.InstallDir);return 0;}
        if(args.Contains("--verify-installed")){var app=ReadInstalled();Console.WriteLine(app.Version+" "+app.Sha256);return 0;}
        var application=new Application();return application.Run(new SetupWindow());
      }catch(Exception ex){if(args.Length==0)MessageBox.Show(ex.Message,"Inhouse Photos",MessageBoxButton.OK,MessageBoxImage.Error);else Console.Error.WriteLine(ex.Message);return 1;}
    }
    sealed class SetupWindow:Window {
      static readonly Brush Page=new SolidColorBrush(Color.FromRgb(23,18,15));
      static readonly Brush Text=new SolidColorBrush(Color.FromRgb(249,243,237));
      static readonly Brush Muted=new SolidColorBrush(Color.FromRgb(189,172,160));
      static readonly Brush Accent=new SolidColorBrush(Color.FromRgb(242,160,103));
      static readonly Brush Rule=new SolidColorBrush(Color.FromRgb(66,51,42));
      static readonly Brush Notice=new SolidColorBrush(Color.FromRgb(45,34,27));
      static readonly Brush Warning=new SolidColorBrush(Color.FromRgb(251,187,155));
      readonly TextBlock statusTitle;
      readonly TextBlock statusDetail;
      readonly Border statusPanel;
      readonly ProgressBar progress;
      readonly Button button;
      bool installed;

      static TextBlock Copy(string value,double size,Brush color,bool bold=false) {
        return new TextBlock {Text=value,FontSize=size,Foreground=color,FontWeight=bold?FontWeights.SemiBold:FontWeights.Normal,
          TextWrapping=TextWrapping.Wrap,LineHeight=size*1.42};
      }
      static FrameworkElement Step(string number,string title,string detail) {
        var row=new Grid {Margin=new Thickness(0,13,0,13)};
        row.ColumnDefinitions.Add(new ColumnDefinition {Width=new GridLength(48)});
        row.ColumnDefinitions.Add(new ColumnDefinition());
        var index=Copy(number,13,Accent,true);index.Margin=new Thickness(0,3,0,0);
        Grid.SetColumn(index,0);row.Children.Add(index);
        var words=new StackPanel();words.Children.Add(Copy(title,17,Text,true));
        var description=Copy(detail,14,Muted);description.Margin=new Thickness(0,3,0,0);words.Children.Add(description);
        Grid.SetColumn(words,1);row.Children.Add(words);
        return row;
      }
      static Border Divider() {return new Border {Height=1,Background=Rule};}

      public SetupWindow() {
        Title="Instalar Inhouse Photos Server";
        Width=Math.Min(610,Math.Max(480,SystemParameters.WorkArea.Width-48));
        Height=Math.Min(620,Math.Max(500,SystemParameters.WorkArea.Height-48));
        MinWidth=450;MinHeight=480;ResizeMode=ResizeMode.CanResize;WindowStartupLocation=WindowStartupLocation.CenterScreen;
        Background=Page;Foreground=Text;FontFamily=new FontFamily("Segoe UI");
        using(var brand=Assembly.GetExecutingAssembly().GetManifestResourceStream("InhousePhotos.brand.xaml"))Icon=(ImageSource)XamlReader.Load(brand);
        var root=new Grid();root.RowDefinitions.Add(new RowDefinition {Height=GridLength.Auto});
        root.RowDefinitions.Add(new RowDefinition());root.RowDefinitions.Add(new RowDefinition {Height=GridLength.Auto});Content=root;

        var header=new Grid {Margin=new Thickness(34,25,34,20)};
        header.ColumnDefinitions.Add(new ColumnDefinition {Width=new GridLength(48)});
        header.ColumnDefinitions.Add(new ColumnDefinition());
        var mark=new Image {Source=Icon,Width=38,Height=38,HorizontalAlignment=HorizontalAlignment.Left,VerticalAlignment=VerticalAlignment.Center};
        header.Children.Add(mark);
        var brandText=new StackPanel();brandText.Children.Add(Copy("INHOUSE PHOTOS",13,Accent,true));
        brandText.Children.Add(Copy("Servidor para Windows",14,Muted));Grid.SetColumn(brandText,1);header.Children.Add(brandText);
        Grid.SetRow(header,0);root.Children.Add(header);

        var scroll=new ScrollViewer {VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};
        var body=new StackPanel {Margin=new Thickness(34,0,34,12)};scroll.Content=body;
        var title=Copy("Instala el gestor.\nTus fotos se quedan.",30,Text,true);title.LineHeight=36;
        body.Children.Add(title);
        var introduction=Copy("Una forma sencilla de conectar, revisar y proteger tu biblioteca desde este ordenador.",15,Muted);
        introduction.Margin=new Thickness(0,13,0,20);body.Children.Add(introduction);
        body.Children.Add(Divider());
        body.Children.Add(Step("01","Instalar el gestor","Se añadirá al menú Inicio. Solo se instala el programa de Windows."));
        body.Children.Add(Divider());
        body.Children.Add(Step("02","Conectar tu biblioteca","Al abrirlo, podrás vincular el servidor que ya tienes y ver su estado."));
        body.Children.Add(Divider());

        var reassurance=new Grid {Margin=new Thickness(0,16,0,16)};
        reassurance.ColumnDefinitions.Add(new ColumnDefinition {Width=new GridLength(30)});
        reassurance.ColumnDefinitions.Add(new ColumnDefinition());
        reassurance.Children.Add(Copy("✓",18,Accent,true));
        var safe=Copy("No se mueven ni se borran fotos. Instalar el gestor no apaga el servidor.",14,Text);
        Grid.SetColumn(safe,1);reassurance.Children.Add(safe);body.Children.Add(reassurance);
        Grid.SetRow(scroll,1);root.Children.Add(scroll);

        var footer=new StackPanel {Margin=new Thickness(34,0,34,28)};
        statusPanel=new Border {Background=Notice,CornerRadius=new CornerRadius(10),Padding=new Thickness(14,10,14,10),Margin=new Thickness(0,0,0,14)};
        var statusStack=new StackPanel();statusTitle=Copy("Listo para instalar",15,Text,true);
        statusDetail=Copy("Versión "+Backend.Version+"  ·  Windows 10 / 11",13,Muted);statusDetail.Margin=new Thickness(0,2,0,0);
        statusStack.Children.Add(statusTitle);statusStack.Children.Add(statusDetail);
        progress=new ProgressBar {Height=4,Margin=new Thickness(0,10,0,0),Foreground=Accent,Background=Rule,
          BorderThickness=new Thickness(0),IsIndeterminate=true,Visibility=Visibility.Collapsed};statusStack.Children.Add(progress);
        statusPanel.Child=statusStack;footer.Children.Add(statusPanel);
        button=new Button {Content="Instalar y abrir",Padding=new Thickness(20,12,20,12),MinHeight=48,FontSize=16,
          FontWeight=FontWeights.SemiBold,BorderThickness=new Thickness(0),Background=Accent,Foreground=Page,
          HorizontalContentAlignment=HorizontalAlignment.Center};footer.Children.Add(button);
        Grid.SetRow(footer,2);root.Children.Add(footer);
        button.Click+=InstallClicked;
      }

      async void InstallClicked(object sender,RoutedEventArgs e) {
        button.IsEnabled=false;
        progress.Visibility=Visibility.Visible;
        statusTitle.Foreground=Text;
        statusTitle.Text=installed?"Abriendo el gestor…":"Instalando el gestor…";
        statusDetail.Text=installed?"Tus fotos y el servidor no se han modificado.":"Copiando el programa y comprobando su integridad.";
        try {
          if(!installed){await Task.Run((Action)Install);installed=true;}
          statusTitle.Text="Instalación completa";
          statusDetail.Text="Abriendo el gestor de tu biblioteca…";
          Launch(false);Close();
        }catch(ManagerRunningException) {
          progress.Visibility=Visibility.Collapsed;
          statusTitle.Foreground=Warning;statusTitle.Text="Cierra el gestor anterior";
          statusDetail.Text="En la barra de tareas, abre los iconos junto al reloj. Haz clic derecho en Inhouse Photos, elige «Salir del gestor» y vuelve aquí. Tus fotos y subidas seguirán funcionando.";
          button.Content="Reintentar instalación";button.IsEnabled=true;
        }catch(Exception ex) {
          progress.Visibility=Visibility.Collapsed;
          statusTitle.Foreground=Warning;statusTitle.Text=installed?"Instalado, pero no se pudo abrir":"No se pudo completar la instalación";
          statusDetail.Text=(installed?"Puedes abrirlo desde el menú Inicio. ":"")+ex.Message;
          button.Content=installed?"Abrir el gestor":"Reintentar instalación";button.IsEnabled=true;
        }
      }
    }
    sealed class ManagerRunningException:IOException {
      public ManagerRunningException():base("El gestor anterior sigue abierto."){}
    }
  }
}
