using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Diagnostics;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Ellipse = System.Windows.Shapes.Ellipse;

namespace InhousePhotos {
  public sealed partial class ServerWindow {
    readonly Brush good=new SolidColorBrush(Color.FromRgb(153,196,154));
    readonly Brush surface=new SolidColorBrush(Color.FromRgb(35,29,24));
    readonly Brush divider=new SolidColorBrush(Color.FromRgb(64,53,44));
    bool? lastLocal, lastEndpoint, lastVerified;
    DateTime lastHealthCheck=DateTime.MinValue;
    int overviewGeneration;
    string backupProgressText;
    TextBlock backupProgressView;

    void SetBackupProgress(string text) {
      backupProgressText=text;
      notice.Text=text;
      if(page=="Protección"&&backupProgressView!=null)backupProgressView.Text=text;
    }

    Task RenderManagedPage() {
      switch(page) {
        case "Inicio": return RenderOverview();
        case "Protección": return RenderBackupPage();
        case "Discos": return RenderStoragePage();
        case "Conectar": return RenderConnectPage();
        case "Configuración": return RenderSettingsPage();
        default: page="Inicio";return RenderOverview();
      }
    }

    Border Panel(Panel inside) {
      return new Border {Background=surface,CornerRadius=new CornerRadius(16),Padding=new Thickness(24,22,24,22),
        Margin=new Thickness(0,4,0,16),Child=inside};
    }
    StackPanel Column() {return new StackPanel{Orientation=Orientation.Vertical};}
    Button PlaceAction(Panel host,string caption,Func<Task> task,bool primary=false) {
      var button=Action(caption,task,primary);
      content.Children.Remove(button);
      host.Children.Add(button);
      return button;
    }
    TextBlock Fine(string text,Brush color=null) {return Label(text,14,color??muted);}
    Task GoTo(string target) {page=target;return Render();}
    string DateLabel(string iso) {
      DateTime value;
      return DateTime.TryParse(iso,out value)?value.ToLocalTime().ToString("dd MMM yyyy · HH:mm"):"Fecha no disponible";
    }
    bool BackupAtSelectedDestination(FullBackupStatus backup) {
      if(backup==null||!backup.HasCompletedRecord||String.IsNullOrWhiteSpace(backup.BackupFolder)||
         String.IsNullOrWhiteSpace(prefs.BackupDestination))return false;
      try {
        var selected=Path.GetFullPath(Path.Combine(prefs.BackupDestination,"Inhouse Photos backup")).TrimEnd('\\');
        var completed=Path.GetFullPath(backup.BackupFolder).TrimEnd('\\');
        return String.Equals(selected,completed,StringComparison.OrdinalIgnoreCase);
      } catch {return false;}
    }
    DiskInfo LibraryDisk() {
      var root=Path.GetPathRoot(Backend.Library(prefs));
      return Backend.Disks().FirstOrDefault(d=>String.Equals(d.Root,root,StringComparison.OrdinalIgnoreCase));
    }
    bool LowSpace(DiskInfo disk) {
      return disk!=null && disk.Free<Math.Max(50L*1024*1024*1024,disk.Total/10);
    }
    bool LocalOnlyEndpoint(string value) {
      Uri address;
      return Uri.TryCreate(value,UriKind.Absolute,out address)&&address.IsLoopback;
    }

