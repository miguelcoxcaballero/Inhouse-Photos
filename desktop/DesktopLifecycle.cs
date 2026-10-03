using System;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Markup;
using System.Windows.Threading;
using Forms=System.Windows.Forms;

namespace InhousePhotos {
  public sealed partial class ServerWindow {
    Forms.NotifyIcon tray;
    DispatcherTimer monitor;
    DispatcherTimer lanMonitor, lanDebounce;
    NetworkAddressChangedEventHandler networkAddressChanged;
    bool lanPublishBusy;
    EventHandler usbDevicesChanged;
    RemoteManagement remoteManagement;
    string remoteOperation="",remoteError="";
    bool monitorBusy, exitRequested, updateClose, updatingManager;
    DateTime retryAfter=DateTime.MinValue;
    internal void InitializeLifecycle(bool hidden) {
      tray=new Forms.NotifyIcon{Text="Inhouse Photos Server",Icon=System.Drawing.Icon.ExtractAssociatedIcon(typeof(ServerWindow).Assembly.Location),Visible=true};
      var menu=new Forms.ContextMenuStrip();menu.Items.Add("Abrir Inhouse Photos",null,(s,e)=>Dispatcher.Invoke(BringToFront));
      menu.Items.Add("Salir del gestor",null,(s,e)=>Dispatcher.Invoke(()=>{if(busy||SystemUpdates.IsBusy){notice.Text="Espera a que termine la operación antes de salir.";return;}exitRequested=true;Close();}));
      tray.ContextMenuStrip=menu;tray.DoubleClick+=(s,e)=>Dispatcher.Invoke(BringToFront);
      Closing+=(s,e)=>{if((busy||monitorBusy||SystemUpdates.IsBusy)&&!updateClose){e.Cancel=true;notice.Text="Espera a que termine la operación antes de salir.";return;}if(!exitRequested){e.Cancel=true;Hide();}};
      Closed+=(s,e)=>{
        if(monitor!=null)monitor.Stop();lanMonitor?.Stop();lanDebounce?.Stop();
        if(networkAddressChanged!=null)NetworkChange.NetworkAddressChanged-=networkAddressChanged;
        if(usbDevicesChanged!=null)UsbDeviceMonitor.Current.Changed-=usbDevicesChanged;
        UsbDeviceMonitor.Current.Dispose();
        remoteManagement?.Dispose();tray.Dispose();
      };
      monitor=new DispatcherTimer{Interval=TimeSpan.FromSeconds(45)};
      monitor.Tick+=async(s,e)=>await Supervise();monitor.Start();
      Dispatcher.BeginInvoke(new Action(async()=>await Supervise()));
      // A USB tether can appear while backups are already running. Discovery
      // must not wait for the full supervisor, or be paused by a disk backup.
      // Publish only private address hints; do not alter gateways or adapters.
      lanDebounce=new DispatcherTimer{Interval=TimeSpan.FromSeconds(2)};
      lanDebounce.Tick+=async(s,e)=>{lanDebounce.Stop();await RefreshLocalRoutes();};
      networkAddressChanged=(s,e)=>{
        if(Dispatcher.HasShutdownStarted)return;
        try{Dispatcher.BeginInvoke(new Action(()=>{lanDebounce.Stop();lanDebounce.Start();}));}
        catch(InvalidOperationException){ /* The window may be closing. */ }
      };
      NetworkChange.NetworkAddressChanged+=networkAddressChanged;
      lanMonitor=new DispatcherTimer{Interval=TimeSpan.FromSeconds(10)};
      lanMonitor.Tick+=async(s,e)=>await RefreshLocalRoutes();lanMonitor.Start();
      // Phone presence changes even when no tether interface exists yet.
      // Observe it independently of backup supervision and update only the
      // cable section; never rebuild the whole dashboard on a USB event.
      usbDevicesChanged=(s,e)=>{
        if(Dispatcher.HasShutdownStarted)return;
        try{Dispatcher.BeginInvoke(new Action(()=>{lanDebounce.Stop();lanDebounce.Start();}));}
        catch(InvalidOperationException){}
      };
      UsbDeviceMonitor.Current.Changed+=usbDevicesChanged;
      UsbDeviceMonitor.Current.Start();
      // A recovery journal blocks supervision, but the phone must still reach
      // the existing authenticated bridge to request ResumeRecord.
      try{EnsureRemoteListener();}catch(Exception ex){notice.Text="Gestión remota no disponible: "+ex.Message;}
    }
    void EnsureRemoteListener() {
      if(remoteManagement!=null||!prefs.Managed)return;
      remoteManagement=new RemoteManagement(prefs,
        ReadRemoteStatus,PerformRemoteAction,
        ()=>Dispatcher.Invoke(()=>busy||monitorBusy||updatingManager||backupCancellation!=null));
    }
    async Task RefreshLocalRoutes() {
      if(lanPublishBusy||exitRequested||updatingManager||SystemUpdates.BlocksOperations(prefs)||RuntimeUpdates.BlocksOperations(prefs)||!prefs.Managed)return;
      lanPublishBusy=true;
      try{await Task.Run(()=>LanRoute.Publish(prefs));}
      catch{ /* Discovery outages never stop the existing HTTPS server. */ }
      finally{lanPublishBusy=false;}
    }
    internal void BringToFront(){Show();WindowState=WindowState.Normal;Activate();}
    async Task Supervise() {
      // Resume first: a durable intent deliberately blocks ordinary automatic
      // restarts and backups, but must never block its own continuation.
      if(!busy&&!monitorBusy&&!updatingManager&&backupCancellation==null&&prefs.Managed) {
        try{if(BeginSystemUpdate(true,true))return;}
        catch(Exception ex){notice.Text=ex.Message;}
      }
      if(busy||monitorBusy||updatingManager||SystemUpdates.BlocksOperations(prefs)||RuntimeUpdates.BlocksOperations(prefs)||!prefs.Managed||DateTime.UtcNow<retryAfter)return;
      monitorBusy=true;
      try {
        bool autoStart=false;
        try{autoStart=await Startup.IsEnabled();}catch{}
        var online=await Backend.Ping(prefs.LocalEndpoint);
        if(autoStart&&!online) {
          await Backend.StartManaged(prefs,text=>Dispatcher.Invoke(()=>notice.Text=text));
          online=true;notice.Text="Servidor disponible.";
        }
        if(online) {
          try {
            EnsureRemoteListener();
            await remoteManagement.EnsurePublished();
          }catch(Exception ex){notice.Text="Actualizaciones remotas no disponibles: "+ex.Message;}
          try {await LanRoute.Publish(prefs);} catch { /* Public HTTPS remains available if LAN discovery cannot be published. */ }
          try {
            var update=await SystemUpdates.Check(prefs);
            if(update.Available&&String.IsNullOrWhiteSpace(notice.Text))notice.Text="Inhouse Photos "+update.LatestVersion+" disponible. Abre Ajustes para actualizar.";
          }catch{ /* A GitHub outage never affects photos or backups. */ }
        }
        if(Backend.IsBackupDue()) {
          if(String.IsNullOrWhiteSpace(prefs.BackupDestination)) {
            Backend.RecordScheduledBackupResult(false,"destination");
            notice.Text="La copia semanal necesita un segundo disco. Ve a Copias para elegirlo.";
          } else if(!online) {
            Backend.RecordScheduledBackupResult(false,"server");
            notice.Text="La copia semanal esperará a que el servidor esté disponible.";
          } else {
            Backend.RecordScheduledBackupStart();
            backupCancellation=new CancellationTokenSource();busy=true;
            try {
              if(IsVisible&&page=="Protección")await Render();
              await Backend.Backup(prefs,text=>Dispatcher.Invoke(()=>SetBackupProgress(text)),backupCancellation.Token);
              Backend.RecordScheduledBackupResult(true,null);
              notice.Text="Copia semanal terminada. Comprueba su estado en Copias.";
            } catch(OperationCanceledException) {
              Backend.RecordScheduledBackupResult(false,"cancelled");
              notice.Text="Copia semanal detenida. Los archivos ya copiados se conservan.";
            } catch(Exception ex) {
              Backend.RecordScheduledBackupResult(false,ex is InsufficientBackupSpaceException||!Directory.Exists(prefs.BackupDestination)?"destination":"unknown");
              notice.Text="La copia semanal no se completó: "+ex.Message;
            } finally {
              backupCancellation.Dispose();backupCancellation=null;backupProgressText=null;busy=false;
              if(IsVisible&&(page=="Inicio"||page=="Protección"))await Render();
            }
          }
        }
        retryAfter=DateTime.UtcNow.AddSeconds(45);
      }catch(Exception ex){notice.Text=ex.Message;retryAfter=DateTime.UtcNow.AddMinutes(2);}
      finally{monitorBusy=false;}
    }
    internal static string OptionalDriveRoot(string path) {
      // .NET Framework throws for an empty path. A missing or malformed
      // optional backup destination must not hide the entire manager status.
      if(String.IsNullOrWhiteSpace(path))return null;
      try {var root=Path.GetPathRoot(path);return String.IsNullOrEmpty(root)?null:root;}
      catch(ArgumentException){return null;}
      catch(NotSupportedException){return null;}
    }
    async Task<RemoteManagerStatus> ReadRemoteStatus() {
      try {
      var ui=Dispatcher.Invoke(()=>new {
        Busy=busy||updatingManager||backupCancellation!=null,
        BackupRunning=backupCancellation!=null,
        Operation=backupCancellation!=null?"backup":remoteOperation,
        Progress=backupProgressText??"",
        Error=remoteError
      });
      var library=Backend.Library(prefs);
      var libraryRoot=Path.GetPathRoot(library);
      var backupRoot=OptionalDriveRoot(prefs.BackupDestination);
      var disks=Backend.Disks().Select(d=>{
        var isLibrary=String.Equals(d.Root,libraryRoot,StringComparison.OrdinalIgnoreCase);
        var isBackup=backupRoot!=null&&String.Equals(d.Root,backupRoot,StringComparison.OrdinalIgnoreCase);
        var canBackup=false;
        try{Backend.ValidateBackup(library,d.Root);canBackup=!isLibrary;}catch{}
        return new RemoteDiskStatus {Root=d.Root,Name=d.Name,Total=d.Total,Free=d.Free,
          IsLibrary=isLibrary,IsBackup=isBackup,CanUseForBackup=canBackup};
      }).ToArray();
      var backup=Backend.ReadFullBackupStatus(prefs);
      var schedule=Backend.ReadBackupSchedule();
      bool startup=false,known=false;
      try{startup=await Startup.IsEnabled();known=true;}catch{}
      return new RemoteManagerStatus {
        Version=SystemUpdates.Status().CurrentVersion,ServerOnline=await Backend.Ping(prefs.LocalEndpoint),Busy=ui.Busy||SystemUpdates.IsBusy||
          (RuntimeUpdates.BlocksOperations(prefs)&&!RuntimeUpdates.Status().RecoveryRequired),
        Operation=ui.Operation,Progress=ui.Progress,Error=ui.Error,
        LibraryDrive=libraryRoot,BackupDestination=prefs.BackupDestination??"",
        BackupConfigured=!String.IsNullOrWhiteSpace(prefs.BackupDestination),
        BackupRunning=ui.BackupRunning,BackupPresent=backup.FilesPresent,
        BackupCompletedUtc=backup.CompletedUtc??"",WeeklyBackupEnabled=schedule.Enabled,
        NextBackupUtc=schedule.NextDueUtc??"",StartupEnabled=startup,StartupKnown=known,Disks=disks,
        Usb=UsbDeviceMonitor.Current.Snapshot,RuntimeUpdate=RuntimeUpdates.Status(),SystemUpdate=SystemUpdates.Status()
      };
      }catch(Exception ex) {
        // This method receives no credentials. Keep only the failure type and
        // message on this PC, never request headers or a full exception dump.
        try {var directory=Path.Combine(Backend.SettingsDir,"diagnostics");Backend.PrivateDirectory(directory);
          File.WriteAllText(Path.Combine(directory,"manager-status-error.txt"),ex.GetType().Name+": "+ex.Message);}
        catch{}
        throw;
      }
    }
    Task<bool> PerformRemoteAction(string action) {
      return Task.FromResult(Dispatcher.Invoke(()=>BeginRemoteAction(action)));
    }
    bool BeginRemoteAction(string action) {
      if(action=="backup/cancel") {
        if(backupCancellation==null)return false;
        backupCancellation.Cancel();SetBackupProgress("Deteniendo la copia. Se conservarán los archivos ya copiados.");return true;
      }
      if(busy||monitorBusy||updatingManager||ManagerUpdates.IsApplying||backupCancellation!=null)return false;
      if(action=="system-update"||action=="runtime-update")return BeginSystemUpdate(false,true);
      if(SystemUpdates.BlocksOperations(prefs)||RuntimeUpdates.BlocksOperations(prefs))return false;
      if(action.StartsWith("backup/destination/",StringComparison.Ordinal)) {
        var letter=action.Substring("backup/destination/".Length);
        if(letter.Length!=1||letter[0]<'A'||letter[0]>'Z')throw new ArgumentException("Invalid backup drive.");
        var drive=Backend.Disks().FirstOrDefault(d=>String.Equals(d.Root,letter+@":\",StringComparison.OrdinalIgnoreCase));
        if(drive==null)throw new InvalidOperationException("The selected backup drive is not connected.");
        Backend.ValidateBackup(Backend.Library(prefs),drive.Root);
        prefs.BackupDestination=drive.Root;Backend.Save(prefs);
        remoteError="";remoteOperation="";notice.Text="Destino de copia guardado desde el móvil. No se han movido ni borrado fotos.";
        if(IsVisible)_=Render();return true;
      }
      if(action=="backup/start") {
        if(String.IsNullOrWhiteSpace(prefs.BackupDestination))throw new InvalidOperationException("Select a backup drive first.");
        Backend.ValidateBackup(Backend.Library(prefs),prefs.BackupDestination);
        backupCancellation=new CancellationTokenSource();busy=true;remoteError="";remoteOperation="backup";
        _=RunRemoteBackup();return true;
      }
      if(action=="snapshot") {
        busy=true;remoteError="";remoteOperation="snapshot";
        _=RunRemoteOperation(async()=>{await Backend.Snapshot(prefs);notice.Text="Instantánea de metadatos terminada.";});return true;
      }
      if(action=="backup/schedule/enable") {
        if(String.IsNullOrWhiteSpace(prefs.BackupDestination))throw new InvalidOperationException("Select a backup drive first.");
        Backend.ValidateBackup(Backend.Library(prefs),prefs.BackupDestination);
        busy=true;remoteError="";remoteOperation="schedule";
        _=RunRemoteOperation(async()=>{if(!await Startup.IsEnabled())await Startup.SetEnabled(prefs,true);
          Backend.SetBackupScheduleEnabled(true);notice.Text="Copia semanal activada desde el móvil.";});return true;
      }
      if(action=="backup/schedule/disable") {
        Backend.SetBackupScheduleEnabled(false);remoteError="";remoteOperation="";
        notice.Text="Copia semanal desactivada desde el móvil.";if(IsVisible)_=Render();return true;
      }
      if(action=="startup/disable"&&Backend.ReadBackupSchedule().Enabled)
        throw new InvalidOperationException("Disable the weekly backup before turning off Windows startup.");
      if(action=="startup/enable"||action=="startup/disable") {
        var enabled=action=="startup/enable";
        busy=true;remoteError="";remoteOperation="startup";
        _=RunRemoteOperation(async()=>{await Startup.SetEnabled(prefs,enabled);
          notice.Text=enabled?"Inicio automático activado desde el móvil.":"Inicio automático desactivado desde el móvil.";});return true;
      }
      return false;
    }
    async Task RunRemoteBackup() {
      var cancellation=backupCancellation;
      try {
        await Backend.Backup(prefs,text=>Dispatcher.Invoke(()=>SetBackupProgress(text)),cancellation.Token);
        try{Backend.RecordManualBackupSuccessForSchedule();}catch{}
        notice.Text="Copia completa terminada.";
      }catch(OperationCanceledException){notice.Text="Copia detenida. Los archivos ya copiados se conservan.";}
      catch(Exception ex){remoteError=ex.Message;notice.Text="La copia no se completó: "+ex.Message;}
      finally{cancellation.Dispose();backupCancellation=null;backupProgressText=null;busy=false;remoteOperation="";
        if(IsVisible&&(page=="Inicio"||page=="Protección"))await Render();}
    }
    async Task RunRemoteOperation(Func<Task> action) {
      try{await action();}
      catch(Exception ex){remoteError=ex.Message;notice.Text=ex.Message;}
      finally{busy=false;remoteOperation="";if(IsVisible)await Render();}
    }
    bool BeginSystemUpdate(bool automatic,bool remote) {
      if(busy||monitorBusy||updatingManager||backupCancellation!=null||SystemUpdates.IsBusy)return false;
      if(!SystemUpdates.TryBegin(prefs,automatic))return false;
      busy=true;remoteError="";remoteOperation="system-update";
      _=RunSystemUpdate(remote);return true;
    }
    async Task RunSystemUpdate(bool remote) {
      try {
        notice.Text="Actualizando Inhouse Photos. La operación continúa aunque cierres la app del móvil…";
        await Task.Run(()=>SystemUpdates.Apply(prefs,()=>Dispatcher.Invoke(()=>ApplyManagerHandoff(remote))));
        if(SystemUpdates.Status().Phase=="completed")notice.Text="Inhouse Photos "+Backend.Version+" actualizado.";
      }catch(Exception ex){remoteError=ex.Message;notice.Text=ex.Message;}
      finally{busy=false;remoteOperation="";if(IsVisible&&!updateClose)await Render();}
    }
    async Task ApplyManagerHandoff(bool remote) {
      if(RuntimeUpdates.IsBusy||backupCancellation!=null)throw new IOException("Espera a que termine la operación actual antes de actualizar.");
      updatingManager=true;
      try {
        var installer=await ManagerUpdates.Prepare();
        // Dispose the bridge before creating the installer so a dead listener
        // cannot survive in an inherited Windows socket handle.
        remoteManagement?.Dispose();remoteManagement=null;
        ManagerUpdates.StartHelper(installer,System.Diagnostics.Process.GetCurrentProcess().Id,remote||!IsVisible);
        updateClose=true;exitRequested=true;Close();
      }catch(Exception ex){ManagerUpdates.Fail(ex);throw;}
      finally{updatingManager=false;}
    }
    void RenderSystemUpdate() {
      Rule();content.Children.Add(Label("Inhouse Photos",22));
      var row=new StackPanel{Margin=new Thickness(0,2,0,8)};
      var version=Label("Comprobando la versión instalada…",16);
      var detail=Label("La actualización continúa en el ordenador aunque cierres el móvil.",14,muted);
      var bar=new ProgressBar{Minimum=0,Maximum=100,Height=4,Foreground=accent,Visibility=Visibility.Collapsed,Margin=new Thickness(0,0,0,9)};
      var update=new Button{Content="Actualizar Inhouse Photos",IsEnabled=false,HorizontalAlignment=HorizontalAlignment.Left};
      row.Children.Add(version);row.Children.Add(detail);row.Children.Add(bar);row.Children.Add(update);content.Children.Add(row);
      void Refresh() {
        var state=SystemUpdates.Status();
        version.Text=String.IsNullOrEmpty(state.CurrentVersion)?"Actualización pendiente":"Versión "+state.CurrentVersion;
        bar.Visibility=state.Busy?Visibility.Visible:Visibility.Collapsed;bar.Value=state.Progress;
        update.IsEnabled=state.Available&&!state.Busy&&!busy&&!monitorBusy&&!updatingManager&&backupCancellation==null;
        update.Content=state.Phase=="error"?"Reintentar actualización":"Actualizar Inhouse Photos";
        if(state.Phase=="downloading")detail.Text="Descargando Inhouse Photos · "+state.Progress+" %";
        else if(state.Phase=="waiting")detail.Text="Continuando la actualización guardada. Los originales y trabajos pendientes se conservan.";
        else if(state.Phase=="installing")detail.Text="Instalando la actualización verificada…";
        else if(state.Phase=="restarting")detail.Text="Reiniciando y comprobando Inhouse Photos…";
        else if(state.Phase=="verifying")detail.Text="Comprobando la actualización y la biblioteca…";
        else if(state.Phase=="error")detail.Text=state.Error;
        else if(state.CurrentVersion==state.LatestVersion)detail.Text="Inhouse Photos está actualizado.";
        else detail.Text=state.Notes;
      }
      update.Click+=async(sender,e)=>{
        update.IsEnabled=false;
        try{await SystemUpdates.Check(prefs,true);if(!BeginSystemUpdate(false,false))notice.Text="Espera a que termine la operación actual o comprueba Inhouse Photos en el ordenador.";}
        catch(Exception ex){detail.Text=ex.Message;}
        Refresh();
      };
      var timer=new DispatcherTimer{Interval=TimeSpan.FromSeconds(1)};
      timer.Tick+=(sender,e)=>{if(!content.Children.Contains(row)){timer.Stop();return;}Refresh();};timer.Start();
      _=RefreshInitially();
      async Task RefreshInitially(){try{await SystemUpdates.Check(prefs);if(content.Children.Contains(row))Refresh();}catch{if(content.Children.Contains(row))detail.Text="No se pudo comprobar Inhouse Photos. Comprueba el ordenador.";}}
    }
    Task RenderManagement() {
      RenderSystemUpdate();
      Rule();content.Children.Add(Label("Inicio automático",22));
      var startupRow=new Grid{Margin=new Thickness(0,4,0,4)};
      startupRow.ColumnDefinitions.Add(new ColumnDefinition());
      startupRow.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
      var startupDetails=new StackPanel{Margin=new Thickness(0,0,20,0)};
      var startupTitle=Label("Iniciar con Windows",17);startupTitle.FontWeight=FontWeights.SemiBold;startupTitle.Margin=new Thickness(0,0,0,4);
      startupDetails.Children.Add(startupTitle);
      startupDetails.Children.Add(Label("El gestor arranca en segundo plano al iniciar sesión. No necesitas abrir Docker; apagarlo no detiene el servidor ni una copia en curso.",14,muted));
      var startupState=Label("Comprobando el inicio automático…",13,muted);startupDetails.Children.Add(startupState);
      var retry=new Button{Content="Volver a comprobar",Visibility=Visibility.Collapsed,HorizontalAlignment=HorizontalAlignment.Left};startupDetails.Children.Add(retry);
      startupRow.Children.Add(startupDetails);
      var auto=new CheckBox{IsEnabled=false,Visibility=Visibility.Hidden,VerticalAlignment=VerticalAlignment.Center,Foreground=Foreground};
      AutomationProperties.SetName(auto,"Iniciar con Windows");Grid.SetColumn(auto,1);startupRow.Children.Add(auto);
      auto.Template=(ControlTemplate)XamlReader.Parse(@"<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='CheckBox'><StackPanel Orientation='Horizontal'><Border x:Name='track' Width='44' Height='26' CornerRadius='13' Background='#DCD5CB' Margin='0,0,12,0'><Ellipse x:Name='thumb' Width='20' Height='20' Fill='#FFFFFF' HorizontalAlignment='Left' Margin='3'/></Border><ContentPresenter VerticalAlignment='Center'/></StackPanel><ControlTemplate.Triggers><Trigger Property='IsChecked' Value='True'><Setter TargetName='track' Property='Background' Value='#A94712'/><Setter TargetName='thumb' Property='HorizontalAlignment' Value='Right'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.45'/></Trigger></ControlTemplate.Triggers></ControlTemplate>");
      content.Children.Add(startupRow);
      bool startupKnown=false,startupEnabled=false;
      async Task RefreshStartupState() {
        startupKnown=false;auto.IsEnabled=false;auto.Visibility=Visibility.Hidden;
        startupState.Text="Comprobando el inicio automático…";startupState.Visibility=Visibility.Visible;retry.Visibility=Visibility.Collapsed;
        try {
          var enabled=await Startup.IsEnabled();
          if(!content.Children.Contains(startupRow))return;
          startupEnabled=enabled;startupKnown=true;auto.IsChecked=enabled;
          auto.Visibility=Visibility.Visible;auto.IsEnabled=prefs.Managed;
          startupState.Visibility=Visibility.Collapsed;
        } catch(Exception ex) {
          if(!content.Children.Contains(startupRow))return;
          startupState.Text="No se pudo comprobar el inicio automático: "+ex.Message;
          retry.Visibility=Visibility.Visible;
        }
      }
      retry.Click+=async(s,e)=>await RefreshStartupState();
      auto.Click+=async(s,e)=>{
        if(busy||SystemUpdates.BlocksOperations(prefs)||RuntimeUpdates.BlocksOperations(prefs)||!startupKnown){auto.IsChecked=startupEnabled;notice.Text="Espera a que termine o se recupere la operación actual antes de cambiar el inicio automático.";return;}
        try {
          var enabled=auto.IsChecked==true;
          if(!enabled&&Backend.ReadBackupSchedule().Enabled&&
             !Confirm("La copia semanal está activada. Si el gestor no se inicia con Windows, solo podrá copiar cuando lo abras manualmente. ¿Desactivar el inicio automático?")){
            auto.IsChecked=startupEnabled;return;
          }
          busy=true;auto.IsEnabled=false;
          await Startup.SetEnabled(prefs,enabled);startupEnabled=enabled;
          notice.Text=enabled?"Inicio automático activado. El servidor se preparará al iniciar sesión.":"Inicio automático desactivado. El servidor actual no se ha detenido.";
        }
        catch(Exception ex){notice.Text=ex.Message;await RefreshStartupState();}
        finally{busy=false;auto.IsEnabled=startupKnown&&prefs.Managed&&content.Children.Contains(startupRow);}
      };
      // The Windows task query can take seconds; the Settings page stays usable
      // while the switch remains unavailable until its actual state is known.
      _=RefreshStartupState();
      Rule();RenderUsbConnection();
      Action("Ver conexión USB en la web  ↗",()=>{Open(Backend.CanonicalEndpoint(prefs.Endpoint)+"/descargas/servidor/");return Task.CompletedTask;});
      Rule();content.Children.Add(Label("Conexión del servidor",22));
      if(prefs.Managed&&File.Exists(prefs.ReceiptPath)) {
        var receipt=Backend.Json.Deserialize<AdoptionReceipt>(File.ReadAllText(prefs.ReceiptPath));
        var counts=receipt.Counts.Split('|');
        var connectionRow=new StackPanel{Margin=new Thickness(0,4,0,4)};
        var connectionTitle=Label("Biblioteca vinculada",17);connectionTitle.FontWeight=FontWeights.SemiBold;connectionTitle.Margin=new Thickness(0,0,0,4);connectionRow.Children.Add(connectionTitle);
        connectionRow.Children.Add(Label("Ya está conectada. No necesitas vincularla de nuevo.",14,muted));
        connectionRow.Children.Add(Label("Al vincularla se verificaron "+counts[0]+" fotos y vídeos, "+counts[1]+" cuentas y "+counts[2]+" álbumes. Esa instantánea no es una copia de las fotos.",14,muted));
        content.Children.Add(connectionRow);
        int detailsStart=content.Children.Count;
        Action("Abrir informe y copia de migración",()=>{Open(Path.GetDirectoryName(prefs.ReceiptPath));return Task.FromResult(0);});
        Action("Desvincular el gestor",async()=>{if(!Confirm("Se devolverá el inicio automático al sistema anterior. No se tocarán las fotos, la base de datos ni las cuentas. ¿Continuar?"))return;await Startup.ReleaseOwnership(prefs);notice.Text="Gestor desvinculado. El servidor y sus datos permanecen intactos.";await Render();});
        var details=new StackPanel();while(content.Children.Count>detailsStart){var child=content.Children[detailsStart];content.Children.RemoveAt(detailsStart);details.Children.Add(child);}
        content.Children.Add(new Expander{Header="Informe y recuperación",Content=details,Foreground=muted,Margin=new Thickness(0,4,0,8)});
      } else {
        var connectionRow=new StackPanel{Margin=new Thickness(0,4,0,4)};
        var connectionTitle=Label("Biblioteca pendiente de vincular",17);connectionTitle.FontWeight=FontWeights.SemiBold;connectionTitle.Margin=new Thickness(0,0,0,4);connectionRow.Children.Add(connectionTitle);
        connectionRow.Children.Add(Label("Antes de gestionar el arranque, comprobaremos la biblioteca y restauraremos una copia en una base de datos temporal aislada. No se detendrá el servidor original.",14,muted));
        content.Children.Add(connectionRow);
      }
      if(!prefs.Managed)Action("Preparar mi biblioteca",async()=>{page="Inicio";await Render();},true);
      return Task.FromResult(0);
    }
  }
}
