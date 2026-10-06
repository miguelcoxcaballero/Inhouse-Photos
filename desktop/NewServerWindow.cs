using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace InhousePhotos {
  public sealed class NewServerWindow:Window {
    static readonly Brush Page=Ui.Paper;
    static readonly Brush Ink=Ui.Ink;
    static readonly Brush Accent=Ui.Accent;
    static readonly Brush Muted=Ui.Ink2;
    static readonly Brush Outline=Ui.Hairline;
    readonly Grid root=new Grid();
    readonly StackPanel content=new StackPanel();
    readonly StackPanel footer=new StackPanel();
    readonly ScrollViewer viewer=new ScrollViewer();
    readonly TextBox folder=new TextBox(),email=new TextBox(),name=new TextBox(),domain=new TextBox();
    readonly PasswordBox password=new PasswordBox();
    readonly CheckBox consent=new CheckBox(),startup=new CheckBox();
    readonly RadioButton localAccess=new RadioButton(),remoteAccess=new RadioButton();
    TextBlock feedback,progressText;
    int step,lastRenderedStep=-1;
    bool busy,resuming,pendingReadFailed;
    public Preferences Result {get;private set;}

    public NewServerWindow() {
      Ui.Apply(this);
      var workWidth=Math.Max(320,SystemParameters.WorkArea.Width-28);
      var workHeight=Math.Max(320,SystemParameters.WorkArea.Height-28);
      Title="Inhouse Photos · Crear mi biblioteca";Width=Math.Min(700,workWidth);Height=Math.Min(780,workHeight);
      MinWidth=Math.Min(560,workWidth);MinHeight=Math.Min(520,workHeight);
      WindowStartupLocation=WindowStartupLocation.CenterOwner;
      using(var brand=typeof(NewServerWindow).Assembly.GetManifestResourceStream("InhousePhotos.brand.xaml"))Icon=(ImageSource)XamlReader.Load(brand);

      root.Background=Page;
      root.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});
      root.RowDefinitions.Add(new RowDefinition{Height=new GridLength(1,GridUnitType.Star)});
      root.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});
      viewer.Content=content;viewer.VerticalScrollBarVisibility=ScrollBarVisibility.Auto;
      viewer.HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled;viewer.Focusable=false;
      content.Margin=new Thickness(40,4,40,16);
      Grid.SetRow(viewer,1);root.Children.Add(viewer);
      Grid.SetRow(footer,2);root.Children.Add(footer);
      Content=root;

      var bestDrive=DriveInfo.GetDrives().Where(d=>d.IsReady&&d.DriveType==DriveType.Fixed).OrderByDescending(d=>d.AvailableFreeSpace).FirstOrDefault();
      folder.Text=Path.Combine(bestDrive==null?Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments):bestDrive.RootDirectory.FullName,"Inhouse Photos Library");
      startup.IsChecked=true;localAccess.GroupName="AccessType";remoteAccess.GroupName="AccessType";localAccess.IsChecked=true;
      localAccess.Content="Solo en este ordenador";remoteAccess.Content="También desde internet";
      localAccess.Checked+=(s,e)=>{domain.IsEnabled=false;};
      remoteAccess.Checked+=(s,e)=>{domain.IsEnabled=true;};
      AutomationProperties.SetName(folder,"Carpeta de la biblioteca");AutomationProperties.SetName(name,"Nombre");
      AutomationProperties.SetName(email,"Correo electrónico");AutomationProperties.SetName(password,"Contraseña");AutomationProperties.SetName(domain,"Dominio");
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

    internal void PreviewStep(int target){step=target;Render();}

    void Render() {
      var stepChanged=lastRenderedStep>=0&&lastRenderedStep!=step;
      root.Children.OfType<FrameworkElement>().Where(x=>Grid.GetRow(x)==0).ToList().ForEach(x=>root.Children.Remove(x));
      foreach(var control in new FrameworkElement[]{folder,email,name,domain,password,consent,startup,localAccess,remoteAccess})
        if(control.Parent is Panel parent)parent.Children.Remove(control);
      content.Children.Clear();footer.Children.Clear();
      RenderHeader();
      if(step==0)RenderLocation();
      else if(step==1)RenderAccount();
      else if(step==2)RenderAccess();
      else if(step==3)RenderReview();
      else RenderInstalling();
      RenderFooter();
      viewer.ScrollToTop();
      if(stepChanged&&IsLoaded&&SystemParameters.ClientAreaAnimation&&!Environment.GetCommandLineArgs().Contains("--render-setup-preview"))
        Ui.Enter(content,6,160);
      lastRenderedStep=step;
    }

    void RenderHeader() {
      var wrap=new StackPanel{Margin=new Thickness(40,24,40,24)};
      var titleRow=new Grid();titleRow.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
      titleRow.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(1,GridUnitType.Star)});
      titleRow.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
      titleRow.Children.Add(new Image{Source=Icon,Width=24,Height=24,VerticalAlignment=VerticalAlignment.Center,Margin=new Thickness(0,0,10,0)});
      var windowTitle=Ui.Text("Crear mi biblioteca",15,Ink,true);windowTitle.VerticalAlignment=VerticalAlignment.Center;Grid.SetColumn(windowTitle,1);
      titleRow.Children.Add(windowTitle);
      var count=Ui.Caption(step==4?"Preparando":"Paso "+(step+1)+" de 4");count.VerticalAlignment=VerticalAlignment.Center;
      Grid.SetColumn(count,2);titleRow.Children.Add(count);wrap.Children.Add(titleRow);
      // Segmented progress: completed and current segments in accent.
      var stages=new Grid{Margin=new Thickness(0,20,0,0)};
      var names=new[]{"Ubicación","Cuenta","Acceso","Confirmar"};
      for(int i=0;i<4;i++)stages.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(1,GridUnitType.Star)});
      for(int i=0;i<4;i++) {
        var part=new StackPanel{Margin=new Thickness(i==0?0:4,0,i==3?0:4,0)};
        part.Children.Add(new Border{Background=i<=step?Accent:Ui.Stroke,Height=3,CornerRadius=new CornerRadius(1.5)});
        var stageRow=new StackPanel{Orientation=Orientation.Horizontal,Margin=new Thickness(0,8,0,0)};
        if(i<step){var done=Ui.Icon("check",12,Accent,2.2);done.Margin=new Thickness(0,0,6,0);done.VerticalAlignment=VerticalAlignment.Center;stageRow.Children.Add(done);}
        var stageLabel=Ui.Text(names[i],Ui.CaptionSize,i==step?Ink:Ui.Ink3,i==step);stageLabel.TextWrapping=TextWrapping.NoWrap;
        stageRow.Children.Add(stageLabel);part.Children.Add(stageRow);
        AutomationProperties.SetName(part,names[i]+(i<step?", completado":i==step?", paso actual":""));
        Grid.SetColumn(part,i);stages.Children.Add(part);
      }
      wrap.Children.Add(stages);Grid.SetRow(wrap,0);root.Children.Add(wrap);
    }

    void RenderLocation() {
      Heading("Elige dónde guardar las fotos","Esta será la biblioteca nueva. No se moverán ni borrarán fotos de otras carpetas.");
      var location=Section();
      location.Children.Add(FieldLabel("Carpeta de la biblioteca",new Thickness(0,0,0,6)));
      var pickRow=new Grid();pickRow.ColumnDefinitions.Add(new ColumnDefinition());pickRow.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
      AddInput(pickRow,folder);
      var choose=ActionButton("Elegir carpeta…",async()=>{
        using(var picker=new System.Windows.Forms.FolderBrowserDialog()){
          picker.Description="Elige una carpeta vacía para la biblioteca nueva";
          if(picker.ShowDialog()==System.Windows.Forms.DialogResult.OK){folder.Text=picker.SelectedPath;Render();}
        }
        await Task.CompletedTask;
      });choose.Margin=new Thickness(8,0,0,0);Grid.SetColumn(choose,1);pickRow.Children.Add(choose);
      location.Children.Add(pickRow);
      var drive=SafeDrive(folder.Text);
      var disk=Ui.Caption(drive==null?"Elige una carpeta en un disco interno.":"Disco "+drive.Name.TrimEnd('\\')+" · "+FormatSize(drive.AvailableFreeSpace)+" disponibles");
      disk.Margin=new Thickness(0,8,0,0);location.Children.Add(disk);
      if(resuming)Note("Preparación pendiente","Puedes continuar en la misma carpeta. La aplicación no sustituirá los datos que ya haya creado.",true);
      else if(pendingReadFailed)Note("Comprueba la carpeta","No se pudo leer una preparación anterior. Selecciona la misma carpeta si quieres reanudarla; nunca se borrará automáticamente.",true);
      else Note("Antes de empezar","Necesitas una carpeta vacía y al menos 10 GB libres, mejor en un disco con espacio para crecer.",false);
    }

    void RenderAccount() {
      Heading("Tu cuenta de administrador","La usarás para entrar desde el móvil y gestionar tu biblioteca.");
      var account=Section();account.Width=440;account.HorizontalAlignment=HorizontalAlignment.Left;
      account.Children.Add(FieldLabel("Nombre",new Thickness(0,0,0,6)));AddInput(account,name);
      account.Children.Add(FieldLabel("Correo electrónico",new Thickness(0,16,0,6)));AddInput(account,email);
      account.Children.Add(FieldLabel("Contraseña",new Thickness(0,16,0,6)));AddPassword(account,password);
      var rule=Ui.Caption("Mínimo 12 caracteres. Se usa para crear y verificar tu cuenta; el asistente no la guarda.");rule.Margin=new Thickness(0,8,0,0);account.Children.Add(rule);
      if(resuming)Note("Si estás reanudando","Introduce la misma contraseña de la primera vez para comprobar la cuenta que ya se haya creado.",true);
    }

    void RenderAccess() {
      Heading("¿Desde dónde quieres entrar?","Usa la biblioteca en este PC o prepara el acceso con tu propio dominio.");
      var access=Section();
      StyleChoice(localAccess);StyleChoice(remoteAccess);
      access.Children.Add(localAccess);
      access.Children.Add(Ui.Text("Sin configurar internet ahora. Más adelante podrás preparar el acceso externo.",Ui.BodySize,Muted));
      ((FrameworkElement)access.Children[access.Children.Count-1]).Margin=new Thickness(30,2,0,20);
      access.Children.Add(new Border{Height=1,Background=Outline,Margin=new Thickness(0,0,0,20)});
      access.Children.Add(remoteAccess);
      var remoteDetail=Ui.Text("Para entrar desde el móvil fuera de casa necesitas un dominio.",Ui.BodySize,Muted);remoteDetail.Margin=new Thickness(30,2,0,12);access.Children.Add(remoteDetail);
      access.Children.Add(FieldLabel("Dominio",new Thickness(30,0,0,6)));
      domain.Margin=new Thickness(30,0,0,0);domain.Width=410;domain.HorizontalAlignment=HorizontalAlignment.Left;AddInput(access,domain);
      domain.IsEnabled=remoteAccess.IsChecked==true;
      Note("Para que funcione desde internet","Tu dominio debe apuntar a este PC y el router debe dirigir los puertos 80 y 443. Escribir el dominio aquí no realiza esos cambios por sí solo.",true);
    }

    void RenderReview() {
      Heading("Revisa y crea tu biblioteca","La instalación empieza solo cuando pulses Crear mi biblioteca.");
      var review=Section();
      review.Children.Add(new Border{Height=1,Background=Outline});
      Summary(review,"Fotos en",folder.Text);
      Summary(review,"Cuenta",email.Text);
      Summary(review,"Acceso",String.IsNullOrEmpty(SelectedDomain())?"Solo en este PC":"https://"+SelectedDomain());
      Summary(review,"Componentes",EngineSetup.Installed?"Listos":"Se prepararán en este PC");
      startup.Content="Abrir Inhouse Photos al entrar en Windows";
      startup.Margin=new Thickness(0,20,0,2);
      review.Children.Add(startup);
      var keepsRunning=Ui.Caption("El servidor seguirá funcionando aunque cierres esta ventana.");keepsRunning.Margin=new Thickness(28,2,0,0);review.Children.Add(keepsRunning);
      if(!EngineSetup.Installed) {
        Note("Componente necesario","Se instalará Docker Desktop como motor del servidor. Es gratuito para uso personal; algunas organizaciones necesitan licencia. Windows puede pedirte reiniciar, pero no lo haremos automáticamente.",false);
        var terms=ActionButton("Leer condiciones de Docker",async()=>{
          Process.Start(new ProcessStartInfo("https://www.docker.com/legal/docker-subscription-service-agreement/"){UseShellExecute=true});
          await Task.CompletedTask;
        },false,"Link","external");terms.Margin=new Thickness(30,-8,0,0);content.Children.Add(terms);
        consent.Content=Ui.Text("He leído y acepto las condiciones de Docker Desktop",Ui.BodySize,Ink);
        AutomationProperties.SetName(consent,"He leído y acepto las condiciones de Docker Desktop");
        consent.Margin=new Thickness(0,16,0,12);content.Children.Add(consent);
        content.Children.Add(ActionButton("Preparar componentes de Windows",async()=>{
          await EngineSetup.PrepareWindows();
          ShowFeedback("Windows preparado. Si te pide reiniciar, hazlo y vuelve aquí para continuar.");
        }));
      }
      Note("Tus datos están protegidos","Si se interrumpe la preparación, podrás reanudar en la misma carpeta. No se borra una biblioteca existente.",false,"shield");
    }

    void RenderInstalling() {
      Heading("Preparando tu biblioteca","Esto puede tardar unos minutos.");
      var card=Section();
      card.Children.Add(new Ui.ActivityBar{Margin=new Thickness(0,4,0,20)});
      progressText=Ui.Text("Comprobando los componentes…",Ui.SubtitleSize,Ink);progressText.Margin=new Thickness(0,0,0,8);
      AutomationProperties.SetLiveSetting(progressText,AutomationLiveSetting.Polite);
      card.Children.Add(progressText);
      card.Children.Add(Ui.Secondary("No cierres esta ventana mientras se prepara el servidor."));
      Note("Si hay una interrupción","La preparación se puede reanudar sin borrar la carpeta de la biblioteca.",false,"shield");
    }

    void RenderFooter() {
      footer.Background=Page;footer.Margin=new Thickness(0);
      if(step!=4)footer.Children.Add(new Border{Height=1,Background=Outline});
      var inner=new StackPanel{Margin=new Thickness(40,16,40,20)};footer.Children.Add(inner);
      feedback=Ui.Text("",Ui.BodySize,Accent);feedback.Visibility=Visibility.Collapsed;
      AutomationProperties.SetLiveSetting(feedback,AutomationLiveSetting.Assertive);
      inner.Children.Add(feedback);
      if(step==4)return;
      var row=new Grid();row.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(1,GridUnitType.Star)});
      row.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
      row.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
      if(step>0){var back=ActionButton("Atrás",async()=>{step--;Render();await Task.CompletedTask;});back.Margin=new Thickness(0,0,8,0);Grid.SetColumn(back,1);row.Children.Add(back);}
      var next=ActionButton(step==3?"Crear mi biblioteca":"Continuar",async()=>{
        if(step==0)ValidateLocation();
        if(step>=1)NewServer.Validate(folder.Text,email.Text,password.Password,name.Text,step==2?SelectedDomain():"");
        if(step==3){await Install();return;}
        step++;Render();await Task.CompletedTask;
      },true);
      next.Margin=new Thickness(0);
      Grid.SetColumn(next,2);row.Children.Add(next);inner.Children.Add(row);
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
    void ShowFeedback(string text){
      if(feedback!=null){feedback.Text=text;feedback.Margin=new Thickness(0,0,0,String.IsNullOrEmpty(text)?0:12);feedback.Visibility=String.IsNullOrEmpty(text)||step==4?Visibility.Collapsed:Visibility.Visible;}
      if(step==4&&progressText!=null)progressText.Text=text;
    }

    void Heading(string title,string subtitle){
      var heading=Ui.Display(title);heading.Margin=new Thickness(0,0,0,6);
      content.Children.Add(heading);
      var line=Ui.Secondary(subtitle);line.Margin=new Thickness(0,0,0,28);content.Children.Add(line);
    }
    StackPanel Section(){
      var section=new StackPanel{Margin=new Thickness(0,0,0,8)};
      content.Children.Add(section);
      return section;
    }
    // A note is an icon and a sentence, never a box. "highlight" marks the ones
    // that ask for attention.
    void Note(string title,string detail,bool highlight,string icon=null){
      var row=new Grid{Margin=new Thickness(0,24,0,0)};
      row.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(30)});row.ColumnDefinitions.Add(new ColumnDefinition());
      var glyph=Ui.Icon(icon??(highlight?"alert":"info"),18,icon=="shield"?Ui.Good:highlight?Accent:Muted);glyph.VerticalAlignment=VerticalAlignment.Top;glyph.HorizontalAlignment=HorizontalAlignment.Left;glyph.Margin=new Thickness(0,1,0,0);row.Children.Add(glyph);
      var note=Ui.Text("",Ui.BodySize,Muted);
      note.Inlines.Add(new Run(title){FontWeight=FontWeights.SemiBold,Foreground=Ink});
      note.Inlines.Add(new LineBreak());
      note.Inlines.Add(new Run(detail));
      Grid.SetColumn(note,1);row.Children.Add(note);
      content.Children.Add(row);
    }
    static void Summary(StackPanel target,string title,string value){
      var row=new Grid{Margin=new Thickness(0,12,0,12)};row.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(140)});
      row.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(1,GridUnitType.Star)});
      row.Children.Add(Ui.Text(title,Ui.BodySize,Muted));
      var answer=Ui.Text(value,Ui.BodySize,Ink,true);
      Grid.SetColumn(answer,1);row.Children.Add(answer);target.Children.Add(row);
      target.Children.Add(new Border{Height=1,Background=Outline});
    }
    static TextBlock FieldLabel(string value,Thickness margin){var label=Ui.Text(value,Ui.BodySize,Ink);label.Margin=margin;return label;}
    static void AddInput(Panel parent,TextBox input){parent.Children.Add(input);}
    static void AddPassword(Panel parent,PasswordBox input){parent.Children.Add(input);}
    static void StyleChoice(RadioButton option){option.FontSize=Ui.SubtitleSize;option.Margin=new Thickness(0);}
    Button ActionButton(string title,Func<Task> action,bool primary=false,string style=null,string icon=null){
      var button=Ui.Button(title,style??(primary?"Primary":"Secondary"),icon);
      button.Margin=new Thickness(0);
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