    StackPanel StatusLine(string text,Brush color) {
      var row=new StackPanel{Orientation=Orientation.Horizontal,Margin=new Thickness(0,0,0,12)};
      row.Children.Add(new Ellipse{Width=9,Height=9,Fill=color,Margin=new Thickness(0,5,9,0)});
      row.Children.Add(new TextBlock{Text=text,FontSize=13,FontWeight=FontWeights.SemiBold,Foreground=color});
      return row;
    }
    Border SummaryCard(StackPanel inside,int side=0) {
      return new Border{Background=surface,CornerRadius=new CornerRadius(14),Padding=new Thickness(21,20,21,18),
        Margin=new Thickness(side==0?0:8,4,side==0?8:0,12),Child=inside};
    }
    ProgressBar SpaceBar(long total,long free) {
      return new ProgressBar{Minimum=0,Maximum=Math.Max(1,total),Value=Math.Max(0,Math.Min(total,total-free)),Height=8,
        Foreground=LowSpace(new DiskInfo{Total=total,Free=free})?accent:good,Background=divider,
        BorderThickness=new Thickness(0),Margin=new Thickness(0,12,0,9)};
    }
    StackPanel StepHeading(string number,string name) {
      var row=new StackPanel{Orientation=Orientation.Horizontal,Margin=new Thickness(0,4,0,12)};
      row.Children.Add(new Border{Width=27,Height=27,CornerRadius=new CornerRadius(14),Background=divider,
        Child=new TextBlock{Text=number,Foreground=accent,FontSize=14,FontWeight=FontWeights.SemiBold,
          HorizontalAlignment=HorizontalAlignment.Center,VerticalAlignment=VerticalAlignment.Center},Margin=new Thickness(0,0,12,0)});
      row.Children.Add(new TextBlock{Text=name,Foreground=Foreground,FontSize=20,FontWeight=FontWeights.SemiBold});
      return row;
    }

