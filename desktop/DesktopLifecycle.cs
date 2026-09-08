using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Forms=System.Windows.Forms;

namespace InhousePhotos {
  public sealed partial class ServerWindow {
    Forms.NotifyIcon tray;
    DispatcherTimer monitor;
    bool monitorBusy, exitRequested;
    DateTime retryAfter=DateTime.MinValue;
    internal void InitializeLifecycle(bool hidden) {
      tray=new Forms.NotifyIcon{Text="Inhouse Photos Server",Icon=System.Drawing.Icon.ExtractAssociatedIcon(typeof(ServerWindow).Assembly.Location),Visible=true};
      var menu=new Forms.ContextMenuStrip();menu.Items.Add("Abrir Inhouse Photos",null,(s,e)=>Dispatcher.Invoke(BringToFront));
      menu.Items.Add("Salir del gestor",null,(s,e)=>Dispatcher.Invoke(()=>{if(busy){notice.Text="Espera a que termine la operación antes de salir.";return;}exitRequested=true;Close();}));
      tray.ContextMenuStrip=menu;tray.DoubleClick+=(s,e)=>Dispatcher.Invoke(BringToFront);
      Closing+=(s,e)=>{if(busy||monitorBusy){e.Cancel=true;notice.Text="Espera a que termine la operación antes de salir.";return;}if(!exitRequested){e.Cancel=true;Hide();}};
      Closed+=(s,e)=>{if(monitor!=null)monitor.Stop();tray.Dispose();};
      monitor=new DispatcherTimer{Interval=TimeSpan.FromSeconds(45)};
      monitor.Tick+=async(s,e)=>await Supervise();monitor.Start();
      if(hidden)Dispatcher.BeginInvoke(new Action(async()=>await Supervise()));
    }
    internal void BringToFront(){Show();WindowState=WindowState.Normal;Activate();}
    async Task Supervise() {
      if(busy||monitorBusy||!prefs.Managed||DateTime.UtcNow<retryAfter)return;
      monitorBusy=true;
      try {
        if(!await Startup.IsEnabled())return;
        if(!await Backend.Ping(prefs.LocalEndpoint)) {
          await Backend.StartManaged(prefs,text=>Dispatcher.Invoke(()=>notice.Text=text));
          notice.Text="Servidor disponible.";
        }
        retryAfter=DateTime.UtcNow.AddSeconds(45);
      }catch(Exception ex){notice.Text=ex.Message;retryAfter=DateTime.UtcNow.AddMinutes(2);}
      finally{monitorBusy=false;}
    }
    async Task RenderManagement() {
      Rule();content.Children.Add(Label("Inicio automático",22));
      var auto=new CheckBox{Content="Iniciar con Windows",IsChecked=await Startup.IsEnabled(),Foreground=Foreground,FontSize=17,Margin=new Thickness(0,8,0,10)};
      auto.Click+=async(s,e)=>{
        if(busy){auto.IsChecked=await Startup.IsEnabled();return;}
        busy=true;auto.IsEnabled=false;
        try {await Startup.SetEnabled(prefs,auto.IsChecked==true);notice.Text=auto.IsChecked==true?"Inicio automático activado. El servidor se preparará al iniciar sesión.":"Inicio automático desactivado. El servidor actual no se ha detenido.";}
        catch(Exception ex){notice.Text=ex.Message;auto.IsChecked=await Startup.IsEnabled();}
        finally{busy=false;auto.IsEnabled=true;}
      };content.Children.Add(auto);
      content.Children.Add(Label("Arranca en segundo plano al iniciar sesión en tu cuenta de Windows. No es necesario abrir Docker. Apagar este interruptor no detiene una copia en curso ni el servidor.",14,muted));
      Rule();content.Children.Add(Label("Vinculación segura",22));
      if(prefs.Managed&&File.Exists(prefs.ReceiptPath)) {
        var receipt=Backend.Json.Deserialize<AdoptionReceipt>(File.ReadAllText(prefs.ReceiptPath));
        var counts=receipt.Counts.Split('|');content.Children.Add(Label("Comprobación de restauración superada",17,accent));
        content.Children.Add(Label(counts[0]+" fotos y vídeos · "+counts[1]+" cuentas · "+counts[2]+" álbumes en la instantánea",14,muted));
        content.Children.Add(Label("La biblioteca no se ha movido. Se conserva la configuración anterior, cifrada para tu cuenta, junto a una instantánea verificada.",14,muted));
        Action("Abrir informe y copia de migración",()=>{Open(Path.GetDirectoryName(prefs.ReceiptPath));return Task.FromResult(0);});
        Action("Desvincular el gestor",async()=>{if(!Confirm("Se devolverá el inicio automático al sistema anterior. No se tocarán las fotos, la base de datos ni las cuentas. ¿Continuar?"))return;await Startup.ReleaseOwnership(prefs);notice.Text="Gestor desvinculado. El servidor y sus datos permanecen intactos.";await Render();});
      } else content.Children.Add(Label("Antes de gestionar el arranque, comprobaremos tu biblioteca y restauraremos una copia en una base de datos temporal aislada. No se detendrá el servidor original.",15,muted));
      Action(prefs.Managed?"Volver a verificar la instalación":"Vincular y verificar mi servidor",async()=>{await Backend.Adopt(prefs,text=>Dispatcher.Invoke(()=>notice.Text=text));await Render();},!prefs.Managed);
    }
  }
}
