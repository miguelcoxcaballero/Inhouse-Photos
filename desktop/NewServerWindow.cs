using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Diagnostics;
using System.Collections.Generic;
using System.Windows.Markup;

namespace InhousePhotos {
  public sealed class NewServerWindow:Window {
    readonly StackPanel panel=new StackPanel();readonly TextBlock status=new TextBlock();
    readonly TextBox folder=new TextBox(),email=new TextBox(),name=new TextBox(),domain=new TextBox();
    readonly PasswordBox password=new PasswordBox();readonly CheckBox consent=new CheckBox(),startup=new CheckBox();
    bool busy; readonly ScrollViewer viewer=new ScrollViewer(); public Preferences Result {get;private set;}
    public NewServerWindow() {
      Title="Inhouse Photos · Crear mi biblioteca";Width=660;Height=790;MinWidth=540;MinHeight=580;WindowStartupLocation=WindowStartupLocation.CenterOwner;
      Background=new SolidColorBrush(Color.FromRgb(19,17,14));Foreground=Brushes.White;FontFamily=new FontFamily("Segoe UI");FontSize=16;
      Resources.Add(typeof(Button),XamlReader.Parse(@"<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='Button'><Setter Property='BorderThickness' Value='0'/><Setter Property='Cursor' Value='Hand'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Button'><Border Background='{TemplateBinding Background}' Padding='{TemplateBinding Padding}' CornerRadius='10'><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.5'/></Trigger><Trigger Property='IsMouseOver' Value='True'><Setter Property='Opacity' Value='0.85'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>"));
      using(var brand=typeof(NewServerWindow).Assembly.GetManifestResourceStream("InhousePhotos.brand.xaml"))Icon=(ImageSource)XamlReader.Load(brand);
      panel.Margin=new Thickness(32);viewer.Content=panel;viewer.Background=Background;viewer.VerticalScrollBarVisibility=ScrollBarVisibility.Auto;Content=viewer;
      Text("Tu biblioteca empieza aquí",28);Text("Tus fotos se guardarán en este PC. No se borrarán ni moverán otras bibliotecas.",15);
      Text("1 · Dónde guardar las fotos",19);
      var dataDrive=DriveInfo.GetDrives().Where(d=>d.IsReady&&d.DriveType==DriveType.Fixed).OrderByDescending(d=>d.AvailableFreeSpace).FirstOrDefault();
      folder.Text=Path.Combine(dataDrive==null?Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments):dataDrive.RootDirectory.FullName,"Inhouse Photos Library");Input(folder);
      Button("Elegir otra carpeta",()=>{using(var picker=new System.Windows.Forms.FolderBrowserDialog()){picker.Description="Elige una carpeta vacía para la biblioteca nueva";if(picker.ShowDialog()==System.Windows.Forms.DialogResult.OK)folder.Text=picker.SelectedPath;}return Task.FromResult(0);});
      Text("2 · Tu cuenta",19);Text("Nombre",14);Input(name);Text("Correo",14);Input(email);Text("Contraseña · mínimo 12 caracteres",14);password.Padding=new Thickness(10);password.Margin=new Thickness(0,0,0,12);password.Background=new SolidColorBrush(Color.FromRgb(44,37,31));password.Foreground=Foreground;panel.Children.Add(password);
      Text("3 · Acceso desde internet (opcional)",19);Input(domain);Text("Ejemplo: fotos.ejemplo.com. Si lo indicas, apunta el dominio a este PC y abre los puertos 80 y 443 en tu router. Sin dominio, la biblioteca estará disponible solo en este ordenador.",14);
      try{if(File.Exists(NewServer.PendingFile)){var pending=Backend.Json.Deserialize<Dictionary<string,string>>(File.ReadAllText(NewServer.PendingFile));folder.Text=pending["Folder"];domain.Text=pending["Domain"];email.Text=pending["Email"];name.Text=pending["Name"];Text("Hay una preparación pendiente. Escribe la misma contraseña para continuar sin perder datos.",15);}}catch{Text("No se pudo recuperar la preparación pendiente. Selecciona su carpeta para reanudarla.",14);}
      if(!EngineSetup.Installed) {
        Text("Preparar este ordenador",19);Text("Se descargará Docker Desktop como motor. Gratis para uso personal; algunas organizaciones necesitan licencia. Puede hacer falta reiniciar Windows. No lo haremos automáticamente.",14);
        Button("Leer condiciones del motor ↗",()=>{Process.Start(new ProcessStartInfo("https://www.docker.com/legal/docker-subscription-service-agreement/"){UseShellExecute=true});return Task.FromResult(0);});
        consent.Content="He leído y acepto las condiciones de Docker Desktop";consent.Foreground=Foreground;consent.Margin=new Thickness(0,12,0,12);panel.Children.Add(consent);
        Button("Preparar componentes de Windows",async()=>{await EngineSetup.PrepareWindows();status.Text="Windows preparado. Si solicita reiniciar, hazlo y vuelve aquí para continuar.";});
      }
      startup.Content="Iniciar automáticamente al entrar en Windows";startup.Foreground=Foreground;startup.IsChecked=true;startup.Margin=new Thickness(0,18,0,12);panel.Children.Add(startup);
      Button("Crear mi biblioteca",async()=>{
        NewServer.Validate(folder.Text,email.Text,password.Password,name.Text,domain.Text.Trim().ToLowerInvariant());
        if(!EngineSetup.Installed)await EngineSetup.Install(consent.IsChecked==true,Progress);
        Result=await NewServer.Create(folder.Text,email.Text,password.Password,name.Text,domain.Text.Trim().ToLowerInvariant(),Progress);
        password.Clear();
        if(startup.IsChecked==true){try{await Startup.SetEnabled(Result,true);}catch{status.Text="Biblioteca creada. Activa el inicio automático en Ajustes después de instalar el gestor.";MessageBox.Show(this,status.Text,"Inhouse Photos");}}
        DialogResult=true;
      },true);
      status.TextWrapping=TextWrapping.Wrap;status.Foreground=new SolidColorBrush(Color.FromRgb(237,153,90));status.Margin=new Thickness(0,16,0,0);panel.Children.Add(status);
      Closing+=(s,e)=>{if(busy&&Result==null){e.Cancel=true;status.Text="Espera a que termine la preparación. Si falla podrás reanudar en esta misma carpeta.";}};
    }
    void Progress(string text){Dispatcher.Invoke(()=>{status.Text=text;viewer.ScrollToEnd();});}
    void Text(string text,int size){panel.Children.Add(new TextBlock{Text=text,FontSize=size,Foreground=Foreground,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,8,0,10)});}
    void Input(TextBox input){input.Padding=new Thickness(10);input.Margin=new Thickness(0,0,0,12);input.Background=new SolidColorBrush(Color.FromRgb(44,37,31));input.Foreground=Foreground;panel.Children.Add(input);}
    void Button(string title,Func<Task> action,bool primary=false){var button=new Button{Content=title,Padding=new Thickness(18,12,18,12),HorizontalAlignment=HorizontalAlignment.Left,Margin=new Thickness(0,6,0,10),Background=new SolidColorBrush(primary?Color.FromRgb(237,153,90):Color.FromRgb(44,37,31)),Foreground=primary?Brushes.Black:Brushes.White};panel.Children.Add(button);button.Click+=async(s,e)=>{if(busy)return;busy=true;panel.IsEnabled=false;try{await action();}catch(Exception ex){status.Text=ex is System.Net.WebException?"No se pudo completar la conexión o validar tu cuenta. Comprueba la contraseña y la conexión, y reintenta en la misma carpeta.":ex.Message;viewer.ScrollToEnd();}finally{busy=false;panel.IsEnabled=true;}};}
  }
}