    Task RenderOverview() {
      Heading("Tu servidor","Fotos disponibles, espacio y protección en una sola vista.");
      var disk=default(DiskInfo);
      string diskIssue=null;
      try {disk=LibraryDisk();if(disk==null)diskIssue="No se encuentra el disco de tu biblioteca.";}
      catch(Exception ex){diskIssue=ex.Message;}
      var hero=Column();
      var healthLine=StatusLine("BIBLIOTECA",diskIssue==null&&lastLocal==true&&lastVerified!=false?good:accent);
      var healthDot=(Ellipse)healthLine.Children[0];hero.Children.Add(healthLine);
      var state=Label(diskIssue!=null?"No encuentro el disco de tus fotos":lastLocal==true?(lastVerified==false?"Hay que verificar la biblioteca":"Tus fotos están disponibles"):lastLocal==false?"El servidor está detenido":"Comprobando el servidor…",27);
      state.FontWeight=FontWeights.SemiBold;
      hero.Children.Add(state);
      hero.Children.Add(Fine(diskIssue??(disk==null?"": "Biblioteca en "+disk.Root+" · "+Backend.Size(disk.Free)+" libres")));
      var mainAction=PlaceAction(hero,"Comprobar servidor",async()=>{
        if(diskIssue!=null)await GoTo("Discos");
        else if(lastVerified==false){await Backend.ReverifyExisting(prefs,text=>Dispatcher.Invoke(()=>notice.Text=text));lastVerified=true;lastHealthCheck=DateTime.MinValue;await Render();}
        else if(lastLocal!=true){await Backend.StartManaged(prefs,text=>Dispatcher.Invoke(()=>notice.Text=text));lastLocal=true;lastHealthCheck=DateTime.MinValue;await Render();}
        else Open(Backend.CanonicalEndpoint(lastEndpoint==true?prefs.Endpoint:prefs.LocalEndpoint));
      },true);
      if(diskIssue!=null)mainAction.Content="Ver almacenamiento";
      else if(lastVerified==false)mainAction.Content="Volver a verificar";
      else if(lastLocal==true)mainAction.Content="Abrir mis fotos  ↗";
      else if(lastLocal==false)mainAction.Content="Iniciar servidor";
      content.Children.Add(Panel(hero));

      var backup=Backend.ReadFullBackupStatus(prefs);
      var backupAtSelectedDestination=BackupAtSelectedDestination(backup);
      var schedule=Backend.ReadBackupSchedule();
      DateTime completed;
      var backupOld=backup.FilesPresent&&DateTime.TryParse(backup.CompletedUtc,out completed)&&
        DateTime.UtcNow-completed.ToUniversalTime()>TimeSpan.FromDays(8);
      var metrics=new Grid();
      metrics.ColumnDefinitions.Add(new ColumnDefinition());metrics.ColumnDefinitions.Add(new ColumnDefinition());
      var spaceCard=Column();spaceCard.Children.Add(Fine("ESPACIO DE TUS FOTOS",accent));
      var free=Label(disk==null?"No disponible":Backend.Size(disk.Free)+" libres",23,disk!=null&&LowSpace(disk)?accent:Foreground);
      free.FontWeight=FontWeights.SemiBold;spaceCard.Children.Add(free);
      spaceCard.Children.Add(Fine(disk==null?"Conecta el disco de la biblioteca":disk.Root+" · "+Backend.Size(disk.Total)+" en total"));
      if(disk!=null)spaceCard.Children.Add(SpaceBar(disk.Total,disk.Free));
      PlaceAction(spaceCard,"Ver disco  →",()=>GoTo("Discos"));
      var backupCard=Column();backupCard.Children.Add(Fine("SEGUNDA COPIA",accent));
      var backupValue=String.IsNullOrWhiteSpace(prefs.BackupDestination)?"No configurada":
        backup.HasCompletedRecord&&!backupAtSelectedDestination?"Pendiente en esta unidad":
        backup.FilesPresent?(backupOld?"Conviene renovarla":"Copia disponible"):
        backup.HasCompletedRecord?"Disco no disponible":"Pendiente de crear";
      var backupState=Label(backupValue,23,backupAtSelectedDestination&&backup.FilesPresent&&!backupOld?good:Foreground);backupState.FontWeight=FontWeights.SemiBold;backupCard.Children.Add(backupState);
      backupCard.Children.Add(Fine(backup.HasCompletedRecord&&!backupAtSelectedDestination?
        backup.FilesPresent?"La copia anterior sigue en "+Path.GetDirectoryName(backup.BackupFolder):"La copia anterior no está disponible":
        backup.FilesPresent?"Última: "+DateLabel(backup.CompletedUtc):
        String.IsNullOrWhiteSpace(prefs.BackupDestination)?"Elige otra unidad, mejor en otro disco":"Todavía no hay una copia completa"));
      PlaceAction(backupCard,"Ver copias  →",()=>GoTo("Protección"));
      var spacePanel=SummaryCard(spaceCard);var backupPanel=SummaryCard(backupCard,1);
      Grid.SetColumn(spacePanel,0);Grid.SetColumn(backupPanel,1);metrics.Children.Add(spacePanel);metrics.Children.Add(backupPanel);
      content.Children.Add(metrics);

      var accessRow=new StackPanel{Orientation=Orientation.Horizontal,Margin=new Thickness(0,4,0,12)};
      accessRow.Children.Add(new TextBlock{Text="ACCESO DESDE EL MÓVIL",Foreground=muted,FontSize=12,FontWeight=FontWeights.SemiBold,Margin=new Thickness(0,0,14,0)});
      var localOnly=LocalOnlyEndpoint(prefs.Endpoint);
      var accessText=new TextBlock{Text=localOnly?"Solo en este PC":String.IsNullOrWhiteSpace(prefs.Endpoint)?"Sin configurar":lastEndpoint==true?"Responde desde este PC":lastEndpoint==false?"No responde desde este PC":"Comprobando…",
        Foreground=!localOnly&&lastEndpoint==true?good:accent,FontSize=14,TextWrapping=TextWrapping.Wrap};
      accessRow.Children.Add(accessText);content.Children.Add(accessRow);
      content.Children.Add(Fine(localOnly?"Esta dirección no funciona en un móvil. Configura acceso HTTPS para conectarlo.":
        String.IsNullOrWhiteSpace(prefs.Endpoint)?"Configura una dirección HTTPS para conectar el móvil.":"Comprueba el acceso externo en el móvil con datos móviles."));
      Action("Conectar un móvil  →",()=>GoTo("Conectar"));

      Rule();
      content.Children.Add(Label("Qué hacer ahora",21));
      if(String.IsNullOrWhiteSpace(prefs.BackupDestination)) {
        content.Children.Add(Fine("Prepara una copia en otra unidad; mejor si es otro disco físico."));
        Action("Preparar copia  →",()=>GoTo("Protección"),true);
      } else if(backup.HasCompletedRecord&&!backupAtSelectedDestination) {
        content.Children.Add(Fine("La unidad elegida aún no tiene una copia completa registrada. La anterior no se ha borrado."));
        Action("Crear copia en esta unidad  →",()=>GoTo("Protección"),true);
      } else if(!backup.FilesPresent) {
        content.Children.Add(Fine(backup.HasCompletedRecord?"Conecta el disco donde está la última copia.":"El destino está listo. Falta crear la primera copia completa."));
        Action("Revisar copias  →",()=>GoTo("Protección"),true);
      } else if(schedule.Enabled&&!String.IsNullOrWhiteSpace(schedule.LastError)) {
        content.Children.Add(Fine("La última copia automática no terminó. Revisa el motivo."));
        Action("Revisar copias  →",()=>GoTo("Protección"),true);
      } else if(backupOld) {
        content.Children.Add(Fine("La última copia completa tiene más de una semana."));
        Action("Crear una nueva copia  →",()=>GoTo("Protección"),true);
      } else if(LowSpace(disk)) {
        content.Children.Add(Fine("Queda poco espacio para nuevas fotos."));
        Action("Ver almacenamiento  →",()=>GoTo("Discos"),true);
      } else {
        content.Children.Add(Fine("La biblioteca tiene espacio y la última copia está disponible."));
        Action("Conectar otro dispositivo  →",()=>GoTo("Conectar"),true);
      }
      var generation=++overviewGeneration;
      RefreshOverviewHealth(generation,state,mainAction,accessText,healthDot,diskIssue==null);
      return Task.FromResult(0);
    }

