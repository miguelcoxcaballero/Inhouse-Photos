using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;

namespace InhousePhotos {
  public sealed class NewServerWindow:Window {
    static readonly Brush Page=new SolidColorBrush(Color.FromRgb(246,243,238));
    static readonly Brush Surface=new SolidColorBrush(Color.FromRgb(255,252,248));
    static readonly Brush Field=Brushes.White;
    static readonly Brush Ink=new SolidColorBrush(Color.FromRgb(32,28,24));
    static readonly Brush Accent=new SolidColorBrush(Color.FromRgb(169,71,18));
    static readonly Brush Muted=new SolidColorBrush(Color.FromRgb(109,98,89));
    static readonly Brush Outline=new SolidColorBrush(Color.FromRgb(226,216,205));
    readonly Grid root=new Grid();
    readonly StackPanel content=new StackPanel();
    readonly StackPanel footer=new StackPanel();
    readonly ScrollViewer viewer=new ScrollViewer();
    readonly TextBox folder=new TextBox(),email=new TextBox(),name=new TextBox(),domain=new TextBox();
    readonly PasswordBox password=new PasswordBox();
    readonly CheckBox consent=new CheckBox(),startup=new CheckBox();
    readonly RadioButton localAccess=new RadioButton(),remoteAccess=new RadioButton();
    TextBlock feedback,progressText;
    int step;
    bool busy,resuming,pendingReadFailed;
    public Preferences Result {get;private set;}

