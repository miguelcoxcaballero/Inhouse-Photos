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
    DiskInfo LibraryDisk() {
      var root=Path.GetPathRoot(Backend.Library(prefs));
      return Backend.Disks().FirstOrDefault(d=>String.Equals(d.Root,root,StringComparison.OrdinalIgnoreCase));
    }
    bool LowSpace(DiskInfo disk) {
      return disk!=null && disk.Free<Math.Max(50L*1024*1024*1024,disk.Total/10);
    }

    Task RenderOverview() {
      Heading("Resumen","Tus fotos, el espacio y la segunda copia. Lo importante está aquí.");
      var disk=default(DiskInfo);
      string diskIssue=null;
      try {disk=LibraryDisk();if(disk==null)diskIssue="No se encuentra el disco de tu biblioteca.";}
      catch(Exception ex){diskIssue=ex.Message;}
      var hero=Column();
      hero.Children.Add(Fine("ESTADO DEL SERVIDOR",accent));
      var state=Label(diskIssue!=null?"No encuentro el disco de tus fotos":lastLocal==true?(lastVerified==false?"Tu biblioteca necesita una comprobación":"Tu biblioteca está disponible"):lastLocal==false?"Tu biblioteca necesita arrancar":"Comprobando tu biblioteca…",26);
      hero.Children.Add(state);
      hero.Children.Add(Fine("La aplicación y tus archivos permanecen en este ordenador."));
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
      var schedule=Backend.ReadBackupSchedule();
      DateTime completed;
      var backupOld=backup.FilesPresent&&DateTime.TryParse(backup.CompletedUtc,out completed)&&
        DateTime.UtcNow-completed.ToUniversalTime()>TimeSpan.FromDays(8);
      var metrics=new Grid{Margin=new Thickness(0,8,0,6)};
      metrics.ColumnDefinitions.Add(new ColumnDefinition());metrics.ColumnDefinitions.Add(new ColumnDefinition());metrics.ColumnDefinitions.Add(new ColumnDefinition());
      var backupValue=String.IsNullOrWhiteSpace(prefs.BackupDestination)?"Sin configurar":backup.FilesPresent?"Última copia disponible":backup.HasCompletedRecord?"Disco no disponible":"Sin copia registrada";
      var backupDetail=backup.FilesPresent?DateLabel(backup.CompletedUtc):String.IsNullOrWhiteSpace(prefs.BackupDestination)?"Elige otra unidad":"No hay una copia completa confirmada";
      var accessValue=lastEndpoint==true?"La dirección responde":lastEndpoint==false?"No responde":"Comprobando…";
      var accessDetail=String.IsNullOrWhiteSpace(prefs.Endpoint)?"Añade una dirección en Ajustes":"Comprobado desde este PC";
      var accessText=Metric(metrics,0,"DIRECCIÓN",accessValue,accessDetail);
      Metric(metrics,1,"ESPACIO",disk==null?"No disponible":Backend.Size(disk.Free)+" libres",disk==null?diskIssue:disk.Root+" · "+Backend.Size(disk.Total)+" en total");
      Metric(metrics,2,"SEGUNDA COPIA",backupValue,backupDetail);
      content.Children.Add(metrics);

      Rule();
      content.Children.Add(Label("Lo siguiente",22));
      if(String.IsNullOrWhiteSpace(prefs.BackupDestination)) {
        content.Children.Add(Fine("Aún no hay una segunda copia de tus fotos. Para mayor protección, elige una unidad en otro disco físico."));
        Action("Preparar una copia  →",()=>GoTo("Protección"),true);
      } else if(!backup.FilesPresent) {
        content.Children.Add(Fine(backup.HasCompletedRecord?"La última copia no está disponible en este momento. Revisa el disco de destino.":"El destino está preparado, pero todavía no se ha completado una copia de fotos y base de datos."));
        Action("Revisar copias  →",()=>GoTo("Protección"),true);
      } else if(schedule.Enabled&&!String.IsNullOrWhiteSpace(schedule.LastError)) {
        content.Children.Add(Fine("La última copia automática no terminó: "+schedule.LastError));
        Action("Revisar copias  →",()=>GoTo("Protección"),true);
      } else if(backupOld) {
        content.Children.Add(Fine("La última copia completa tiene más de una semana. Conviene crear otra antes de añadir más fotos."));
        Action("Crear una nueva copia  →",()=>GoTo("Protección"),true);
      } else if(LowSpace(disk)) {
        content.Children.Add(Fine("El disco de tu biblioteca empieza a quedarse sin espacio. Revisa qué unidad usa antes de añadir más fotos."));
        Action("Ver almacenamiento  →",()=>GoTo("Discos"),true);
      } else {
        content.Children.Add(Fine("Tu biblioteca tiene espacio y el disco de la última copia está disponible. Las copias no sustituyen una prueba de restauración."));
        Action("Conectar otro dispositivo  →",()=>GoTo("Conectar"));
      }
      Action("Conectar un móvil",()=>GoTo("Conectar"));
      var generation=++overviewGeneration;
      RefreshOverviewHealth(generation,state,mainAction,accessText,diskIssue==null);
      return Task.FromResult(0);
    }

    TextBlock Metric(Grid grid,int index,string title,string value,string detail) {
      var column=Column();column.Margin=new Thickness(index==0?0:12,0,index==2?0:12,0);
      column.Children.Add(Fine(title,accent));
      var valueText=Label(value,19);valueText.FontWeight=FontWeights.SemiBold;column.Children.Add(valueText);
      column.Children.Add(Fine(detail));
      Grid.SetColumn(column,index);grid.Children.Add(column);
      return valueText;
    }

    async void RefreshOverviewHealth(int generation,TextBlock state,Button action,TextBlock access,bool diskReady) {
      if(DateTime.UtcNow-lastHealthCheck<TimeSpan.FromSeconds(20)&&lastLocal.HasValue&&lastEndpoint.HasValue&&lastVerified.HasValue)return;
      try {
        var localTask=Backend.Ping(prefs.LocalEndpoint);
        var remoteTask=String.IsNullOrWhiteSpace(prefs.Endpoint)?Task.FromResult(false):Backend.Ping(prefs.Endpoint);
        var local=await localTask;var remote=await remoteTask;
        var verified=true;
        if(local)try {
          Backend.ValidateManagedConfiguration(prefs);
          var receipt=Backend.Json.Deserialize<AdoptionReceipt>(File.ReadAllText(prefs.ReceiptPath));
          Backend.AssertIdentity(receipt.Containers,await Backend.InspectServer(prefs));
        }catch {verified=false;}
        lastLocal=local;lastEndpoint=remote;lastVerified=verified;lastHealthCheck=DateTime.UtcNow;
        if(generation!=overviewGeneration||page!="Inicio")return;
        state.Text=!diskReady?"No encuentro el disco de tus fotos":local?(verified?"Tu biblioteca está disponible":"Tu biblioteca necesita una comprobación"):"Tu biblioteca necesita arrancar";
        state.Foreground=diskReady&&local&&verified?good:accent;
        action.Content=!diskReady?"Ver almacenamiento":local?(verified?"Abrir mis fotos  ↗":"Volver a verificar"):"Iniciar servidor";
        access.Text=String.IsNullOrWhiteSpace(prefs.Endpoint)?"Sin configurar":remote?"La dirección responde":"No responde";
        access.Foreground=remote?good:accent;
      } catch {if(generation==overviewGeneration&&page=="Inicio"&&diskReady)state.Text="No se pudo comprobar el servidor";}
    }

    Task RenderBackupPage() {
      Heading("Tus copias","Protege fotos, vídeos, álbumes y cuentas en otra unidad.");
      var backup=Backend.ReadFullBackupStatus(prefs);
      var summary=Column();summary.Children.Add(Fine("ÚLTIMA COPIA COMPLETA",accent));
      var state=backup.FilesPresent?"Terminada · disco disponible":backup.HasCompletedRecord?"El disco de la última copia no está disponible":"No hay copia registrada en este gestor";
      summary.Children.Add(Label(state,23,backup.FilesPresent?good:Foreground));
      if(backup.HasCompletedRecord)summary.Children.Add(Fine(DateLabel(backup.CompletedUtc)+" · "+backup.BackupFolder));
      else summary.Children.Add(Fine("La comprobación inicial y las copias de solo álbumes y cuentas no protegen tus fotos."));
      if(backup.FilesPresent)PlaceAction(summary,"Abrir carpeta de la copia  ↗",()=>{
        Process.Start(new ProcessStartInfo(backup.BackupFolder){UseShellExecute=true});return Task.FromResult(0);
      });
      content.Children.Add(Panel(summary));
      content.Children.Add(Label("Destino",20));
      content.Children.Add(Fine(String.IsNullOrWhiteSpace(prefs.BackupDestination)?"Elige una carpeta en otra unidad. Mejor si está en un disco físico distinto.":prefs.BackupDestination));
      Action(String.IsNullOrWhiteSpace(prefs.BackupDestination)?"Elegir destino":"Cambiar destino",async()=>{
        var path=PickFolder();if(path==null)return;
        Backend.ValidateBackup(Backend.Library(prefs),path);
        prefs.BackupDestination=path;Backend.Save(prefs);await Render();notice.Text="Destino guardado. Todavía no se ha hecho una copia.";
      },String.IsNullOrWhiteSpace(prefs.BackupDestination));
      if(!String.IsNullOrWhiteSpace(prefs.BackupDestination)) {
        Rule();content.Children.Add(Label("Hacer una copia ahora",20));
        content.Children.Add(Fine("Primero se guardan álbumes y cuentas; después se copian las fotos y vídeos. Los archivos existentes no se sobrescriben. Evita editar la biblioteca mientras se copia."));
        var progress=Fine(backupProgressText??"Copia en curso…");progress.Visibility=backupCancellation==null?Visibility.Collapsed:Visibility.Visible;
        backupProgressView=progress;content.Children.Add(progress);
        var cancel=new Button{Content="Detener copia",Visibility=backupCancellation==null?Visibility.Collapsed:Visibility.Visible,HorizontalAlignment=HorizontalAlignment.Left};
        cancel.Click+=(s,e)=>{if(backupCancellation!=null){backupCancellation.Cancel();SetBackupProgress("Deteniendo la copia. Se conservarán los archivos ya copiados.");}};
        var create=Action("Crear copia completa",async()=>{
          if(!Confirm("Se copiarán fotos, vídeos y base de datos a otra unidad. La primera copia puede tardar bastante. No se borrarán archivos existentes. ¿Continuar?"))return;
          backupCancellation=new CancellationTokenSource();cancel.Visibility=Visibility.Visible;progress.Visibility=Visibility.Visible;
          try {var result=await Backend.Backup(prefs,text=>Dispatcher.Invoke(()=>SetBackupProgress(text)),backupCancellation.Token);
            var scheduleUpdated=true;
            try{Backend.RecordManualBackupSuccessForSchedule();}catch{scheduleUpdated=false;}
            notice.Text="Copia terminada en "+result+". No se ha probado una restauración."+
              (scheduleUpdated?"":" Revisa la fecha de la próxima copia automática.");
          } finally {backupCancellation.Dispose();backupCancellation=null;backupProgressText=null;await Render();}
        },true);
        create.IsEnabled=backupCancellation==null;
        content.Children.Add(cancel);
      }
      Rule();
      var schedule=Backend.ReadBackupSchedule();
      content.Children.Add(Label("Copia automática semanal",20));
      content.Children.Add(Fine(schedule.Enabled?"Activada. Próxima comprobación: "+DateLabel(schedule.NextDueUtc)+". Funciona mientras este PC y el gestor están encendidos.":"Desactivada. Puedes activarla después de elegir otra unidad."));
      if(!String.IsNullOrWhiteSpace(schedule.LastError))content.Children.Add(Fine(schedule.LastError,accent));
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
      content.Children.Add(Fine("Una copia terminada confirma que el flujo finalizó y que los archivos siguen presentes. No certifica una restauración completa ni sustituye otra copia fuera de casa."));
      return Task.FromResult(0);
    }

    Task RenderStoragePage() {
      Heading("Almacenamiento","Primero el disco que guarda tus fotos. Lo demás, solo si lo necesitas.");
      try {
        var library=Backend.Library(prefs);var disk=LibraryDisk();
        if(disk==null)throw new IOException("El disco de la biblioteca no está disponible.");
        var summary=Column();summary.Children.Add(Fine("BIBLIOTECA ACTUAL",accent));
        summary.Children.Add(Label("Disco "+disk.Root.TrimEnd('\\'),25));
        summary.Children.Add(Fine(library));
        summary.Children.Add(Label(Backend.Size(disk.Free)+" libres de "+Backend.Size(disk.Total),18,LowSpace(disk)?accent:good));
        summary.Children.Add(new ProgressBar{Minimum=0,Maximum=disk.Total,Value=disk.Total-disk.Free,Height=6,Foreground=accent,
          Background=divider,BorderThickness=new Thickness(0),Margin=new Thickness(0,10,0,8)});
        if(LowSpace(disk))summary.Children.Add(Fine("Conviene ampliar el espacio antes de seguir subiendo fotos.",accent));
        content.Children.Add(Panel(summary));
      }catch(Exception ex){content.Children.Add(Label(ex.Message,17,accent));}
      if(!String.IsNullOrWhiteSpace(prefs.BackupDestination)) {
        Rule();content.Children.Add(Label("Unidad de la segunda copia",20));
        try {var drive=new DriveInfo(Path.GetPathRoot(prefs.BackupDestination));
          content.Children.Add(Fine(drive.IsReady?prefs.BackupDestination+" · "+Backend.Size(drive.AvailableFreeSpace)+" libres":"No disponible ahora"));}
        catch {content.Children.Add(Fine("No disponible ahora. Conecta el disco antes de hacer una copia."));}
      }
      Rule();
      var advanced=Column();advanced.Children.Add(Fine("Estos controles modifican la configuración de Windows, no trasladan automáticamente la biblioteca."));
      PlaceAction(advanced,"Ver todos los discos",async()=>{advanced.Children.Add(Fine(await Task.Run(()=>Backend.PhysicalDisks())));});
      PlaceAction(advanced,"Configurar discos protegidos",()=>{
        Process.Start(new ProcessStartInfo(typeof(Program).Assembly.Location,"--storage"){
          UseShellExecute=true,Verb="runas",WindowStyle=ProcessWindowStyle.Normal});return Task.FromResult(0);
      });
      content.Children.Add(new Expander{Header="Opciones de discos avanzadas",Content=advanced,Foreground=muted,Margin=new Thickness(0,4,0,8)});
      content.Children.Add(Fine("Un espejo o RAID no sustituye una copia en otro disco físico. Crear un grupo no mueve las fotos existentes."));
      return Task.FromResult(0);
    }

    async Task RenderConnectPage() {
      Heading("Conectar un dispositivo","Usa la misma cuenta que ya tienes en tu biblioteca.");
      Action("←  Volver al resumen",()=>GoTo("Inicio"));
      var address=String.IsNullOrWhiteSpace(prefs.Endpoint)?null:Backend.CanonicalEndpoint(prefs.Endpoint);
      var box=Column();box.Children.Add(Fine("DIRECCIÓN DE TU BIBLIOTECA",accent));
      box.Children.Add(Label(address??"Aún no hay una dirección configurada",22));
      if(address!=null)PlaceAction(box,"Copiar dirección",()=>{Clipboard.SetText(address);notice.Text="Dirección copiada. Pégala en la pantalla de inicio de Inhouse Photos.";return Task.FromResult(0);},true);
      content.Children.Add(Panel(box));
      content.Children.Add(Fine("1  Instala Inhouse Photos en el móvil.\n2  Pega esta dirección.\n3  Inicia sesión con tu cuenta habitual."));
      Action("Abrir página de descargas  ↗",()=>{Open("https://fotos.miguelcoxcaballero.com/descargas/");return Task.FromResult(0);});
      if(address!=null) {
        var checkedFromHere=await Backend.Ping(address);
        content.Children.Add(Fine(checkedFromHere?"Esta dirección responde desde este ordenador. Para confirmar el acceso desde fuera, pruébala en el móvil usando datos móviles.":"Esta dirección no respondió desde este ordenador. Comprueba el dominio en Ajustes.",checkedFromHere?muted:accent));
      }
    }

    async Task RenderSettingsPage() {
      Heading("Ajustes","Mantén el servidor accesible y cambia solo lo que necesitas.");
      await RenderManagement();
      var advanced=Column();
      advanced.Children.Add(Label("Carpeta del servidor",18));
      advanced.Children.Add(Fine(prefs.Installation??"Sin configurar"));
      PlaceAction(advanced,"Cambiar carpeta",async()=>{
        var path=PickFolder();if(path==null)return;
        if(!File.Exists(Path.Combine(path,"docker-compose.yml"))||!File.Exists(Path.Combine(path,".env")))
          throw new InvalidOperationException("La carpeta no contiene un servidor compatible.");
        if(String.Equals(path,prefs.Installation,StringComparison.OrdinalIgnoreCase))return;
        if(!Confirm("¿Cambiar el servidor gestionado? Se desactivará su arranque automático hasta verificar la nueva biblioteca. No se moverán fotos."))return;
        await Startup.SetEnabled(prefs,false);Backend.SetBackupScheduleEnabled(false);
        prefs.Installation=path;prefs.Managed=false;prefs.ReceiptPath=null;prefs.ProjectName=null;
        Backend.Save(prefs);page="Inicio";await Render();
      });
      advanced.Children.Add(Label("Dirección de la biblioteca",18));
      var endpoint=new TextBox{Text=prefs.Endpoint??"",Padding=new Thickness(12),FontSize=16,Background=surface,
        Foreground=Foreground,BorderThickness=new Thickness(1),BorderBrush=divider,Margin=new Thickness(0,4,0,10)};
      advanced.Children.Add(endpoint);
      PlaceAction(advanced,"Comprobar y guardar dirección",async()=>{
        var url=Backend.CanonicalEndpoint(endpoint.Text);
        if(!await Backend.Ping(url))throw new IOException("La dirección no responde desde este PC. No se ha guardado.");
        prefs.Endpoint=url;Backend.Save(prefs);lastHealthCheck=DateTime.MinValue;
        notice.Text="Dirección guardada. Pruébala también desde el móvil con datos móviles.";
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