    async void RefreshOverviewHealth(int generation,TextBlock state,Button action,TextBlock access,Ellipse healthDot,bool diskReady) {
      if(DateTime.UtcNow-lastHealthCheck<TimeSpan.FromSeconds(20)&&lastLocal.HasValue&&lastEndpoint.HasValue&&lastVerified.HasValue)return;
      try {
        var localTask=Backend.Ping(prefs.LocalEndpoint);
        var remoteTask=String.IsNullOrWhiteSpace(prefs.Endpoint)||LocalOnlyEndpoint(prefs.Endpoint)?Task.FromResult(false):Backend.Ping(prefs.Endpoint);
        var local=await localTask;var remote=await remoteTask;
        var verified=true;
        if(local)try {
          Backend.ValidateManagedConfiguration(prefs);
          var receipt=Backend.Json.Deserialize<AdoptionReceipt>(File.ReadAllText(prefs.ReceiptPath));
          Backend.AssertIdentity(receipt.Containers,await Backend.InspectServer(prefs));
        }catch {verified=false;}
        lastLocal=local;lastEndpoint=remote;lastVerified=verified;lastHealthCheck=DateTime.UtcNow;
        if(generation!=overviewGeneration||page!="Inicio")return;
        state.Text=!diskReady?"No encuentro el disco de tus fotos":local?(verified?"Tus fotos están disponibles":"Hay que verificar la biblioteca"):"El servidor está detenido";
        state.Foreground=diskReady&&local&&verified?good:accent;
        healthDot.Fill=diskReady&&local&&verified?good:accent;
        action.Content=!diskReady?"Ver almacenamiento":local?(verified?"Abrir mis fotos  ↗":"Volver a verificar"):"Iniciar servidor";
        access.Text=LocalOnlyEndpoint(prefs.Endpoint)?"Solo en este PC":String.IsNullOrWhiteSpace(prefs.Endpoint)?"Sin configurar":remote?"Responde desde este PC":"No responde desde este PC";
        access.Foreground=remote?good:accent;
      } catch {if(generation==overviewGeneration&&page=="Inicio"&&diskReady)state.Text="No se pudo comprobar el servidor";}
    }