    public NewServerWindow() {
      var workWidth=Math.Max(320,SystemParameters.WorkArea.Width-28);
      var workHeight=Math.Max(320,SystemParameters.WorkArea.Height-28);
      Title="Inhouse Photos · Crear mi biblioteca";Width=Math.Min(700,workWidth);Height=Math.Min(780,workHeight);
      MinWidth=Math.Min(540,workWidth);MinHeight=Math.Min(460,workHeight);
      WindowStartupLocation=WindowStartupLocation.CenterOwner;
      Background=Page;Foreground=Ink;
      FontFamily=new FontFamily("Segoe UI");FontSize=16;
      Resources.Add(typeof(Button),XamlReader.Parse(@"<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='Button'><Setter Property='Cursor' Value='Hand'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Button'><Border Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' Padding='{TemplateBinding Padding}' CornerRadius='8'><ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/></Border><ControlTemplate.Triggers><Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.45'/></Trigger><Trigger Property='IsMouseOver' Value='True'><Setter Property='Opacity' Value='0.84'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>"));
      using(var brand=typeof(NewServerWindow).Assembly.GetManifestResourceStream("InhousePhotos.brand.xaml"))Icon=(ImageSource)XamlReader.Load(brand);

      root.Background=Page;
      root.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});
      root.RowDefinitions.Add(new RowDefinition{Height=new GridLength(1,GridUnitType.Star)});
      root.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});
      viewer.Content=content;viewer.VerticalScrollBarVisibility=ScrollBarVisibility.Auto;
      viewer.HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled;
      viewer.Margin=new Thickness(30,6,30,8);
      Grid.SetRow(viewer,1);root.Children.Add(viewer);
      Grid.SetRow(footer,2);root.Children.Add(footer);
      Content=root;

      var bestDrive=DriveInfo.GetDrives().Where(d=>d.IsReady&&d.DriveType==DriveType.Fixed).OrderByDescending(d=>d.AvailableFreeSpace).FirstOrDefault();
      folder.Text=Path.Combine(bestDrive==null?Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments):bestDrive.RootDirectory.FullName,"Inhouse Photos Library");
      startup.IsChecked=true;localAccess.GroupName="AccessType";remoteAccess.GroupName="AccessType";localAccess.IsChecked=true;
      localAccess.Content="Solo en este ordenador";remoteAccess.Content="También desde internet";
      localAccess.Checked+=(s,e)=>{domain.IsEnabled=false;};
      remoteAccess.Checked+=(s,e)=>{domain.IsEnabled=true;};
      try {
        if(File.Exists(NewServer.PendingFile)) {
          var pending=Backend.Json.Deserialize<Dictionary<string,string>>(File.ReadAllText(NewServer.PendingFile));
          folder.Text=pending["Folder"];domain.Text=pending["Domain"];email.Text=pending["Email"];name.Text=pending["Name"];
          remoteAccess.IsChecked=!String.IsNullOrEmpty(domain.Text);localAccess.IsChecked=!remoteAccess.IsChecked;
          resuming=true;
        }
      } catch {pendingReadFailed=true;}
      Closing+=(s,e)=>{if(busy&&Result==null){e.Cancel=true;ShowFeedback("Espera a que termine la preparación. Si falla, podrás reanudarla en la misma carpeta.");}};
      Render();
    }

    void Render() {
      root.Children.OfType<FrameworkElement>().Where(x=>Grid.GetRow(x)==0).ToList().ForEach(x=>root.Children.Remove(x));
      content.Children.Clear();footer.Children.Clear();
      RenderHeader();
      if(step==0)RenderLocation();
      else if(step==1)RenderAccount();
      else if(step==2)RenderAccess();
      else if(step==3)RenderReview();
      else RenderInstalling();
      RenderFooter();
      viewer.ScrollToTop();
    }

    void RenderHeader() {
      var wrap=new StackPanel{Margin=new Thickness(30,24,30,15)};
      var titleRow=new Grid();titleRow.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(1,GridUnitType.Star)});
      titleRow.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
      var identity=new StackPanel();identity.Children.Add(Label("INHOUSE PHOTOS",12,Accent,new Thickness(0,0,0,3)));
      identity.Children.Add(Label("Tu biblioteca, bajo tu control",22,Ink,new Thickness(0,0,0,0)));
      titleRow.Children.Add(identity);
      var count=Label(step==4?"PREPARANDO":"PASO "+(step+1)+" DE 4",12,Muted,new Thickness(12,8,0,0));
      Grid.SetColumn(count,1);titleRow.Children.Add(count);wrap.Children.Add(titleRow);
      var stages=new Grid{Margin=new Thickness(0,22,0,0)};
      var names=new[]{"Ubicación","Cuenta","Acceso","Confirmar"};
      for(int i=0;i<4;i++)stages.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(1,GridUnitType.Star)});
      for(int i=0;i<4;i++) {
        var part=new StackPanel{Margin=new Thickness(i==0?0:3,0,i==3?0:3,0)};
        part.Children.Add(new Border{Background=i<=step?Accent:Outline,Height=3,CornerRadius=new CornerRadius(2)});
        part.Children.Add(Label(names[i],12,i==step?Ink:Muted,new Thickness(0,7,0,0)));
        Grid.SetColumn(part,i);stages.Children.Add(part);
      }
      wrap.Children.Add(stages);Grid.SetRow(wrap,0);root.Children.Add(wrap);
    }

    void RenderLocation() {
      Heading("Elige dónde guardar las fotos","Esta será la biblioteca nueva. La instalación no moverá ni borrará fotos de otras carpetas.");
      var location=Card();
      var drive=SafeDrive(folder.Text);
      var disk=new Grid();disk.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
      disk.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(1,GridUnitType.Star)});
      var mark=new Border{Width=54,Height=54,CornerRadius=new CornerRadius(13),Background=Field,Margin=new Thickness(0,0,16,0),Child=Label(drive==null?"PC":drive.Name.TrimEnd('\\').ToUpperInvariant(),17,Accent,new Thickness(0))};
      disk.Children.Add(mark);var description=new StackPanel{VerticalAlignment=VerticalAlignment.Center};
      description.Children.Add(Label(drive==null?"Almacenamiento local":"Disco "+drive.Name.TrimEnd('\\'),17,Ink,new Thickness(0)));
      description.Children.Add(Label(drive==null?"Elige una carpeta en un disco interno":FormatSize(drive.AvailableFreeSpace)+" disponibles",14,Muted,new Thickness(0,4,0,0)));
      Grid.SetColumn(description,1);disk.Children.Add(description);location.Children.Add(disk);
      location.Children.Add(Label("CARPETA DE LA BIBLIOTECA",12,Muted,new Thickness(0,20,0,8)));
      AddInput(location,folder);
      location.Children.Add(ActionButton("Elegir carpeta",async()=>{
        using(var picker=new System.Windows.Forms.FolderBrowserDialog()){
          picker.Description="Elige una carpeta vacía para la biblioteca nueva";
          if(picker.ShowDialog()==System.Windows.Forms.DialogResult.OK){folder.Text=picker.SelectedPath;Render();}
        }
        await Task.CompletedTask;
      }));
      if(resuming)Note("Preparación pendiente","Puedes continuar en la misma carpeta. La aplicación no sustituirá los datos que ya haya creado.",true);
      else if(pendingReadFailed)Note("Comprueba la carpeta","No se pudo leer una preparación anterior. Selecciona la misma carpeta si quieres reanudarla; nunca se borrará automáticamente.",true);
      else Note("Antes de empezar","Necesitas una carpeta vacía y al menos 10 GB libres. Recomendamos un disco con espacio para el crecimiento de tu biblioteca.",false);
    }

    void RenderAccount() {
      Heading("Tu cuenta de administrador","La usarás para entrar desde el móvil y gestionar tu biblioteca.");
      var account=Card();
      account.Children.Add(Label("NOMBRE",12,Muted,new Thickness(0,0,0,8)));AddInput(account,name);
      account.Children.Add(Label("CORREO ELECTRÓNICO",12,Muted,new Thickness(0,10,0,8)));AddInput(account,email);
      account.Children.Add(Label("CONTRASEÑA",12,Muted,new Thickness(0,10,0,8)));AddPassword(account,password);
      account.Children.Add(Label("Mínimo 12 caracteres. No se mostrará en el resumen.",13,Muted,new Thickness(0,4,0,0)));
      Note("Tu cuenta es privada","La contraseña se utiliza para crear y verificar tu cuenta; no se guardará en el asistente.",false);
      if(resuming)Note("Si estás reanudando","Introduce la misma contraseña de la primera vez para comprobar la cuenta que ya se haya creado.",true);
    }

    void RenderAccess() {
      Heading("¿Desde dónde quieres entrar?","Puedes usar la biblioteca en este PC o preparar el acceso con tu propio dominio.");
      var access=Card();
      StyleChoice(localAccess);StyleChoice(remoteAccess);
      access.Children.Add(localAccess);
      access.Children.Add(Label("Sin configurar internet ahora. Más adelante podrás preparar el acceso externo con ayuda técnica.",14,Muted,new Thickness(31,3,0,19)));
      access.Children.Add(new Border{Height=1,Background=Outline,Margin=new Thickness(0,0,0,16)});
      access.Children.Add(remoteAccess);
      access.Children.Add(Label("Para entrar desde el móvil fuera de casa necesitas un dominio.",14,Muted,new Thickness(31,3,0,13)));
      access.Children.Add(Label("DOMINIO",12,Muted,new Thickness(31,0,0,8)));
      domain.Margin=new Thickness(31,0,0,0);AddInput(access,domain);
      domain.IsEnabled=remoteAccess.IsChecked==true;
      Note("Para que funcione desde internet","Tu dominio debe apuntar a este PC y el router debe dirigir los puertos 80 y 443. Escribir el dominio aquí no realiza esos cambios por sí solo.",true);
    }

    void RenderReview() {
      Heading("Revisa y crea tu biblioteca","Solo comenzaremos la instalación cuando pulses el botón de abajo.");
      var review=Card();
      Summary(review,"FOTOS EN",folder.Text);
      Summary(review,"CUENTA",email.Text);
      Summary(review,"ACCESO",String.IsNullOrEmpty(SelectedDomain())?"Solo en este PC":"https://"+SelectedDomain());
      Summary(review,"COMPONENTES",EngineSetup.Installed?"Listos":"Se prepararán en este PC");
      startup.Content="Abrir Inhouse Photos al entrar en Windows";
      startup.Foreground=Ink;startup.Margin=new Thickness(0,18,0,2);
      review.Children.Add(startup);
      review.Children.Add(Label("El servidor seguirá funcionando aunque cierres esta ventana.",13,Muted,new Thickness(26,0,0,0)));
      if(!EngineSetup.Installed) {
        Note("Componente necesario","Se instalará Docker Desktop como motor del servidor. Es gratuito para uso personal; algunas organizaciones necesitan licencia. Windows puede pedirte reiniciar, pero no lo haremos automáticamente.",false);
        var terms=ActionButton("Leer condiciones de Docker ↗",async()=>{
          Process.Start(new ProcessStartInfo("https://www.docker.com/legal/docker-subscription-service-agreement/"){UseShellExecute=true});
          await Task.CompletedTask;
        });content.Children.Add(terms);
        consent.Content=Label("He leído y acepto las condiciones de Docker Desktop",14,Ink,new Thickness(0));
        consent.Foreground=Ink;
        consent.Margin=new Thickness(0,14,0,10);content.Children.Add(consent);
        content.Children.Add(ActionButton("Preparar componentes de Windows",async()=>{
          await EngineSetup.PrepareWindows();
          ShowFeedback("Windows preparado. Si te pide reiniciar, hazlo y vuelve aquí para continuar.");
        }));
      }
      Note("Tus datos están protegidos","Si se interrumpe la preparación, podrás reanudar en la misma carpeta. No se borra una biblioteca existente.",true);
    }

    void RenderInstalling() {
      Heading("Preparando tu biblioteca","Esto puede tardar unos minutos. Puedes seguir el avance aquí.");
      var card=Card();
      var ring=new ProgressBar{IsIndeterminate=true,Height=5,Foreground=Accent,Background=Outline,Margin=new Thickness(0,10,0,22)};
      card.Children.Add(ring);
      progressText=Label("Comprobando los componentes…",18,Ink,new Thickness(0,0,0,12));
      card.Children.Add(progressText);
      card.Children.Add(Label("No cierres esta ventana mientras se prepara el servidor.",14,Muted,new Thickness(0)));
      Note("Si hay una interrupción","La preparación se puede reanudar sin borrar la carpeta de la biblioteca.",false);
    }

    void RenderFooter() {
      footer.Background=Page;footer.Margin=new Thickness(30,14,30,18);
      feedback=Label("",13,Accent,new Thickness(0,0,0,0));feedback.TextWrapping=TextWrapping.Wrap;
      footer.Children.Add(feedback);
      if(step==4)return;
      var row=new Grid();row.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(1,GridUnitType.Star)});
      row.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
      if(step>0){var back=ActionButton("Atrás",async()=>{step--;Render();await Task.CompletedTask;});row.Children.Add(back);}
      var next=ActionButton(step==3?"Crear mi biblioteca":"Continuar",async()=>{
        if(step==0)ValidateLocation();
        if(step>=1)NewServer.Validate(folder.Text,email.Text,password.Password,name.Text,step==2?SelectedDomain():"");
        if(step==3){await Install();return;}
        step++;Render();await Task.CompletedTask;
      },true);
      Grid.SetColumn(next,1);row.Children.Add(next);footer.Children.Add(row);
    }

    async Task Install() {
      NewServer.Validate(folder.Text,email.Text,password.Password,name.Text,SelectedDomain());
      if(!EngineSetup.Installed&&consent.IsChecked!=true)throw new ArgumentException("Para instalar el motor, lee y acepta primero sus condiciones.");
      step=4;Render();
      try {
        if(!EngineSetup.Installed)await EngineSetup.Install(consent.IsChecked==true,Progress);
        Result=await NewServer.Create(folder.Text,email.Text,password.Password,name.Text,SelectedDomain(),Progress);
        password.Clear();
        if(startup.IsChecked==true){
          try{await Startup.SetEnabled(Result,true);}
          catch{MessageBox.Show(this,"Biblioteca creada. Activa el inicio automático en Ajustes después de instalar el gestor.","Inhouse Photos");}
        }
        DialogResult=true;
      } catch {
        step=3;Render();
        throw;
      }
    }

    void ValidateLocation() {
      NewServer.Validate(folder.Text,"check@example.com","123456789012","Comprobación","");
      var path=Path.GetFullPath(folder.Text);
      if(Directory.Exists(path)&&Directory.EnumerateFileSystemEntries(path).Any()&&!File.Exists(Path.Combine(path,"inhouse-setup.json")))
        throw new IOException("Esta carpeta ya contiene archivos. Elige una carpeta vacía para no tocar los datos existentes.");
      var drive=SafeDrive(path);
      if(drive==null||drive.AvailableFreeSpace<10L*1024*1024*1024)
        throw new IOException("Elige un disco local con al menos 10 GB libres.");
    }

    string SelectedDomain(){return remoteAccess.IsChecked==true?domain.Text.Trim().ToLowerInvariant():"";}
    static DriveInfo SafeDrive(string path){try{var drive=new DriveInfo(Path.GetPathRoot(Path.GetFullPath(path)));return drive.IsReady&&drive.DriveType==DriveType.Fixed?drive:null;}catch{return null;}}
    static string FormatSize(long bytes){return (bytes/1073741824.0).ToString("N0")+" GB";}
    void Progress(string text){Dispatcher.Invoke(()=>{if(progressText!=null)progressText.Text=text;ShowFeedback(text);});}
    void ShowFeedback(string text){if(feedback!=null){feedback.Text=text;feedback.Margin=new Thickness(0,0,0,String.IsNullOrEmpty(text)?0:12);}if(step==4&&progressText!=null)progressText.Text=text;}

    void Heading(string title,string subtitle){
      content.Children.Add(Label(title,28,Ink,new Thickness(0,4,0,9)));
      content.Children.Add(Label(subtitle,15,Muted,new Thickness(0,0,0,20)));
    }
    StackPanel Card(){
      var inside=new StackPanel();
      content.Children.Add(new Border{Child=inside,Background=Surface,CornerRadius=new CornerRadius(10),Padding=new Thickness(22),Margin=new Thickness(0,0,0,16)});
      return inside;
    }
    void Note(string title,string detail,bool highlight){
      var box=new StackPanel();box.Children.Add(Label(title,15,highlight?Accent:Ink,new Thickness(0,0,0,5)));
      box.Children.Add(Label(detail,14,Muted,new Thickness(0)));
      content.Children.Add(new Border{Child=box,BorderBrush=highlight?Accent:Outline,BorderThickness=new Thickness(2,0,0,0),Padding=new Thickness(14,3,0,3),Margin=new Thickness(0,1,0,19)});
    }
    static void Summary(StackPanel target,string title,string value){
      target.Children.Add(Label(title,12,Muted,new Thickness(0,0,0,5)));
      target.Children.Add(Label(value,17,Ink,new Thickness(0,0,0,16)));
    }
    static TextBlock Label(string value,int size,Brush color,Thickness margin){return new TextBlock{Text=value,FontSize=size,Foreground=color,TextWrapping=TextWrapping.Wrap,Margin=margin};}
    static void AddInput(StackPanel parent,TextBox input){
      input.Padding=new Thickness(12,11,12,11);input.Background=Field;input.Foreground=Ink;
      input.CaretBrush=Accent;input.BorderBrush=Outline;input.BorderThickness=new Thickness(1);
      input.MinHeight=44;parent.Children.Add(input);
    }
    static void AddPassword(StackPanel parent,PasswordBox input){
      input.Padding=new Thickness(12,11,12,11);input.Background=Field;input.Foreground=Ink;
      input.CaretBrush=Accent;input.BorderBrush=Outline;input.BorderThickness=new Thickness(1);
      input.MinHeight=44;parent.Children.Add(input);
    }
    static void StyleChoice(RadioButton option){option.Foreground=Ink;option.FontSize=17;option.Margin=new Thickness(0);option.Cursor=System.Windows.Input.Cursors.Hand;}
    Button ActionButton(string title,Func<Task> action,bool primary=false){
      var button=new Button{Content=title,Padding=new Thickness(18,12,18,12),MinHeight=44,
        HorizontalAlignment=HorizontalAlignment.Left,Background=primary?Accent:Surface,
        BorderBrush=primary?Accent:Outline,BorderThickness=new Thickness(primary?0:1),
        Foreground=primary?Brushes.White:Accent,Margin=new Thickness(0,0,0,0)};
      button.Click+=async(s,e)=>{
        if(busy)return;busy=true;button.IsEnabled=false;
        try{await action();}
        catch(Exception ex){ShowFeedback(ex is System.Net.WebException?"No se pudo conectar. Comprueba la conexión y reintenta en la misma carpeta.":ex.Message);}
        finally{busy=false;button.IsEnabled=true;}
      };
      return button;
    }
  }
}
