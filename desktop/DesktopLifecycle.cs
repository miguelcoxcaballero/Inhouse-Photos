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
    bool lanPublishBusy,publicDownloadsBusy;
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
      monitor.Tick+=async(s,e)=>{_=RefreshPublicDownloads();await Supervise();};monitor.Start();
      // Repair stale public downloads independently of a pending engine update.
      // The publisher validates the existing route and never changes its config.
      _=RefreshPublicDownloads(true);
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
    async Task RefreshPublicDownloads(bool force=false) {
      if(publicDownloadsBusy||exitRequested||!prefs.Managed)return;
      publicDownloadsBusy=true;
      try{await Task.Run(()=>PublicDownloads.Publish(prefs,force));}
      catch{ /* A pending engine operation must not keep the download page stale. */ }
      finally{publicDownloadsBusy=false;}
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
      var progressTimer=new DispatcherTimer{Interval=TimeSpan.FromSeconds(1)};
      progressTimer.Tick+=(sender,e)=>{
        var state=SystemUpdates.Status();var detail=ProductInstallation.StageMessage(state.Stage);
        if(state.Busy&&detail!=null)notice.Text=detail;
        else if(state.Busy&&state.Phase=="downloading")notice.Text="Descargando Inhouse Photos · "+state.Progress+" %";
      };
      progressTimer.Start();
      try {
        notice.Text="Actualizando Inhouse Photos. La operación continúa aunque cierres la app del móvil…";
        await Task.Run(()=>SystemUpdates.Apply(prefs,()=>Dispatcher.Invoke(()=>ApplyManagerHandoff(remote))));
        if(SystemUpdates.Status().Phase=="completed")notice.Text="Inhouse Photos "+Backend.Version+" actualizado.";
      }catch(Exception ex){remoteError=ex.Message;notice.Text=ex.Message;}
      finally{progressTimer.Stop();busy=false;remoteOperation="";if(IsVisible&&!updateClose)await Render();}
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
      Section("Actualizaciones");
      var parts=Ui.ListRow("refresh","Comprobando la versión instalada…","La actualización continúa en el ordenador aunque cierres el móvil.");
      var row=parts.Root;var version=parts.Heading;var detail=parts.Detail;
      var bar=new ProgressBar{Minimum=0,Maximum=100};
      AutomationProperties.SetName(bar,"Progreso de la actualización");
      var barMeasure=Ui.Constrain(bar,320);barMeasure.Margin=new Thickness(0,10,0,2);barMeasure.Visibility=Visibility.Collapsed;parts.Body.Children.Add(barMeasure);
      var update=Ui.Button("Actualizar Inhouse Photos");update.IsEnabled=false;update.Margin=new Thickness(0);parts.Trailing.Children.Add(update);
      content.Children.Add(row);
      void Refresh() {
        var state=SystemUpdates.Status();
        version.Text=String.IsNullOrEmpty(state.CurrentVersion)?"Actualización pendiente":"Inhouse Photos "+state.CurrentVersion;
        barMeasure.Visibility=state.Busy?Visibility.Visible:Visibility.Collapsed;bar.Value=state.Progress;
        update.IsEnabled=state.Available&&!state.Busy&&!busy&&!monitorBusy&&!updatingManager&&backupCancellation==null;
        Ui.SetCaption(update,state.Phase=="error"?"Reintentar actualización":"Actualizar Inhouse Photos");
        if(state.Phase=="downloading")detail.Text="Descargando Inhouse Photos · "+state.Progress+" %";
        else if(state.Phase=="waiting")detail.Text="Continuando la actualización guardada. Los originales y trabajos pendientes se conservan.";
        else if(state.Phase=="installing")detail.Text="Instalando la actualización verificada…";
        else if(state.Phase=="restarting")detail.Text="Reiniciando y comprobando Inhouse Photos…";
        else if(state.Phase=="verifying")detail.Text="Comprobando la actualización y la biblioteca…";
        else if(state.Phase=="error")detail.Text=state.Error;
        else if(state.CurrentVersion==state.LatestVersion)detail.Text="Inhouse Photos está actualizado.";
        else detail.Text=state.Notes;
        var stageDetail=ProductInstallation.StageMessage(state.Stage);
        if(state.Busy&&stageDetail!=null)detail.Text=stageDetail;
        detail.Foreground=state.Phase=="error"?accent:Ui.Ink2;
        detail.Visibility=String.IsNullOrWhiteSpace(detail.Text)?Visibility.Collapsed:Visibility.Visible;
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
      Section("Inicio automático");
      var parts=Ui.ListRow("power","Iniciar con Windows","El gestor arranca en segundo plano al iniciar sesión. Apagarlo no detiene el servidor ni una copia en curso.");
      var startupRow=parts.Root;
      var startupState=Ui.Caption("Comprobando el inicio automático…");startupState.Margin=new Thickness(0,6,0,0);parts.Body.Children.Add(startupState);
      var retry=Ui.Button("Volver a comprobar","Link");retry.Visibility=Visibility.Collapsed;retry.Margin=new Thickness(0,6,0,0);parts.Body.Children.Add(retry);
      var auto=new CheckBox{IsEnabled=false,Visibility=Visibility.Hidden,VerticalAlignment=VerticalAlignment.Center,Style=Ui.StyleOf("Switch")};
      AutomationProperties.SetName(auto,"Iniciar con Windows");parts.Trailing.Children.Add(auto);
      content.Children.Add(startupRow);
      bool startupKnown=false,startupEnabled=false;
      async Task RefreshStartupState() {
        startupKnown=false;auto.IsEnabled=false;auto.Visibility=Visibility.Hidden;
        startupState.Text="Comprobando el inicio automático…";startupState.Foreground=Ui.Ink3;startupState.Visibility=Visibility.Visible;retry.Visibility=Visibility.Collapsed;
        try {
          var enabled=await Startup.IsEnabled();
          if(!content.Children.Contains(startupRow))return;
          startupEnabled=enabled;startupKnown=true;auto.IsChecked=enabled;
          auto.Visibility=Visibility.Visible;auto.IsEnabled=prefs.Managed;
          startupState.Visibility=Visibility.Collapsed;
        } catch(Exception ex) {
          if(!content.Children.Contains(startupRow))return;
          startupState.Text="No se pudo comprobar el inicio automático: "+ex.Message;startupState.Foreground=accent;
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
      RenderUsbConnection();
      var web=Action("Ver conexión USB en la web",()=>{Open(Backend.CanonicalEndpoint(prefs.Endpoint)+"/descargas/servidor/");return Task.CompletedTask;},false,"external");
      Ui.SetStyle(web,"Link");web.Margin=new Thickness(40,0,0,0);
      Section("Biblioteca");
      if(prefs.Managed&&File.Exists(prefs.ReceiptPath)) {
        var receipt=Backend.Json.Deserialize<AdoptionReceipt>(File.ReadAllText(prefs.ReceiptPath));
        var counts=receipt.Counts.Split('|');
        var linked=Ui.ListRow("photo","Biblioteca vinculada","Al vincularla se verificaron "+counts[0]+" fotos y vídeos, "+counts[1]+" cuentas y "+counts[2]+" álbumes. Esa instantánea no es una copia de las fotos.");
        content.Children.Add(linked.Root);
        int detailsStart=content.Children.Count;
        Action("Abrir informe y copia de migración",()=>{Open(Path.GetDirectoryName(prefs.ReceiptPath));return Task.FromResult(0);});
        Action("Desvincular el gestor",async()=>{if(!Confirm("Se devolverá el inicio automático al sistema anterior. No se tocarán las fotos, la base de datos ni las cuentas. ¿Continuar?"))return;await Startup.ReleaseOwnership(prefs);notice.Text="Gestor desvinculado. El servidor y sus datos permanecen intactos.";await Render();});
        var details=new StackPanel();
        details.Children.Add(Ui.Secondary("Abre el informe de verificación o devuelve el arranque al sistema anterior. Ninguna opción toca fotos, base de datos ni cuentas."));
        var detailActions=new StackPanel{Orientation=Orientation.Horizontal,Margin=new Thickness(0,12,0,0)};details.Children.Add(detailActions);
        while(content.Children.Count>detailsStart){var child=content.Children[detailsStart];content.Children.RemoveAt(detailsStart);((FrameworkElement)child).Margin=new Thickness(0,0,8,0);detailActions.Children.Add(child);}
        content.Children.Add(new Expander{Header="Informe y recuperación",Content=details,Margin=new Thickness(0,8,0,0)});
      } else {
        var pending=Ui.ListRow("photo","Biblioteca pendiente de vincular","Antes de gestionar el arranque, comprobaremos la biblioteca y restauraremos una copia en una base de datos temporal aislada. No se detendrá el servidor original.");
        content.Children.Add(pending.Root);
      }
      if(!prefs.Managed)Action("Preparar mi biblioteca",async()=>{page="Inicio";await Render();},true);
      return Task.FromResult(0);
    }
  }
}