    Task RenderBackupPage() {
      Heading("Copias de seguridad","Protege tus fotos en otra unidad, sin cambiar tu biblioteca actual.");
      var backup=Backend.ReadFullBackupStatus(prefs);
      var backupAtSelectedDestination=BackupAtSelectedDestination(backup);
      var summary=Column();summary.Children.Add(StatusLine("ÚLTIMA COPIA COMPLETA",backup.FilesPresent?good:accent));
      var state=backup.HasCompletedRecord&&!backupAtSelectedDestination?
        backup.FilesPresent?"Copia anterior disponible":"Copia anterior no disponible":
        backup.FilesPresent?"Copia disponible":backup.HasCompletedRecord?"Disco de copia no disponible":"Todavía no hay una copia completa";
      var stateText=Label(state,24,backup.FilesPresent?good:Foreground);stateText.FontWeight=FontWeights.SemiBold;summary.Children.Add(stateText);
      if(backup.HasCompletedRecord){
        summary.Children.Add(Fine("Terminó el "+DateLabel(backup.CompletedUtc)));
        summary.Children.Add(Fine(backup.BackupFolder));
        if(!backupAtSelectedDestination)summary.Children.Add(Fine("Todavía no hay una copia completa registrada en la unidad elegida ahora.",accent));
      } else summary.Children.Add(Fine("Las copias solo de la base de datos no incluyen tus fotos ni vídeos."));
      if(backup.FilesPresent)PlaceAction(summary,"Abrir carpeta de la copia  ↗",()=>{
        Process.Start(new ProcessStartInfo(backup.BackupFolder){UseShellExecute=true});return Task.FromResult(0);
      });
      content.Children.Add(Panel(summary));

      content.Children.Add(StepHeading("1","Unidad de la segunda copia"));
      var destination=String.IsNullOrWhiteSpace(prefs.BackupDestination);
      var target=Label(destination?"Sin destino elegido":prefs.BackupDestination,16,destination?accent:Foreground);
      target.FontWeight=FontWeights.SemiBold;content.Children.Add(target);
      content.Children.Add(Fine(destination?"Elige otra unidad. Mejor si es un disco físico distinto.":"El destino está guardado. Puedes cambiarlo sin mover la biblioteca."));
      Action(String.IsNullOrWhiteSpace(prefs.BackupDestination)?"Elegir destino":"Cambiar destino",async()=>{
        var path=PickFolder();if(path==null)return;
        Backend.ValidateBackup(Backend.Library(prefs),path);
        prefs.BackupDestination=path;Backend.Save(prefs);await Render();notice.Text="Destino guardado. Si es una unidad nueva, falta crear una copia completa allí. La copia anterior no se ha borrado.";
      },String.IsNullOrWhiteSpace(prefs.BackupDestination));

      Rule();content.Children.Add(StepHeading("2","Crea la primera copia"));
      if(!String.IsNullOrWhiteSpace(prefs.BackupDestination)) {
        content.Children.Add(Fine("Base de datos  →  Fotos y vídeos  →  Comprobación final"));
        content.Children.Add(Fine("No sobrescribe archivos existentes. Evita editar la biblioteca durante la copia."));
        var progress=Fine(backupProgressText??"Copia en curso…");progress.Visibility=backupCancellation==null?Visibility.Collapsed:Visibility.Visible;
        backupProgressView=progress;content.Children.Add(progress);
        var activity=new ProgressBar{IsIndeterminate=true,Height=6,Foreground=accent,Background=divider,
          BorderThickness=new Thickness(0),Margin=new Thickness(0,2,0,12),Visibility=backupCancellation==null?Visibility.Collapsed:Visibility.Visible};
        content.Children.Add(activity);
        var cancel=new Button{Content="Detener copia",Visibility=backupCancellation==null?Visibility.Collapsed:Visibility.Visible,HorizontalAlignment=HorizontalAlignment.Left};
        cancel.Click+=(s,e)=>{if(backupCancellation!=null){backupCancellation.Cancel();SetBackupProgress("Deteniendo la copia. Se conservarán los archivos ya copiados.");}};
        var create=Action("Crear copia completa",async()=>{
          if(!Confirm("Se copiarán fotos, vídeos y base de datos a otra unidad. La primera copia puede tardar bastante. No se borrarán archivos existentes. ¿Continuar?"))return;
          backupCancellation=new CancellationTokenSource();cancel.Visibility=Visibility.Visible;progress.Visibility=Visibility.Visible;activity.Visibility=Visibility.Visible;
          try {var result=await Backend.Backup(prefs,text=>Dispatcher.Invoke(()=>SetBackupProgress(text)),backupCancellation.Token);
            var scheduleUpdated=true;
            try{Backend.RecordManualBackupSuccessForSchedule();}catch{scheduleUpdated=false;}
            notice.Text="Copia terminada en "+result+". No se ha probado una restauración."+
              (scheduleUpdated?"":" Revisa la fecha de la próxima copia automática.");
          } finally {backupCancellation.Dispose();backupCancellation=null;backupProgressText=null;await Render();}
        },true);
        create.IsEnabled=backupCancellation==null;
        content.Children.Add(cancel);
      } else content.Children.Add(Fine("Este paso estará disponible al elegir el destino."));

      Rule();content.Children.Add(StepHeading("3","Mantenla al día"));
      var schedule=Backend.ReadBackupSchedule();
      content.Children.Add(StatusLine(schedule.Enabled?"COPIA SEMANAL ACTIVADA":"COPIA SEMANAL DESACTIVADA",schedule.Enabled?good:muted));
      content.Children.Add(Fine(schedule.Enabled?"Próxima comprobación: "+DateLabel(schedule.NextDueUtc)+". El PC y el gestor deben estar encendidos.":"Es opcional. Actívala cuando tengas un disco de copia conectado."));
      if(!String.IsNullOrWhiteSpace(schedule.LastError))content.Children.Add(Fine("Último problema: "+schedule.LastError,accent));
      var scheduleButton=Action(schedule.Enabled?"Desactivar copia semanal":"Activar copia semanal",async()=>{
        if(schedule.Enabled){Backend.SetBackupScheduleEnabled(false);await Render();notice.Text="Copia semanal desactivada. No se ha detenido el servidor.";return;}
        if(String.IsNullOrWhiteSpace(prefs.BackupDestination))throw new IOException("Elige primero otra unidad para la copia.");
        if(!await Startup.IsEnabled()){
          if(!Confirm("La copia semanal necesita que el gestor se inicie con Windows. ¿Activar también el inicio automático?"))return;
          await Startup.SetEnabled(prefs,true);
        }
        Backend.SetBackupScheduleEnabled(true);await Render();notice.Text="Copia semanal activada. Puedes hacer la primera copia ahora.";
      });
      scheduleButton.IsEnabled=schedule.Enabled||!String.IsNullOrWhiteSpace(prefs.BackupDestination);
      Rule();
      content.Children.Add(Fine("El gestor confirma que terminó la copia y que siguen presentes los archivos. No se ha probado una restauración completa."));
      return Task.FromResult(0);
    }

