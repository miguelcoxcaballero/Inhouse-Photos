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
          throw new IOException("Cierra el gestor desde su icono junto al reloj (Salir del gestor) y vuelve a instalar. El servidor y tus fotos seguirán disponibles.");
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
    static int Launch(bool startup) {
      var record=ReadInstalled();var path=Path.Combine(Backend.InstallDir,record.RelativePath);
      using(var child=Process.Start(new ProcessStartInfo(path,startup?"--startup":""){UseShellExecute=false,CreateNoWindow=true,WindowStyle=startup?ProcessWindowStyle.Hidden:ProcessWindowStyle.Normal,WorkingDirectory=Backend.InstallDir})) {
        if(startup){child.WaitForExit();return child.ExitCode;}return 0;
      }
    }
    [STAThread] public static int Main(string[] args) {
      try {
        if(args.Contains("--launch")||args.Contains("--startup"))return Launch(args.Contains("--startup"));
        if(args.Contains("--install-current")){Install();Console.WriteLine("Instalación verificada en "+Backend.InstallDir);return 0;}
        if(args.Contains("--verify-installed")){var app=ReadInstalled();Console.WriteLine(app.Version+" "+app.Sha256);return 0;}
        var application=new Application();return application.Run(new SetupWindow());
      }catch(Exception ex){if(args.Length==0)MessageBox.Show(ex.Message,"Inhouse Photos",MessageBoxButton.OK,MessageBoxImage.Error);else Console.Error.WriteLine(ex.Message);return 1;}
    }
    sealed class SetupWindow:Window {
      public SetupWindow() {
        Title="Instalar Inhouse Photos Server";Width=560;Height=460;ResizeMode=ResizeMode.NoResize;WindowStartupLocation=WindowStartupLocation.CenterScreen;
        Background=new SolidColorBrush(Color.FromRgb(19,17,14));Foreground=Brushes.White;FontFamily=new FontFamily("Segoe UI");
        using(var brand=Assembly.GetExecutingAssembly().GetManifestResourceStream("InhousePhotos.brand.xaml"))Icon=(ImageSource)XamlReader.Load(brand);
        var panel=new StackPanel{Margin=new Thickness(38)};Content=panel;
        panel.Children.Add(new Image{Source=Icon,Height=58,Width=58,HorizontalAlignment=HorizontalAlignment.Left,Margin=new Thickness(0,0,0,18)});
        panel.Children.Add(new TextBlock{Text="Tu servidor, en una app.",FontSize=28,Margin=new Thickness(0,0,0,12)});
        panel.Children.Add(new TextBlock{Text="Instala o actualiza Inhouse Photos Server. La biblioteca, las cuentas y el servidor existente no se eliminan ni se trasladan.",FontSize=16,TextWrapping=TextWrapping.Wrap});
        var status=new TextBlock{Text="Windows 10 / 11 · versión "+Backend.Version,FontSize=14,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,20,0,20)};panel.Children.Add(status);
        var button=new Button{Content="Instalar y abrir",Padding=new Thickness(20,14,20,14),FontSize=17,BorderThickness=new Thickness(0),Background=new SolidColorBrush(Color.FromRgb(237,153,90)),Foreground=Brushes.Black};panel.Children.Add(button);
        button.Click+=async(s,e)=>{button.IsEnabled=false;status.Text="Instalando y comprobando los archivos…";try{await Task.Run((Action)Install);Launch(false);Close();}catch(Exception ex){status.Text=ex.Message;button.IsEnabled=true;}};
      }
    }
  }
}
