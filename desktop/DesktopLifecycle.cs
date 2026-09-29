using System;
using System.IO;
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
    RemoteManagement remoteManagement;
    bool monitorBusy, exitRequested, updateClose, updatingManager;
    DateTime retryAfter=DateTime.MinValue;
    internal void InitializeLifecycle(bool hidden) {
      tray=new Forms.NotifyIcon{Text="Inhouse Photos Server",Icon=System.Drawing.Icon.ExtractAssociatedIcon(typeof(ServerWindow).Assembly.Location),Visible=true};
      var menu=new Forms.ContextMenuStrip();menu.Items.Add("Abrir Inhouse Photos",null,(s,e)=>Dispatcher.Invoke(BringToFront));
      menu.Items.Add("Salir del gestor",null,(s,e)=>Dispatcher.Invoke(()=>{if(busy){notice.Text="Espera a que termine la operación antes de salir.";return;}exitRequested=true;Close();}));
      tray.ContextMenuStrip=menu;tray.DoubleClick+=(s,e)=>Dispatcher.Invoke(BringToFront);
      Closing+=(s,e)=>{if((busy||monitorBusy)&&!updateClose){e.Cancel=true;notice.Text="Espera a que termine la operación antes de salir.";return;}if(!exitRequested){e.Cancel=true;Hide();}};
      Closed+=(s,e)=>{if(monitor!=null)monitor.Stop();remoteManagement?.Dispose();tray.Dispose();};
      monitor=new DispatcherTimer{Interval=TimeSpan.FromSeconds(45)};
      monitor.Tick+=async(s,e)=>await Supervise();monitor.Start();
      if(hidden)Dispatcher.BeginInvoke(new Action(async()=>await Supervise()));
    }
    internal void BringToFront(){Show();WindowState=WindowState.Normal;Activate();}
    async Task Supervise() {
      if(busy||monitorBusy||!prefs.Managed||DateTime.UtcNow<retryAfter)return;
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
          try {await LanRoute.Publish(prefs);} catch { /* Public HTTPS remains available if LAN discovery cannot be published. */ }
          try {
            if(remoteManagement==null)remoteManagement=new RemoteManagement(prefs,
              ()=>Dispatcher.Invoke(()=>!busy&&!monitorBusy&&!updatingManager&&backupCancellation==null),
              ()=>Dispatcher.BeginInvoke(new Action(async()=>await ApplyManagerUpdate(true))));
            await remoteManagement.EnsurePublished();
          }catch(Exception ex){notice.Text="Actualizaciones remotas no disponibles: "+ex.Message;}
          try {
            var update=await ManagerUpdates.Check();
            if(update.Available&&String.IsNullOrWhiteSpace(notice.Text))notice.Text="Nueva versión del gestor: "+update.LatestVersion+". Abre Ajustes para actualizar.";
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
    async Task ApplyManagerUpdate(bool remote) {
      if(updatingManager||backupCancellation!=null||busy||monitorBusy) {
        if(remote)ManagerUpdates.Fail(new IOException("El PC está ocupado. Vuelve a intentarlo en unos segundos."));
        else notice.Text="Espera a que termine la operación actual y vuelve a intentarlo.";
        return;
      }
      if(!remote&&!ManagerUpdates.TryBegin())return;
      updatingManager=true;
      try {
        notice.Text="Descargando y comprobando la actualización del gestor…";
        var installer=await ManagerUpdates.Prepare();
        ManagerUpdates.StartHelper(installer,System.Diagnostics.Process.GetCurrentProcess().Id,remote||!IsVisible);
        // The verified setup waits for this process to close. It changes only
        // the per-user manager pointer; Docker and Caddy keep serving photos.
        updateClose=true;exitRequested=true;Close();
      }catch(Exception ex){ManagerUpdates.Fail(ex);notice.Text="No se instaló la actualización: "+ex.Message;}
      finally{updatingManager=false;}
    }
    Task RenderManagement() {
      Rule();content.Children.Add(Label("Actualizaciones del gestor",22));
      var updateRow=new StackPanel{Margin=new Thickness(0,2,0,8)};
      var updateVersion=Label("Versión instalada "+Backend.Version,16);updateVersion.FontWeight=FontWeights.SemiBold;
      updateVersion.Margin=new Thickness(0,0,0,3);updateRow.Children.Add(updateVersion);
      var updateDetail=Label("Buscando actualizaciones…",14,muted);updateDetail.Margin=new Thickness(0,0,0,8);updateRow.Children.Add(updateDetail);
      var updateProgress=new ProgressBar{Minimum=0,Maximum=100,Height=4,Foreground=accent,Visibility=Visibility.Collapsed,Margin=new Thickness(0,0,0,9)};
      updateRow.Children.Add(updateProgress);
      var updateActions=new StackPanel{Orientation=Orientation.Horizontal};
      var installUpdate=new Button{Content="Actualizar el gestor",IsEnabled=false,Visibility=Visibility.Collapsed};
      var checkUpdate=new Button{Content="Buscar actualizaciones"};
      updateActions.Children.Add(installUpdate);updateActions.Children.Add(checkUpdate);updateRow.Children.Add(updateActions);
      content.Children.Add(updateRow);
      async Task RefreshUpdate(bool force) {
        checkUpdate.IsEnabled=false;
        updateDetail.Text="Comprobando la última versión…";
        try {
          var state=await ManagerUpdates.Check(force);
          if(!content.Children.Contains(updateRow))return;
          updateDetail.Text=state.Available?"Versión "+state.LatestVersion+" disponible. "+state.Notes:
            "Tu gestor está al día. Las fotos y el servidor se actualizan por separado.";
          installUpdate.Visibility=state.Available?Visibility.Visible:Visibility.Collapsed;
          installUpdate.IsEnabled=state.Available&&!updatingManager;
        }catch(Exception ex){if(content.Children.Contains(updateRow))updateDetail.Text="No se pudo comprobar ahora: "+ex.Message;}
        finally{if(content.Children.Contains(updateRow))checkUpdate.IsEnabled=true;}
      }
      checkUpdate.Click+=async(s,e)=>await RefreshUpdate(true);
      installUpdate.Click+=async(s,e)=>{
        if(updatingManager||busy||backupCancellation!=null)return;
        if(!Confirm("Se instalará solo la nueva versión del gestor y se volverá a abrir. El servidor de fotos, las subidas y tus datos seguirán funcionando. ¿Actualizar ahora?"))return;
        installUpdate.IsEnabled=false;checkUpdate.IsEnabled=false;
        await ApplyManagerUpdate(false);
        if(content.Children.Contains(updateRow)){checkUpdate.IsEnabled=true;await RefreshUpdate(false);}
      };
      var updateTimer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(400)};
      updateTimer.Tick+=(s,e)=>{
        if(!content.Children.Contains(updateRow)){updateTimer.Stop();return;}
        var state=ManagerUpdates.Status();
        if(state.Phase=="downloading"||state.Phase=="verifying"||state.Phase=="installing") {
          updateProgress.Visibility=Visibility.Visible;updateProgress.Value=state.Progress;
          updateDetail.Text=state.Phase=="downloading"?"Descargando · "+state.Progress+" %":
            state.Phase=="verifying"?"Comprobando el instalador…":"Abriendo la nueva versión…";
        }else if(state.Phase=="error"){
          updateProgress.Visibility=Visibility.Collapsed;updateDetail.Text="No se instaló: "+state.Error;
        }
      };updateTimer.Start();
      _=RefreshUpdate(false);
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
        if(busy||!startupKnown){auto.IsChecked=startupEnabled;if(busy)notice.Text="Espera a que termine la operación antes de cambiar el inicio automático.";return;}
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