    Task RenderStoragePage() {
      Heading("Almacenamiento","Mira cuánto sitio queda antes de subir más fotos.");
      try {
        var library=Backend.Library(prefs);var disk=LibraryDisk();
        if(disk==null)throw new IOException("El disco de la biblioteca no está disponible.");
        var summary=Column();summary.Children.Add(StatusLine("BIBLIOTECA DE FOTOS",LowSpace(disk)?accent:good));
        var diskTitle=Label("Disco "+disk.Root.TrimEnd('\\'),26);diskTitle.FontWeight=FontWeights.SemiBold;summary.Children.Add(diskTitle);
        var free=Label(Backend.Size(disk.Free)+" libres",29,LowSpace(disk)?accent:good);free.FontWeight=FontWeights.SemiBold;summary.Children.Add(free);
        summary.Children.Add(SpaceBar(disk.Total,disk.Free));
        var used=Math.Max(0,disk.Total-disk.Free);
        summary.Children.Add(Fine(Backend.Size(used)+" usados  ·  "+Backend.Size(disk.Total)+" en total"));
        summary.Children.Add(Fine("Tus archivos: "+library));
        if(LowSpace(disk))summary.Children.Add(Fine("Queda poco espacio. Amplía el disco antes de seguir subiendo fotos.",accent));
        content.Children.Add(Panel(summary));
      }catch(Exception ex){content.Children.Add(Label(ex.Message,17,accent));}
      if(!String.IsNullOrWhiteSpace(prefs.BackupDestination)) {
        content.Children.Add(Label("Unidad de la segunda copia",20));
        try {var drive=new DriveInfo(Path.GetPathRoot(prefs.BackupDestination));
          content.Children.Add(StatusLine(drive.IsReady?Backend.Size(drive.AvailableFreeSpace)+" libres":"No está conectado",drive.IsReady?good:accent));
          content.Children.Add(Fine(prefs.BackupDestination));}
        catch {content.Children.Add(StatusLine("No está conectado",accent));content.Children.Add(Fine("Conecta el disco antes de hacer una copia."));}
      } else {
        content.Children.Add(Label("Unidad de la segunda copia",20));
        content.Children.Add(StatusLine("Sin configurar",accent));
        Action("Preparar una copia  →",()=>GoTo("Protección"));
      }
      Rule();
      var advanced=Column();advanced.Children.Add(Fine("Estos controles cambian la configuración de Windows. No trasladan la biblioteca."));
      PlaceAction(advanced,"Ver todos los discos",async()=>{advanced.Children.Add(Fine(await Task.Run(()=>Backend.PhysicalDisks())));});
      PlaceAction(advanced,"Configurar discos protegidos",()=>{
        Process.Start(new ProcessStartInfo(typeof(Program).Assembly.Location,"--storage"){
          UseShellExecute=true,Verb="runas",WindowStyle=ProcessWindowStyle.Normal});return Task.FromResult(0);
      });
      content.Children.Add(new Expander{Header="Opciones avanzadas de discos",Content=advanced,Foreground=muted,Margin=new Thickness(0,4,0,8)});
      content.Children.Add(Fine("Un espejo o RAID no sustituye una copia en otro disco."));
      return Task.FromResult(0);
    }

