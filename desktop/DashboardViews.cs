using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Diagnostics;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace InhousePhotos {
  public sealed partial class ServerWindow {
    readonly Brush good=Ui.Good;
    readonly Brush surface=Ui.Surface;
    readonly Brush divider=Ui.Hairline;
    bool? lastLocal, lastEndpoint, lastVerified;
    DateTime lastHealthCheck=DateTime.MinValue;
    int overviewGeneration;
    int connectGeneration;
    string backupProgressText;
    TextBlock backupProgressView;
    Action<string> backupProgressStage;

    void SetBackupProgress(string text) {
      backupProgressText=text;
      // The Copias page shows progress in its own hero; elsewhere it uses the notice.
      notice.Text=page=="Protección"&&backupProgressView!=null?"":text;
      if(page=="Protección"&&backupProgressView!=null)backupProgressView.Text=text;
      if(page=="Protección"&&backupProgressStage!=null)backupProgressStage(text);
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
      return new Border {Background=Brushes.Transparent,BorderThickness=new Thickness(0),Padding=new Thickness(0),
        Margin=new Thickness(0,0,0,8),Child=inside};
    }
    StackPanel Column() {return new StackPanel{Orientation=Orientation.Vertical};}
    static bool Horizontal(Panel host){var stack=host as StackPanel;return stack!=null&&stack.Orientation==Orientation.Horizontal;}
    Button PlaceAction(Panel host,string caption,Func<Task> task,bool primary=false,string icon=null) {
      var button=Action(caption,task,primary,icon);
      content.Children.Remove(button);
      button.Margin=Horizontal(host)?new Thickness(0,0,8,0):new Thickness(0,16,8,0);
      host.Children.Add(button);
      return button;
    }
    Button PlaceLink(Panel host,string caption,Func<Task> task,string icon=null) {
      var button=PlaceAction(host,caption,task,false,icon);
      Ui.SetStyle(button,"Link");
      button.Margin=Horizontal(host)?new Thickness(0,0,16,0):new Thickness(0,8,0,0);
      return button;
    }
    TextBlock Fine(string text,Brush color=null) {var block=Ui.Text(text,Ui.BodySize,color??muted);block.Margin=new Thickness(0,0,0,8);return block;}
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

    // Small status pill: a dot and a short label on a tint of the same tone.
    Border Pill(string text,Tone tone) {
      var ink=tone==Tone.Good?Ui.Good:tone==Tone.Attention?Ui.Accent:tone==Tone.Critical?Ui.Critical:(Brush)Ui.Ink2;
      var tint=tone==Tone.Good?Ui.GoodTint:tone==Tone.Attention?Ui.AccentTint:tone==Tone.Critical?Ui.CriticalTint:(Brush)Ui.NeutralTint;
      var row=new StackPanel{Orientation=Orientation.Horizontal};
      row.Children.Add(new System.Windows.Shapes.Ellipse{Width=6,Height=6,Fill=ink,VerticalAlignment=VerticalAlignment.Center,Margin=new Thickness(0,0,6,0)});
      var label=Ui.Text(text,Ui.CaptionSize,ink,true);label.TextWrapping=TextWrapping.NoWrap;row.Children.Add(label);
      return new Border{Background=tint,CornerRadius=new CornerRadius(10),Padding=new Thickness(8,2,10,2),Child=row,
        HorizontalAlignment=HorizontalAlignment.Left,Margin=new Thickness(0,0,0,10)};
    }
    void Divide(){content.Children.Add(Ui.Divider(new Thickness(0)));}

    // Wire a non-standard button (a whole list row) through the same guard as Action.
    void Wire(Button button,Func<Task> task) {
      button.Click+=async(s,e)=>{if(busy||SystemUpdates.BlocksOperations(prefs)||RuntimeUpdates.BlocksOperations(prefs)){notice.Text="Espera a que termine o se recupere la actualización actual.";return;}busy=true;button.IsEnabled=false;notice.Text="Trabajando…";try{await task();if(notice.Text=="Trabajando…")notice.Text="";}catch(Exception ex){notice.Text=ex.Message;}finally{busy=false;button.IsEnabled=true;}};
    }
    // Overview row that opens another page: whole row is one focusable target.
    Ui.Row NavigationRow(string icon,string title,string detail,string value,Brush valueColor,string target) {
      var row=Ui.ListRow(icon,title,detail);
      var valueText=Ui.Text(value,Ui.BodySize,valueColor??Ui.Ink,true);valueText.TextWrapping=TextWrapping.NoWrap;valueText.VerticalAlignment=VerticalAlignment.Center;
      row.Trailing.Children.Add(valueText);
      var chevron=Ui.Icon("chevron",16,Ui.Ink3);chevron.Margin=new Thickness(12,0,0,0);chevron.VerticalAlignment=VerticalAlignment.Center;row.Trailing.Children.Add(chevron);
      var button=new Button{Style=Ui.StyleOf("Row"),Content=row.Root};
      AutomationProperties.SetName(button,title+": "+value);AutomationProperties.SetHelpText(button,detail??"");
      Wire(button,()=>GoTo(target));
      content.Children.Add(button);
      return row;
    }

    // USB device detection and USB network readiness are different facts. Keep
    // both visible, and update this section rather than rebuilding the page.
    // In particular, a charging/MTP phone must never be labelled ready to upload.
    void RenderUsbConnection(bool compact=false) {
      if(!compact)Section("Transferencia por cable","Sube fotos más rápido con el móvil conectado por USB.");
      var parts=Ui.ListRow("usb","Detectando el móvil…","Conecta un móvil con un cable de datos. Se detectará automáticamente.");
      var section=parts.Root;var body=parts.Body;var title=parts.Heading;var detail=parts.Detail;var cableIcon=parts.Icon;
      var next=Fine("");next.Margin=new Thickness(0,4,0,0);next.Visibility=Visibility.Collapsed;body.Children.Add(next);
      var network=Fine("");network.Margin=new Thickness(0,4,0,0);network.Visibility=Visibility.Collapsed;body.Children.Add(network);
      var activity=Fine("");activity.Margin=new Thickness(0,6,0,0);activity.Visibility=Visibility.Collapsed;body.Children.Add(activity);
      var prepare=Ui.Button("Preparar red USB");prepare.Visibility=Visibility.Collapsed;prepare.Margin=new Thickness(0,0,12,0);
      AutomationProperties.SetName(prepare,"Preparar la red del móvil detectado por USB");parts.Trailing.Children.Add(prepare);
      var check=Ui.Button("Volver a detectar","Link");parts.Trailing.Children.Add(check);
      content.Children.Add(section);
      var monitor=UsbDeviceMonitor.Current;string lastSignature=null;bool preparing=false;
      void Update() {
        if(!content.Children.Contains(section))return;
        var status=monitor.Snapshot;
        var signature=status.State+"|"+status.Title+"|"+status.Message+"|"+status.Action+"|"+status.DeviceName+"|"+status.LinkMbps+"|"+status.CanPrepare;
        title.Text=status.Title;detail.Text=status.Message;detail.Visibility=String.IsNullOrWhiteSpace(detail.Text)?Visibility.Collapsed:Visibility.Visible;
        title.Foreground=status.State=="ready"?good:Ui.Ink;
        Ui.IconPath(cableIcon).Stroke=status.State=="ready"?good:status.Connected?Ui.Ink:Ui.Ink3;
        next.Text=status.Action=="Volver a comprobar"||status.Action=="Preparar conexión USB"?"":status.Action??"";
        next.Visibility=String.IsNullOrWhiteSpace(next.Text)?Visibility.Collapsed:Visibility.Visible;
        network.Text=status.State=="ready"?"Red por cable disponible"+(status.LinkMbps>0?" · enlace de "+status.LinkMbps+" Mbps":"")+". La velocidad real de subida aparece en el móvil.":"";
        network.Visibility=String.IsNullOrWhiteSpace(network.Text)?Visibility.Collapsed:Visibility.Visible;
        prepare.Visibility=status.CanPrepare&&status.NeedsPreparation?Visibility.Visible:Visibility.Collapsed;
        prepare.IsEnabled=status.CanPrepare&&status.NeedsPreparation&&!preparing;
        // No-device is already watched automatically. Reserve a manual retry
        // for a connected phone or a failed detection, not a required step.
        check.Visibility=!compact||status.Connected||status.State=="detection_unavailable"?Visibility.Visible:Visibility.Collapsed;
        check.IsEnabled=!preparing&&status.State!="checking";
        if(lastSignature!=null&&lastSignature!=signature&&!DisableTransitions&&SystemParameters.ClientAreaAnimation)
          body.BeginAnimation(UIElement.OpacityProperty,new DoubleAnimation(0.65,1,new Duration(TimeSpan.FromMilliseconds(140))){FillBehavior=FillBehavior.Stop});
        lastSignature=signature;
      }
      EventHandler changed=(s,e)=>{
        if(Dispatcher.HasShutdownStarted)return;
        try{Dispatcher.BeginInvoke(new Action(Update));}catch(InvalidOperationException){}
      };
      bool listening=false;
      section.Loaded+=(s,e)=>{if(!listening){monitor.Changed+=changed;listening=true;}Update();};
      section.Unloaded+=(s,e)=>{if(listening){monitor.Changed-=changed;listening=false;}};
      check.Click+=(s,e)=>monitor.Refresh();
      prepare.Click+=async(s,e)=>{
        if(busy||monitorBusy||updatingManager||SystemUpdates.BlocksOperations(prefs)||RuntimeUpdates.BlocksOperations(prefs)){activity.Text="Espera a que termine la operación actual antes de preparar la red USB.";activity.Foreground=accent;activity.Visibility=Visibility.Visible;return;}
        if(!monitor.Snapshot.CanPrepare){monitor.Refresh();Update();return;}
        if(!Confirm("El móvil ya está detectado. Se preparará únicamente su conexión de red USB para que el PC mantenga Internet por Ethernet o Wi-Fi. No se cambiarán DNS, fotos ni la red habitual. Windows pedirá permiso de administrador. ¿Preparar esta red USB?"))return;
        busy=true;preparing=true;prepare.IsEnabled=false;check.IsEnabled=false;
        activity.Text="Preparando la red USB…";activity.Foreground=muted;activity.Visibility=Visibility.Visible;
        try {
          await UsbNetworkSafety.PrepareWithConsent();
          activity.Text="Red USB preparada. Mantén Inhouse Photos abierto en el móvil para subir por cable.";activity.Foreground=good;
          await RefreshLocalRoutes();monitor.Refresh();
        }catch(Exception ex){activity.Text=ex.Message;activity.Foreground=accent;}
        finally{busy=false;preparing=false;Update();}
      };
      Update();
    }
    ProgressBar SpaceBar(long total,long free,bool low=false) {
      var bar=new ProgressBar{Minimum=0,Maximum=Math.Max(1,total),Value=Math.Max(0,Math.Min(total,total-free)),Height=4,
        Foreground=low?Ui.Accent:Ui.Ink2};
      AutomationProperties.SetName(bar,"Espacio usado");
      return bar;
    }

    Task RenderOverview() {
      Heading("Resumen",null);
      var disk=default(DiskInfo);
      string diskIssue=null;
      try {disk=LibraryDisk();if(disk==null)diskIssue="No se encuentra el disco de tu biblioteca.";}
      catch(Exception ex){diskIssue=ex.Message;}

      // Status first: one sentence about the library and its one next action.
      var hero=new Grid{Margin=new Thickness(0,0,0,24)};
      hero.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
      hero.ColumnDefinitions.Add(new ColumnDefinition());
      hero.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
      var mark=new Ui.StatusMark(44);mark.VerticalAlignment=VerticalAlignment.Center;
      mark.Set(diskIssue!=null?Tone.Attention:lastLocal==true?(lastVerified==false?Tone.Attention:Tone.Good):lastLocal==false?Tone.Attention:Tone.Busy);
      hero.Children.Add(mark);
      var words=new StackPanel{Margin=new Thickness(16,0,16,0),VerticalAlignment=VerticalAlignment.Center};Grid.SetColumn(words,1);hero.Children.Add(words);
      var state=Ui.Title(diskIssue!=null?"No encuentro el disco de tus fotos":lastLocal==true?(lastVerified==false?"Hay que verificar la biblioteca":"Tus fotos están disponibles"):lastLocal==false?"El servidor está detenido":"Comprobando el servidor…");
      words.Children.Add(state);
      var where=Ui.Secondary(diskIssue??(disk==null?"":"Fotos guardadas en el disco "+disk.Root.TrimEnd('\\')));where.Margin=new Thickness(0,2,0,0);words.Children.Add(where);
      var actionHost=new StackPanel{Orientation=Orientation.Horizontal,VerticalAlignment=VerticalAlignment.Center};Grid.SetColumn(actionHost,2);hero.Children.Add(actionHost);
      var mainAction=PlaceAction(actionHost,"Comprobar servidor",async()=>{
        if(diskIssue!=null)await GoTo("Discos");
        else if(lastVerified==false){await Backend.ReverifyExisting(prefs,text=>Dispatcher.Invoke(()=>notice.Text=text));lastVerified=true;lastHealthCheck=DateTime.MinValue;await Render();}
        else if(lastLocal!=true){await Backend.StartManaged(prefs,text=>Dispatcher.Invoke(()=>notice.Text=text));lastLocal=true;lastHealthCheck=DateTime.MinValue;await Render();}
        else Open(Backend.CanonicalEndpoint(lastEndpoint==true?prefs.Endpoint:prefs.LocalEndpoint));
      },true);
      mainAction.Margin=new Thickness(0);
      if(diskIssue!=null)Ui.SetCaption(mainAction,"Ver almacenamiento");
      else if(lastVerified==false)Ui.SetCaption(mainAction,"Volver a verificar");
      else if(lastLocal==true)Ui.SetCaption(mainAction,"Abrir mis fotos","external");
      else if(lastLocal==false)Ui.SetCaption(mainAction,"Iniciar servidor");
      content.Children.Add(hero);
      Divide();

      var storage=NavigationRow("drive","Almacenamiento",
        disk==null?"Conecta el disco de la biblioteca":"Disco "+disk.Root.TrimEnd('\\')+" · "+Backend.Size(disk.Total)+" en total",
        disk==null?"No disponible":Backend.Size(disk.Free)+" libres",disk!=null&&LowSpace(disk)?accent:null,"Discos");
      if(disk!=null){var meter=Ui.Constrain(SpaceBar(disk.Total,disk.Free,LowSpace(disk)),320);meter.Margin=new Thickness(0,10,0,2);storage.Body.Children.Add(meter);}
      Divide();

      var backup=Backend.ReadFullBackupStatus(prefs);
      var backupAtSelectedDestination=BackupAtSelectedDestination(backup);
      var schedule=Backend.ReadBackupSchedule();
      DateTime completed;
      var backupOld=backup.FilesPresent&&DateTime.TryParse(backup.CompletedUtc,out completed)&&
        DateTime.UtcNow-completed.ToUniversalTime()>TimeSpan.FromDays(8);
      var backupValue=String.IsNullOrWhiteSpace(prefs.BackupDestination)?"No configurada":
        backup.HasCompletedRecord&&!backupAtSelectedDestination?"Pendiente en esta unidad":
        backup.FilesPresent?(backupOld?"Conviene renovarla":"Copia disponible"):
        backup.HasCompletedRecord?"Disco no disponible":"Pendiente de crear";
      var backupDetail=!String.IsNullOrWhiteSpace(schedule.LastError)?"Último intento: "+schedule.LastError:
        backup.HasCompletedRecord&&!backupAtSelectedDestination?
        backup.FilesPresent?"La copia anterior sigue en "+Path.GetDirectoryName(backup.BackupFolder):"La copia anterior no está disponible":
        backup.FilesPresent?"Última: "+DateLabel(backup.CompletedUtc):
        String.IsNullOrWhiteSpace(prefs.BackupDestination)?"Elige otra unidad, mejor en otro disco":"Todavía no hay una copia completa";
      var backupHealthy=backupAtSelectedDestination&&backup.FilesPresent&&!backupOld;
      NavigationRow(backupHealthy?"cloudDone":"cloud","Copia de seguridad",backupDetail,backupValue,backupHealthy?good:accent,"Protección");
      Divide();

      var localOnly=LocalOnlyEndpoint(prefs.Endpoint);
      var accessValue=localOnly?"Solo en este PC":String.IsNullOrWhiteSpace(prefs.Endpoint)?"Sin configurar":lastEndpoint==true?"Responde desde este PC":lastEndpoint==false?"No responde desde este PC":"Comprobando…";
      var access=NavigationRow("phone","Acceso desde el móvil",localOnly?"La dirección actual solo funciona en este PC.":
        String.IsNullOrWhiteSpace(prefs.Endpoint)?"Configura una dirección HTTPS para conectar el móvil.":"Prueba desde el móvil con datos móviles para verificar el acceso exterior.",
        accessValue,!localOnly&&lastEndpoint==true?good:lastEndpoint==null&&!localOnly&&!String.IsNullOrWhiteSpace(prefs.Endpoint)?Ui.Ink2:accent,"Conectar");
      var accessText=(TextBlock)access.Trailing.Children[0];
      Divide();
      RenderUsbConnection(true);
      var generation=++overviewGeneration;
      RefreshOverviewHealth(generation,state,mark,mainAction,accessText,diskIssue==null);
      return Task.FromResult(0);
    }

    async void RefreshOverviewHealth(int generation,TextBlock state,Ui.StatusMark mark,Button action,TextBlock access,bool diskReady) {
      if(DateTime.UtcNow-lastHealthCheck<TimeSpan.FromSeconds(20)&&lastLocal.HasValue&&lastEndpoint.HasValue&&lastVerified.HasValue)return;
      try {
        var localTask=Backend.Ping(prefs.LocalEndpoint);
        var remoteTask=String.IsNullOrWhiteSpace(prefs.Endpoint)||LocalOnlyEndpoint(prefs.Endpoint)?Task.FromResult(false):Backend.Ping(prefs.Endpoint);
        var local=await localTask;var remote=await remoteTask;
        var verified=true;
        if(local)try {
          Backend.ValidateManagedConfiguration(prefs);
          var receipt=Backend.Json.Deserialize<AdoptionReceipt>(File.ReadAllText(prefs.ReceiptPath));
          Backend.AssertManagedIdentity(prefs,receipt.Containers,await Backend.InspectServer(prefs));
        }catch {verified=false;}
        lastLocal=local;lastEndpoint=remote;lastVerified=verified;lastHealthCheck=DateTime.UtcNow;
        if(generation!=overviewGeneration||page!="Inicio")return;
        state.Text=!diskReady?"No encuentro el disco de tus fotos":local?(verified?"Tus fotos están disponibles":"Hay que verificar la biblioteca"):"El servidor está detenido";
        mark.Set(diskReady&&local&&verified?Tone.Good:Tone.Attention);
        if(!diskReady)Ui.SetCaption(action,"Ver almacenamiento");
        else if(local&&verified)Ui.SetCaption(action,"Abrir mis fotos","external");
        else Ui.SetCaption(action,local?"Volver a verificar":"Iniciar servidor");
        access.Text=LocalOnlyEndpoint(prefs.Endpoint)?"Solo en este PC":String.IsNullOrWhiteSpace(prefs.Endpoint)?"Sin configurar":remote?"Responde desde este PC":"No responde desde este PC";
        access.Foreground=remote?good:accent;
      } catch {if(generation==overviewGeneration&&page=="Inicio"&&diskReady){state.Text="No se pudo comprobar el servidor";mark.Set(Tone.Attention);}}
    }

    Task RenderBackupPage() {
      Heading("Copias de seguridad","Una segunda copia de tus fotos, vídeos y álbumes en otra unidad.");
      var backup=Backend.ReadFullBackupStatus(prefs);
      var backupAtSelectedDestination=BackupAtSelectedDestination(backup);
      var noDestination=String.IsNullOrWhiteSpace(prefs.BackupDestination);
      DateTime completed;
      var backupOld=backup.FilesPresent&&DateTime.TryParse(backup.CompletedUtc,out completed)&&
        DateTime.UtcNow-completed.ToUniversalTime()>TimeSpan.FromDays(8);

      // Hero: the cloud, the state in one line, and the page's primary action.
      var hero=new Grid{Margin=new Thickness(0,0,0,8)};
      hero.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
      hero.ColumnDefinitions.Add(new ColumnDefinition());
      var cloud=new Ui.BackupCloud{VerticalAlignment=VerticalAlignment.Top,Margin=new Thickness(0,-8,0,0)};hero.Children.Add(cloud);
      var words=new StackPanel{Margin=new Thickness(16,8,0,0)};Grid.SetColumn(words,1);hero.Children.Add(words);
      var restingState=backup.HasCompletedRecord&&!backupAtSelectedDestination?
        backup.FilesPresent?"Copia anterior disponible":"Copia anterior no disponible":
        backup.FilesPresent?"Copia disponible":backup.HasCompletedRecord?"Disco de copia no disponible":"Todavía no hay una copia completa";
      var restingCloud=noDestination&&!backup.HasCompletedRecord?Ui.CloudState.Off:
        backup.FilesPresent&&backupAtSelectedDestination&&!backupOld?Ui.CloudState.Done:
        backup.HasCompletedRecord?Ui.CloudState.Attention:Ui.CloudState.Idle;
      var stateText=Ui.Title(restingState);words.Children.Add(stateText);
      var facts=Column();words.Children.Add(facts);
      if(backup.HasCompletedRecord){
        var when=Ui.Secondary("Terminó el "+DateLabel(backup.CompletedUtc));when.Margin=new Thickness(0,2,0,0);facts.Children.Add(when);
        var folder=Ui.Caption(backup.BackupFolder);folder.Margin=new Thickness(0,2,0,0);folder.TextTrimming=TextTrimming.CharacterEllipsis;folder.TextWrapping=TextWrapping.NoWrap;folder.ToolTip=backup.BackupFolder;facts.Children.Add(folder);
        if(!backupAtSelectedDestination){var pending=Ui.Text("Todavía no hay una copia completa registrada en la unidad elegida ahora.",Ui.BodySize,accent);pending.Margin=new Thickness(0,6,0,0);facts.Children.Add(pending);}
      } else {var none=Ui.Secondary(noDestination?"Elige primero la unidad donde guardarla.":"Las copias solo de la base de datos no incluyen tus fotos ni vídeos.");none.Margin=new Thickness(0,2,0,0);facts.Children.Add(none);}

      // Live progress, visible only while a copy runs.
      var progress=Ui.Secondary(backupProgressText??"Copia en curso…");progress.Margin=new Thickness(0,2,0,0);
      AutomationProperties.SetLiveSetting(progress,AutomationLiveSetting.Polite);
      backupProgressView=progress;words.Children.Add(progress);
      var stageNames=new[]{"Base de datos","Fotos y vídeos","Comprobación"};
      var stages=new WrapPanel{Margin=new Thickness(0,14,0,0)};
      var stageMarks=new Ui.StepMarker[3];var stageLabels=new TextBlock[3];
      for(var i=0;i<3;i++){
        if(i>0)stages.Children.Add(new Border{Width=24,Height=1,Background=Ui.Stroke,VerticalAlignment=VerticalAlignment.Center,Margin=new Thickness(10,0,10,0)});
        stageMarks[i]=new Ui.StepMarker(i+1,20);stages.Children.Add(stageMarks[i]);
        stageLabels[i]=Ui.Text(stageNames[i],Ui.BodySize,Ui.Ink2);stageLabels[i].TextWrapping=TextWrapping.NoWrap;stageLabels[i].VerticalAlignment=VerticalAlignment.Center;stageLabels[i].Margin=new Thickness(8,0,0,0);
        stages.Children.Add(stageLabels[i]);
      }
      if(!noDestination)words.Children.Add(stages);
      backupProgressStage=text=>{
        var index=text==null?-1:text.Contains("1 de 3")?0:text.Contains("2 de 3")?1:text.Contains("3 de 3")?2:-1;
        for(var i=0;i<3;i++){
          stageMarks[i].Set(index<0?Ui.StepState.Pending:i<index?Ui.StepState.Done:i==index?Ui.StepState.Current:Ui.StepState.Pending);
          stageLabels[i].Foreground=index>=0&&i<=index?Ui.Ink:Ui.Ink2;
        }
      };
      var actions=new StackPanel{Orientation=Orientation.Horizontal,Margin=new Thickness(0,20,0,0)};words.Children.Add(actions);
      var cancel=Ui.Button("Detener copia");cancel.Margin=new Thickness(0,0,8,0);
      cancel.Click+=(s,e)=>{if(backupCancellation!=null){backupCancellation.Cancel();SetBackupProgress("Deteniendo la copia. Se conservarán los archivos ya copiados.");}};
      Button create=null;
      void ShowRunning(bool running){
        cloud.Set(running?Ui.CloudState.Copying:restingCloud);
        stateText.Text=running?"Copiando tu biblioteca":restingState;
        facts.Visibility=running?Visibility.Collapsed:Visibility.Visible;
        progress.Visibility=running?Visibility.Visible:Visibility.Collapsed;
        cancel.Visibility=running?Visibility.Visible:Visibility.Collapsed;
        if(create!=null)create.Visibility=running?Visibility.Collapsed:Visibility.Visible;
        backupProgressStage(running?backupProgressText:null);
      }
      if(!noDestination) {
        create=PlaceAction(actions,"Crear copia completa",async()=>{
          if(!Confirm("Se copiarán fotos, vídeos y base de datos a otra unidad. La primera copia puede tardar bastante. No se borrarán archivos existentes. ¿Continuar?"))return;
          backupCancellation=new CancellationTokenSource();ShowRunning(true);
          try {var result=await Backend.Backup(prefs,text=>Dispatcher.Invoke(()=>SetBackupProgress(text)),backupCancellation.Token);
            var scheduleUpdated=true;
            try{Backend.RecordManualBackupSuccessForSchedule();}catch{scheduleUpdated=false;}
            notice.Text="Copia terminada en "+result+". No se ha probado una restauración."+
              (scheduleUpdated?"":" Revisa la fecha de la próxima copia automática.");
          } finally {backupCancellation.Dispose();backupCancellation=null;backupProgressText=null;await Render();}
        },true);
        create.IsEnabled=backupCancellation==null;
      }
      actions.Children.Add(cancel);
      if(backup.FilesPresent)PlaceLink(actions,"Abrir carpeta de la copia",()=>{
        Process.Start(new ProcessStartInfo(backup.BackupFolder){UseShellExecute=true});return Task.FromResult(0);
      },"external").Margin=new Thickness(8,0,0,0);
      content.Children.Add(hero);
      ShowRunning(backupCancellation!=null);

      Section("Destino");
      var target=Ui.ListRow("drive",noDestination?"Sin destino elegido":prefs.BackupDestination,
        noDestination?"Elige otra unidad. Mejor si es un disco físico distinto.":"Puedes cambiarlo sin mover la biblioteca.");
      if(noDestination)target.Heading.Foreground=accent;
      content.Children.Add(target.Root);
      PlaceAction(target.Trailing,noDestination?"Elegir destino":"Cambiar destino",async()=>{
        var path=PickFolder();if(path==null)return;
        Backend.ValidateBackup(Backend.Library(prefs),path);
        prefs.BackupDestination=path;Backend.Save(prefs);await Render();notice.Text="Destino guardado. Si es una unidad nueva, falta crear una copia completa allí. La copia anterior no se ha borrado.";
      },noDestination).Margin=new Thickness(0);

      Section("Copia semanal");
      var schedule=Backend.ReadBackupSchedule();
      var weekly=Ui.ListRow("calendar",schedule.Enabled?"Activada":"Desactivada",
        schedule.Enabled?"Próxima comprobación: "+DateLabel(schedule.NextDueUtc)+". El PC y el gestor deben estar encendidos.":"Es opcional. Actívala cuando tengas un disco de copia conectado.");
      if(!String.IsNullOrWhiteSpace(schedule.LastError)){var problem=Ui.Text("Último problema: "+schedule.LastError,Ui.BodySize,accent);problem.Margin=new Thickness(0,4,0,0);weekly.Body.Children.Add(problem);}
      content.Children.Add(weekly.Root);
      var scheduleButton=PlaceAction(weekly.Trailing,schedule.Enabled?"Desactivar copia semanal":"Activar copia semanal",async()=>{
        if(schedule.Enabled){Backend.SetBackupScheduleEnabled(false);await Render();notice.Text="Copia semanal desactivada. No se ha detenido el servidor.";return;}
        if(String.IsNullOrWhiteSpace(prefs.BackupDestination))throw new IOException("Elige primero otra unidad para la copia.");
        if(!await Startup.IsEnabled()){
          if(!Confirm("La copia semanal necesita que el gestor se inicie con Windows. ¿Activar también el inicio automático?"))return;
          await Startup.SetEnabled(prefs,true);
        }
        Backend.SetBackupScheduleEnabled(true);await Render();notice.Text="Copia semanal activada. Puedes hacer la primera copia ahora.";
      });
      scheduleButton.Margin=new Thickness(0);
      scheduleButton.IsEnabled=schedule.Enabled||!String.IsNullOrWhiteSpace(prefs.BackupDestination);

      content.Children.Add(Ui.Divider(new Thickness(0,24,0,16)));
      var safety=new Grid();safety.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(40)});safety.ColumnDefinitions.Add(new ColumnDefinition());
      var shield=Ui.Icon("shield",20,Ui.Ink2);shield.VerticalAlignment=VerticalAlignment.Top;shield.HorizontalAlignment=HorizontalAlignment.Left;safety.Children.Add(shield);
      var safetyText=Ui.Secondary("Las copias solo añaden archivos: nunca borran ni sobrescriben lo que ya hay en el destino. Evita editar la biblioteca durante la copia. El gestor confirma que terminó y que los archivos siguen presentes; no se ha probado una restauración completa.");
      Grid.SetColumn(safetyText,1);safety.Children.Add(safetyText);content.Children.Add(safety);
      return Task.FromResult(0);
    }

    Task RenderStoragePage() {
      Heading("Almacenamiento","Mira cuánto sitio queda antes de subir más fotos.");
      try {
        var disk=LibraryDisk();
        if(disk==null)throw new IOException("El disco de la biblioteca no está disponible.");
        var low=LowSpace(disk);
        var summary=new Grid();
        summary.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(40)});summary.ColumnDefinitions.Add(new ColumnDefinition());summary.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
        var driveIcon=Ui.Icon("drive",24,Ui.Ink2);driveIcon.VerticalAlignment=VerticalAlignment.Top;driveIcon.HorizontalAlignment=HorizontalAlignment.Left;driveIcon.Margin=new Thickness(0,2,0,0);summary.Children.Add(driveIcon);
        var names=new StackPanel();Grid.SetColumn(names,1);summary.Children.Add(names);
        names.Children.Add(Ui.Title("Disco "+disk.Root.TrimEnd('\\')));
        var role=Ui.Secondary("Guarda tu biblioteca de fotos");role.Margin=new Thickness(0,2,0,0);names.Children.Add(role);
        var free=Ui.Text(Backend.Size(disk.Free)+" libres",Ui.TitleSize,low?accent:Ui.Ink,true);free.TextWrapping=TextWrapping.NoWrap;free.VerticalAlignment=VerticalAlignment.Top;
        Grid.SetColumn(free,2);summary.Children.Add(free);
        content.Children.Add(summary);
        var bar=SpaceBar(disk.Total,disk.Free,low);bar.Height=6;bar.Margin=new Thickness(40,20,0,8);content.Children.Add(bar);
        var scale=new Grid{Margin=new Thickness(40,0,0,0)};
        var used=Math.Max(0,disk.Total-disk.Free);
        var usedText=Ui.Caption(Backend.Size(used)+" usados");scale.Children.Add(usedText);
        var totalText=Ui.Caption(Backend.Size(disk.Total)+" en total");totalText.HorizontalAlignment=HorizontalAlignment.Right;scale.Children.Add(totalText);
        content.Children.Add(scale);
        if(low){var warning=Ui.Text("Queda poco espacio. Amplía el disco antes de seguir subiendo fotos.",Ui.BodySize,accent);warning.Margin=new Thickness(40,12,0,0);content.Children.Add(warning);}
      }catch(Exception ex){content.Children.Add(EmptyState("drive",Tone.Attention,"Disco no disponible",ex.Message));}

      Section("Unidad de la segunda copia");
      if(!String.IsNullOrWhiteSpace(prefs.BackupDestination)) {
        Ui.Row copy;
        try {var drive=new DriveInfo(Path.GetPathRoot(prefs.BackupDestination));
          copy=Ui.ListRow("drive",prefs.BackupDestination,drive.IsReady?null:"Conecta el disco antes de hacer una copia.");
          var state=Ui.Text(drive.IsReady?Backend.Size(drive.AvailableFreeSpace)+" libres":"No está conectado",Ui.BodySize,drive.IsReady?Ui.Ink:accent,true);
          state.TextWrapping=TextWrapping.NoWrap;copy.Trailing.Children.Add(state);}
        catch {copy=Ui.ListRow("drive",prefs.BackupDestination,"Conecta el disco antes de hacer una copia.");
          var state=Ui.Text("No está conectado",Ui.BodySize,accent,true);state.TextWrapping=TextWrapping.NoWrap;copy.Trailing.Children.Add(state);}
        content.Children.Add(copy.Root);
      } else {
        var copy=Ui.ListRow("drive","Sin configurar","Elige otra unidad para guardar una segunda copia.");
        copy.Heading.Foreground=accent;content.Children.Add(copy.Root);
        PlaceAction(copy.Trailing,"Preparar una copia",()=>GoTo("Protección"),false,"arrow").Margin=new Thickness(0);
      }
      var advanced=Column();
      var explain=Ui.Secondary("Estos controles cambian la configuración de Windows. No trasladan la biblioteca.");explain.Margin=new Thickness(0,0,0,12);advanced.Children.Add(explain);
      var advancedActions=new StackPanel{Orientation=Orientation.Horizontal};advanced.Children.Add(advancedActions);
      var inventory=Column();inventory.Margin=new Thickness(0,12,0,0);advanced.Children.Add(inventory);
      PlaceAction(advancedActions,"Ver todos los discos",async()=>{inventory.Children.Add(Fine(await Task.Run(()=>Backend.PhysicalDisks())));});
      PlaceAction(advancedActions,"Configurar discos protegidos",()=>{
        Process.Start(new ProcessStartInfo(typeof(Program).Assembly.Location,"--storage"){
          UseShellExecute=true,Verb="runas",WindowStyle=ProcessWindowStyle.Normal});return Task.FromResult(0);
      });
      var expander=new Expander{Header="Opciones avanzadas de discos",Content=advanced,Margin=new Thickness(0,24,0,0)};
      content.Children.Add(expander);
      var raid=Ui.Caption("Un espejo o RAID no sustituye una copia en otro disco.");raid.Margin=new Thickness(0,4,0,0);content.Children.Add(raid);
      return Task.FromResult(0);
    }

    Task RenderConnectPage() {return RenderPairingPage();}

    async Task RenderSettingsPage() {
      Heading("Ajustes",null);
      var mobileTitle=Section("Dirección para el móvil","La dirección HTTPS de tu biblioteca.");mobileTitle.Margin=new Thickness(0,0,0,2);
      var field=new Grid();
      field.ColumnDefinitions.Add(new ColumnDefinition());field.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
      var endpoint=new TextBox{Text=LocalOnlyEndpoint(prefs.Endpoint)?"":prefs.Endpoint??""};
      AutomationProperties.SetName(endpoint,"Dirección HTTPS para el móvil");
      field.Children.Add(endpoint);
      var saveHost=new StackPanel{Orientation=Orientation.Horizontal,Margin=new Thickness(8,0,0,0)};Grid.SetColumn(saveHost,1);field.Children.Add(saveHost);
      var fieldMeasure=Ui.Constrain(field,640);fieldMeasure.Margin=new Thickness(0,12,0,0);content.Children.Add(fieldMeasure);
      PlaceAction(saveHost,"Comprobar y guardar",async()=>{
        var url=Backend.CanonicalEndpoint(endpoint.Text);
        if(LocalOnlyEndpoint(url))throw new IOException("Esta dirección solo funciona en este PC. Usa tu dominio HTTPS para el móvil.");
        if(!await Backend.Ping(url))throw new IOException("La dirección no responde desde este PC. No se ha guardado.");
        prefs.Endpoint=url;Backend.Save(prefs);lastHealthCheck=DateTime.MinValue;
        notice.Text="Dirección guardada. Pruébala también desde el móvil con datos móviles.";
      },true).Margin=new Thickness(0);
      var hint=Ui.Caption("Se comprueba desde este PC. Prueba el acceso exterior con datos móviles.");hint.Margin=new Thickness(0,8,0,0);content.Children.Add(hint);
      await RenderManagement();

      var advanced=Column();
      Ui.Row TechnicalRow(string icon,string title,string detail,bool first=false){
        if(!first)advanced.Children.Add(Ui.Divider(new Thickness(0)));
        var row=Ui.ListRow(icon,title,detail);advanced.Children.Add(row.Root);return row;
      }
      var folderRow=TechnicalRow("folder","Carpeta del servidor",prefs.Installation??"Sin configurar",true);
      PlaceAction(folderRow.Trailing,"Cambiar carpeta",async()=>{
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
      }).Margin=new Thickness(0);
      var diagnostics=TechnicalRow("wrench","Diagnóstico","El estado de los servicios se consulta solo cuando lo solicitas.");
      var serviceReport=Fine("");serviceReport.Margin=new Thickness(0,6,0,0);serviceReport.Visibility=Visibility.Collapsed;diagnostics.Body.Children.Add(serviceReport);
      PlaceAction(diagnostics.Trailing,"Abrir registro de errores",()=>{
        var path=Path.Combine(Backend.SettingsDir,"diagnostics");Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo(path){UseShellExecute=true});return Task.FromResult(0);
      });
      PlaceAction(diagnostics.Trailing,"Comprobar servicios",async()=>{
        var data=await Backend.Compose(prefs,"ps --format json",15);
        var names=new Dictionary<string,string>{{"immich-server","Galería"},{"immich-machine-learning","Análisis"},{"database","Base de datos"},{"redis","Tareas"},{"caddy","Conexión segura"}};
        var lines=data.Split(new[]{'\r','\n'},StringSplitOptions.RemoveEmptyEntries).Select(line=>{
          var row=Backend.Json.Deserialize<Dictionary<string,object>>(line);
          var key=Convert.ToString(row.ContainsKey("Service")?row["Service"]:"");
          var state=Convert.ToString(row.ContainsKey("State")?row["State"]:"");
          return (names.ContainsKey(key)?names[key]:key)+" · "+(state=="running"?"Activo":state);
        });
        serviceReport.Text=String.Join("\n",lines);serviceReport.Visibility=Visibility.Visible;
      }).Margin=new Thickness(0);
      var snapshotRow=TechnicalRow("drive","Instantánea de la base de datos","Una instantánea de base de datos no contiene fotos ni vídeos.");
      PlaceAction(snapshotRow.Trailing,"Guardar solo base de datos",async()=>{
        notice.Text="Instantánea de metadatos guardada: "+await Backend.Snapshot(prefs);
      }).Margin=new Thickness(0);
      var licenseRow=TechnicalRow("info","Licencias","Los códigos QR se generan en este PC con QRCoder.");
      PlaceAction(licenseRow.Trailing,"Licencia del generador QR",()=>{
        MessageBox.Show(this,PairingClient.QrLicense(),"QRCoder · licencia MIT",MessageBoxButton.OK,MessageBoxImage.Information);
        return Task.CompletedTask;
      }).Margin=new Thickness(0);
      content.Children.Add(new Expander{Header="Opciones técnicas",Content=advanced,Margin=new Thickness(0,36,0,0)});
    }
  }
}
