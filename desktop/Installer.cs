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
      if(File.Exists(Pointer)&&ManagerUpdates.Compare(ReadInstalled().Version,Backend.Version)>0)
        throw new IOException("Ya tienes una versión más reciente. Descarga el instalador actual desde tu web; no se instalará una versión anterior.");
      // The current and older managers use the same installer entry points.
      // Persist continuation before the active pointer can change, including
      // a manual upgrade used to recover an interrupted legacy operation.
      var updatePreferences=Backend.Load();SystemUpdates.QueueFromInstaller(updatePreferences);
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
      if(!File.Exists(Backend.Launcher))FullInstallerPackage.CopyLauncher(assembly.Location,Backend.Launcher);
      var temporary=Pointer+"."+Guid.NewGuid().ToString("N")+".new";File.WriteAllText(temporary,Backend.Json.Serialize(app));
      if(File.Exists(Pointer))File.Replace(temporary,Pointer,Path.Combine(Backend.InstallDir,"previous.json"));else File.Move(temporary,Pointer);
      var shortcut=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs),"Inhouse Photos Server.lnk");
      dynamic shell=Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));dynamic link=shell.CreateShortcut(shortcut);
      link.TargetPath=Backend.Launcher;link.Arguments="--launch";link.WorkingDirectory=Backend.InstallDir;link.IconLocation=target+",0";link.Description="Administra tu biblioteca Inhouse Photos";link.Save();
      using(var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\App Paths\Inhouse Photos.exe"))key.SetValue("",Backend.Launcher);
      ReadInstalled();
      SystemUpdates.ManagerInstalled(updatePreferences);
    }
    public static async Task InstallProduct(Action<string> notify) {
      Backend.PrivateDirectory(Backend.SettingsDir);
      var leasePath=Path.Combine(Backend.SettingsDir,"product-install.lock");
      if(File.Exists(leasePath)&&(File.GetAttributes(leasePath)&FileAttributes.ReparsePoint)!=0)
        throw new IOException("El bloqueo de instalación no puede ser un enlace.");
      // Unlike a Mutex, the file lease is not bound to an await continuation's
      // thread. CLI hand-off and WPF use exactly the same cross-process guard.
      using(var lease=new FileStream(leasePath,FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None)) {
          notify("Comprobando el programa y los componentes incluidos…");
          VerifyPayload();
          await FullInstallerPackage.Import(Assembly.GetExecutingAssembly().Location,notify);
          notify("Instalando Inhouse Photos…");
          Install();
          var installed=ReadInstalled();
          if(installed.Version!=Backend.Version)throw new IOException("El programa instalado no es la versión de este instalador.");
          var prefs=Backend.Load();
          if(!prefs.Managed) {
            notify("Preparando los componentes para tu biblioteca nueva…");
            await RuntimeUpdates.CachePackage();
            return; // Disk selection and third-party license consent stay explicit.
          }
          notify("Preparando el servidor y verificando tu biblioteca…");
          var executable=Path.Combine(Backend.InstallDir,installed.RelativePath);
          using(var child=new Process{StartInfo=new ProcessStartInfo(executable,"--complete-product-install") {
            UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden,
            WorkingDirectory=Backend.InstallDir,RedirectStandardOutput=true,RedirectStandardError=true
          }}) {
            var stdoutClosed=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            child.OutputDataReceived+=(sender,line)=>{
              if(line.Data==null){stdoutClosed.TrySetResult(true);return;}
              const string prefix="INHOUSE_INSTALL_STAGE:";
              if(line.Data!=null&&line.Data.StartsWith(prefix,StringComparison.Ordinal)) {
                var stage=line.Data.Substring(prefix.Length);
                var message=ProductInstallation.StageMessage(stage);
                if(message!=null)notify(message);
              }
            };
            child.Start();child.BeginOutputReadLine();
            var errors=child.StandardError.ReadToEndAsync();
            while(!await Task.Run(()=>child.WaitForExit(1000)))await Task.Delay(100);
            await RuntimeProcessOutput.Drain(child,errors,stdoutClosed.Task);
            if(child.ExitCode!=0)throw new IOException(SystemUpdates.InstallationError(prefs)+" Pulsa Reintentar; tus fotos y la preparación verificada se conservan.");
          }
          if(ReadInstalled().Sha256!=installed.Sha256||!await RuntimeUpdates.ConfirmInstalled(prefs))
            throw new IOException("Falta confirmar el servidor. La instalación no se da por terminada; pulsa Reintentar.");
          notify("Instalación completa y biblioteca verificadas.");
      }
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
    static int WaitAndInstall(string[] args) {
      int managerPid;
      if(args.Length<2||!int.TryParse(args[1],out managerPid)||managerPid<=0)throw new ArgumentException("La solicitud de actualización no es válida.");
      var hidden=args.Contains("--restart-hidden");
      try {
        try {using(var old=Process.GetProcessById(managerPid)) {
          if(!old.WaitForExit(120000))throw new TimeoutException("El gestor anterior no se cerró. La actualización queda pendiente para reintentar; tus fotos se conservan.");
        }}catch(ArgumentException){/* It exited before the helper started. */}
        InstallProduct(message=>{}).GetAwaiter().GetResult();
        StartInstalled(hidden);
        var previousError=Path.Combine(Backend.SettingsDir,"last-manager-update-error.txt");
        if(File.Exists(previousError))File.Delete(previousError);
        return 0;
      }catch(Exception ex) {
        // If installation fails, the last validated pointer still launches the
        // previous manager. The photo server was never stopped either way.
        try{Backend.PrivateDirectory(Backend.SettingsDir);File.WriteAllText(Path.Combine(Backend.SettingsDir,"last-manager-update-error.txt"),ex.Message);}catch{}
        try{StartInstalled(hidden);}catch{}
        throw;
      }
    }
    static void StartInstalled(bool hidden) {
      var record=ReadInstalled();var executable=Path.Combine(Backend.InstallDir,record.RelativePath);
      Process.Start(new ProcessStartInfo(executable,hidden?"--startup":"") {
        UseShellExecute=false,CreateNoWindow=hidden,WindowStyle=hidden?ProcessWindowStyle.Hidden:ProcessWindowStyle.Normal,
        WorkingDirectory=Backend.InstallDir
      });
    }
    [STAThread] public static int Main(string[] args) {
      try {
        if(args.Length>0&&args[0]=="--wait-and-install")return WaitAndInstall(args);
        if(args.Contains("--launch")||args.Contains("--startup"))return Launch(args.Contains("--startup"));
        if(args.Contains("--verify-payload")){VerifyPayload();Console.WriteLine("Contenido verificado.");return 0;}
        if(args.Contains("--verify-full-package")){VerifyPayload();FullInstallerPackage.Verify(Assembly.GetExecutingAssembly().Location);Console.WriteLine("Instalador completo verificado.");return 0;}
        if(args.Contains("--install-product")){InstallProduct(Console.WriteLine).GetAwaiter().GetResult();return 0;}
        if(args.Contains("--install-current")){InstallProduct(Console.WriteLine).GetAwaiter().GetResult();Console.WriteLine("Instalación completa verificada.");return 0;}
        if(args.Contains("--install-manager-only-fixture")){if(Backend.Load().Managed)throw new IOException("Esta prueba requiere un perfil Windows sin biblioteca vinculada.");Install();return 0;}
        if(args.Contains("--verify-installed")){var app=ReadInstalled();Console.WriteLine(app.Version+" "+app.Sha256);return 0;}
        var application=new Application();return application.Run(new SetupWindow());
      }catch(Exception ex){if(args.Length==0)MessageBox.Show(ex.Message,"Inhouse Photos",MessageBoxButton.OK,MessageBoxImage.Error);else Console.Error.WriteLine(ex.Message);return 1;}
    }
    sealed class SetupWindow:Window {
      static readonly Brush Page=new SolidColorBrush(Color.FromRgb(246,243,238));
      static readonly Brush Text=new SolidColorBrush(Color.FromRgb(32,28,24));
      static readonly Brush Muted=new SolidColorBrush(Color.FromRgb(109,98,89));
      static readonly Brush Accent=new SolidColorBrush(Color.FromRgb(169,71,18));
      static readonly Brush Rule=new SolidColorBrush(Color.FromRgb(226,216,205));
      static readonly Brush Warning=new SolidColorBrush(Color.FromRgb(177,62,45));
      readonly TextBlock statusTitle;
      readonly TextBlock statusDetail;
      readonly Border statusPanel;
      readonly ProgressBar progress;
      readonly Button button;
      bool installed,installing;

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
        Title="Instalar Inhouse Photos";
        Width=Math.Min(610,Math.Max(480,SystemParameters.WorkArea.Width-48));
        Height=Math.Min(730,Math.Max(500,SystemParameters.WorkArea.Height-48));
        MinWidth=450;MinHeight=480;ResizeMode=ResizeMode.CanResize;WindowStartupLocation=WindowStartupLocation.CenterScreen;
        Background=Page;Foreground=Text;FontFamily=new FontFamily("Segoe UI");
        using(var brand=Assembly.GetExecutingAssembly().GetManifestResourceStream("InhousePhotos.brand.xaml"))Icon=(ImageSource)XamlReader.Load(brand);
        var root=new Grid{Background=Page};root.RowDefinitions.Add(new RowDefinition {Height=GridLength.Auto});
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
        var title=Copy("Inhouse Photos,\nlisto en tu PC.",30,Text,true);title.LineHeight=36;
        body.Children.Add(title);
        var introduction=Copy("Una sola instalación para el programa y el sistema que guarda tus fotos. Si ya tienes una biblioteca vinculada, también se actualiza y se comprueba aquí.",15,Muted);
        introduction.Margin=new Thickness(0,13,0,20);body.Children.Add(introduction);
        body.Children.Add(Divider());
        body.Children.Add(Step("01","Instalar Inhouse Photos","El programa queda actualizado, con su versión comprobada y un acceso en el menú Inicio."));
        body.Children.Add(Divider());
        body.Children.Add(Step("02","Preparar el sistema","El motor de fotos viene en este instalador. En un PC nuevo, al abrirlo se preparan los componentes que falten y se solicitan los permisos necesarios."));
        body.Children.Add(Divider());
        body.Children.Add(Step("03","Comprobar tu biblioteca","Si ya está vinculada, la instalación termina después de verificar el servidor. Si es la primera vez, al abrirlo eliges dónde guardar tus fotos."));
        body.Children.Add(Divider());

        var reassurance=new Grid {Margin=new Thickness(0,16,0,16)};
        reassurance.ColumnDefinitions.Add(new ColumnDefinition {Width=new GridLength(30)});
        reassurance.ColumnDefinitions.Add(new ColumnDefinition());
        reassurance.Children.Add(Copy("✓",18,Accent,true));
        var safe=Copy("Tus fotos, cuentas, álbumes y discos se conservan. Al actualizar el motor puede haber una pausa breve en el acceso; no necesitas volver a subir tu biblioteca.",14,Text);
        Grid.SetColumn(safe,1);reassurance.Children.Add(safe);body.Children.Add(reassurance);
        Grid.SetRow(scroll,1);root.Children.Add(scroll);

        var footer=new StackPanel {Margin=new Thickness(34,0,34,28)};
        statusPanel=new Border {BorderBrush=Rule,BorderThickness=new Thickness(0,1,0,0),Padding=new Thickness(0,15,0,0),Margin=new Thickness(0,0,0,14)};
        var statusStack=new StackPanel();statusTitle=Copy("Listo para instalar",15,Text,true);
        statusDetail=Copy("Versión "+Backend.Version+"  ·  Windows 10 / 11",13,Muted);statusDetail.Margin=new Thickness(0,2,0,0);
        statusStack.Children.Add(statusTitle);
        statusStack.Children.Add(new ScrollViewer{Content=statusDetail,MaxHeight=108,
          VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled});
        progress=new ProgressBar {Height=4,Margin=new Thickness(0,10,0,0),Foreground=Accent,Background=Rule,
          BorderThickness=new Thickness(0),IsIndeterminate=true,Visibility=Visibility.Collapsed};statusStack.Children.Add(progress);
        statusPanel.Child=statusStack;footer.Children.Add(statusPanel);
        button=new Button {Content="Instalar Inhouse Photos",Padding=new Thickness(20,12,20,12),MinHeight=48,FontSize=16,
          FontWeight=FontWeights.SemiBold,BorderThickness=new Thickness(0),Background=Accent,Foreground=Brushes.White,
          HorizontalContentAlignment=HorizontalAlignment.Center};footer.Children.Add(button);
        Grid.SetRow(footer,2);root.Children.Add(footer);
        button.Click+=InstallClicked;
        Closing+=(sender,args)=>{
          if(!installing)return;
          args.Cancel=true;
          statusDetail.Text="La instalación sigue en curso. Espera a que termine la comprobación antes de cerrar. Tus fotos y el trabajo pendiente se conservan.";
        };
      }

      async void InstallClicked(object sender,RoutedEventArgs e) {
        if(installing)return;
        button.IsEnabled=false;
        statusTitle.Foreground=Text;
        try {
          if(installed) {
            statusTitle.Text="Abriendo Inhouse Photos…";
            Launch(false);Close();return;
          }
          installing=true;progress.Visibility=Visibility.Visible;
          button.Content="Instalando…";
          statusTitle.Text="Preparando Inhouse Photos…";
          statusDetail.Text="Comprobando el programa, el motor de fotos y tu instalación actual.";
          await InstallProduct(message=>{
            if(String.IsNullOrWhiteSpace(message)||Dispatcher.HasShutdownStarted)return;
            try{Dispatcher.BeginInvoke(new Action(()=>{if(installing)statusDetail.Text=message;}));}
            catch(InvalidOperationException){ /* The window may be closing. */ }
          });
          var managed=Backend.Load().Managed;
          // InstallProduct does not complete until the existing server and its
          // persisted installation receipt are verified. A copied executable
          // alone must not expose a success state or open the manager early.
          installed=true;
          statusTitle.Text=managed?"Instalación completa y verificada":"Programa actualizado y preparado";
          statusDetail.Text=managed?"El programa y tu servidor están comprobados. Puedes abrir Inhouse Photos; tus fotos y cuentas se conservan.":
            "Al abrir Inhouse Photos, elige dónde guardar tus fotos o conecta tu biblioteca existente. Se solicitarán las condiciones y permisos que necesite este PC.";
          button.Content="Abrir Inhouse Photos";
        }catch(ManagerRunningException) {
          statusTitle.Foreground=Warning;statusTitle.Text="Cierra el programa anterior";
          statusDetail.Text="En los iconos junto al reloj de Windows, haz clic derecho en Inhouse Photos y elige «Salir del gestor». Después pulsa Reintentar. No cierres el servidor de fotos; tu biblioteca se conserva.";
          button.Content="Reintentar instalación";
        }catch(Exception ex) {
          statusTitle.Foreground=Warning;statusTitle.Text=installed?"Instalado, pero no se pudo abrir":"No se pudo completar la instalación";
          statusDetail.Text=ex.Message+(installed?" Puedes volver a abrirlo o usar el menú Inicio.":
            " Tus fotos y el trabajo pendiente se conservan. Pulsa Reintentar para continuar; no necesitas desinstalar ni volver a subir nada.");
          button.Content=installed?"Abrir Inhouse Photos":"Reintentar instalación";
        }finally {
          installing=false;progress.Visibility=Visibility.Collapsed;button.IsEnabled=true;
        }
      }
    }
    sealed class ManagerRunningException:IOException {
      public ManagerRunningException():base("El gestor anterior sigue abierto."){}
    }
  }
}