    async Task RenderConnectPage() {
      Heading("Conectar un móvil","Solo necesitas la dirección y tu cuenta habitual.");
      Action("←  Volver al resumen",()=>GoTo("Inicio"));
      var address=String.IsNullOrWhiteSpace(prefs.Endpoint)?null:Backend.CanonicalEndpoint(prefs.Endpoint);
      if(address==null||LocalOnlyEndpoint(address)) {
        var localBox=Column();localBox.Children.Add(StatusLine(address==null?"FALTA CONFIGURAR EL ACCESO":"ACCESO SOLO EN ESTE PC",accent));
        localBox.Children.Add(Label("Aún no hay dirección para el móvil",23));
        localBox.Children.Add(Fine(address==null?"Guarda primero una dirección accesible desde el móvil.":"La dirección local apunta al propio dispositivo. Pegarla en el móvil no conectaría con este servidor."));
        content.Children.Add(Panel(localBox));
        content.Children.Add(Fine("Para entrar desde el móvil, prepara un dominio HTTPS que apunte a este PC y configura el router. Después guarda esa dirección en Ajustes."));
        Action("Abrir Ajustes  →",()=>GoTo("Configuración"),true);
        return;
      }
      var box=Column();box.Children.Add(StatusLine("DIRECCIÓN DE TU BIBLIOTECA",address==null?accent:good));
      var addressBox=new TextBox{Text=address??"Aún no hay una dirección configurada",IsReadOnly=true,TextWrapping=TextWrapping.Wrap,
        FontSize=21,FontWeight=FontWeights.SemiBold,Foreground=Foreground,Background=Brushes.Transparent,
        BorderThickness=new Thickness(0),Padding=new Thickness(0),Margin=new Thickness(0,0,0,12)};
      box.Children.Add(addressBox);
      if(address!=null)PlaceAction(box,"Copiar dirección",()=>{Clipboard.SetText(address);notice.Text="Dirección copiada. Pégala en la pantalla de inicio de Inhouse Photos.";return Task.FromResult(0);},true);
      content.Children.Add(Panel(box));
      content.Children.Add(StepHeading("1","Instala Inhouse Photos"));
      content.Children.Add(Fine("Descarga la aplicación en tu móvil."));
      Action("Abrir página de descargas  ↗",()=>{Open("https://fotos.miguelcoxcaballero.com/descargas/");return Task.FromResult(0);});
      content.Children.Add(StepHeading("2","Pega la dirección"));
      content.Children.Add(Fine("En la primera pantalla de la app, pega la dirección de arriba."));
      content.Children.Add(StepHeading("3","Inicia sesión"));
      content.Children.Add(Fine("Usa la cuenta que ya tienes en esta biblioteca."));
      if(address!=null) {
        var checkedFromHere=await Backend.Ping(address);
        Rule();content.Children.Add(StatusLine(checkedFromHere?"RESPONDE DESDE ESTE PC":"NO RESPONDE DESDE ESTE PC",checkedFromHere?good:accent));
        content.Children.Add(Fine(checkedFromHere?"Para comprobar el acceso fuera de casa, abre la app con datos móviles.":"Comprueba la dirección en Ajustes."));
      }
    }

    async Task RenderSettingsPage() {
      Heading("Ajustes","Acceso desde el móvil y arranque automático. Lo técnico queda aparte.");
      var mobile=Column();
      mobile.Children.Add(StatusLine("DIRECCIÓN PARA EL MÓVIL",accent));
      mobile.Children.Add(Fine("Guarda la dirección HTTPS de tu biblioteca. Esta comprobación se hace desde este PC; prueba el acceso exterior con datos móviles."));
      var endpoint=new TextBox{Text=LocalOnlyEndpoint(prefs.Endpoint)?"":prefs.Endpoint??"",Padding=new Thickness(12),FontSize=16,Background=surface,
        Foreground=Foreground,BorderThickness=new Thickness(1),BorderBrush=divider,Margin=new Thickness(0,4,0,10)};
      mobile.Children.Add(endpoint);
      PlaceAction(mobile,"Comprobar y guardar dirección",async()=>{
        var url=Backend.CanonicalEndpoint(endpoint.Text);
        if(LocalOnlyEndpoint(url))throw new IOException("Esta dirección solo funciona en este PC. Usa tu dominio HTTPS para el móvil.");
        if(!await Backend.Ping(url))throw new IOException("La dirección no responde desde este PC. No se ha guardado.");
        prefs.Endpoint=url;Backend.Save(prefs);lastHealthCheck=DateTime.MinValue;
        notice.Text="Dirección guardada. Pruébala también desde el móvil con datos móviles.";
      },true);
      content.Children.Add(Panel(mobile));
      await RenderManagement();
      var advanced=Column();
      advanced.Children.Add(Label("Carpeta del servidor",18));
      advanced.Children.Add(Fine(prefs.Installation??"Sin configurar"));
      PlaceAction(advanced,"Cambiar carpeta",async()=>{
        var path=PickFolder();if(path==null)return;
        if(!File.Exists(Path.Combine(path,"docker-compose.yml"))||!File.Exists(Path.Combine(path,".env")))
          throw new InvalidOperationException("La carpeta no contiene un servidor compatible.");
        if(String.Equals(path,prefs.Installation,StringComparison.OrdinalIgnoreCase))return;
        var backupScheduled=Backend.ReadBackupSchedule().Enabled;
        if(!Confirm("¿Cambiar el servidor gestionado? Se desactivará su arranque automático hasta verificar la nueva biblioteca."+
          (backupScheduled?" También se desactivará la copia semanal.":"")+" No se moverán fotos."))return;
        await Startup.SetEnabled(prefs,false);Backend.SetBackupScheduleEnabled(false);
        prefs.Installation=path;prefs.Managed=false;prefs.ReceiptPath=null;prefs.ProjectName=null;
        Backend.Save(prefs);page="Inicio";await Render();
      });
      advanced.Children.Add(Label("Diagnóstico",18));
      PlaceAction(advanced,"Abrir registro de errores",()=>{
        var path=Path.Combine(Backend.SettingsDir,"diagnostics");Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo(path){UseShellExecute=true});return Task.FromResult(0);
      });
      var serviceReport=Fine("El estado detallado de los servicios se consulta solo cuando lo solicitas.");
      PlaceAction(advanced,"Comprobar servicios",async()=>{
        var data=await Backend.Compose(prefs,"ps --format json",15);
        var names=new Dictionary<string,string>{{"immich-server","Galería"},{"immich-machine-learning","Análisis"},{"database","Base de datos"},{"redis","Tareas"},{"caddy","Conexión segura"}};
        var lines=data.Split(new[]{'\r','\n'},StringSplitOptions.RemoveEmptyEntries).Select(line=>{
          var row=Backend.Json.Deserialize<Dictionary<string,object>>(line);
          var key=Convert.ToString(row.ContainsKey("Service")?row["Service"]:"");
          var state=Convert.ToString(row.ContainsKey("State")?row["State"]:"");
          return (names.ContainsKey(key)?names[key]:key)+" · "+(state=="running"?"Activo":state);
        });
        serviceReport.Text=String.Join("\n",lines);
      });
      advanced.Children.Add(serviceReport);
      PlaceAction(advanced,"Guardar solo base de datos",async()=>{
        notice.Text="Instantánea de metadatos guardada: "+await Backend.Snapshot(prefs);
      });
      advanced.Children.Add(Fine("Una instantánea de base de datos no contiene fotos ni vídeos."));
      content.Children.Add(new Expander{Header="Opciones técnicas",Content=advanced,Foreground=muted,Margin=new Thickness(0,20,0,10)});
    }
  }
}
