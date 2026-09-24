using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace InhousePhotos {
  public sealed partial class ServerWindow {
    async Task RenderSimpleHome() {
      Heading(prefs.Managed?"Tu biblioteca, en casa.":"Vamos a conectar tus fotos.",
        prefs.Managed?"Gestiona tu biblioteca sin cambiar tus fotos ni tus cuentas.":"Prepararemos el servidor que ya tienes en este ordenador.");
      if(!prefs.Managed) {
        content.Children.Add(Label(String.IsNullOrEmpty(prefs.Installation)?"Selecciona dónde está tu servidor":"Hemos encontrado tu servidor",24));
        content.Children.Add(Label("Conservaremos tus fotos, álbumes y usuarios. La comprobación inicial puede tardar varios minutos; verás cada paso aquí.",16,muted));
        if(String.IsNullOrEmpty(prefs.Installation))Action("Buscar mi servidor",async()=>{
          var folder=PickFolder();if(folder==null)return;
          if(!File.Exists(Path.Combine(folder,"docker-compose.yml")))throw new IOException("No encontramos un servidor en esa carpeta. Elige la carpeta de la instalación anterior.");
          prefs.Installation=folder;Backend.Save(prefs);await Render();
        });
        else Action("Preparar mi biblioteca",async()=>{
          var progress=new ProgressBar{IsIndeterminate=true,Height=4,Foreground=accent,Margin=new Thickness(0,20,0,12)};
          content.Children.Add(progress);
          try {
            await Backend.Adopt(prefs,text=>Dispatcher.Invoke(()=>notice.Text=text));
            await Backend.StartManaged(prefs,text=>Dispatcher.Invoke(()=>notice.Text=text));
            notice.Text="Listo. Tu biblioteca está conectada.";await Render();
          }finally{content.Children.Remove(progress);}
        },true);
        return;
      }
      var state=Label("Comprobando disponibilidad…",22,muted);content.Children.Add(state);
      var online=await Backend.Ping(prefs.LocalEndpoint);
      state.Text=online?"●  Tu biblioteca está disponible":"Tu servidor necesita arrancar";
      state.Foreground=online?new SolidColorBrush(Color.FromRgb(160,201,145)):accent;
      content.Children.Add(Label(online?"Puedes abrir tus fotos o conectar otro dispositivo.":"Prepararemos el motor en segundo plano. No tienes que abrir otros programas.",16,muted));
      if(online)Action("Abrir mis fotos  ↗",()=>{Open(Backend.CanonicalEndpoint(String.IsNullOrEmpty(prefs.Endpoint)?prefs.LocalEndpoint:prefs.Endpoint));return Task.FromResult(0);},true);
      else Action("Iniciar mi servidor",async()=>{await Backend.StartManaged(prefs,text=>Dispatcher.Invoke(()=>notice.Text=text));notice.Text="";await Render();},true);
      Rule();
      content.Children.Add(Label("Tus dispositivos",22));
      content.Children.Add(Label("Conecta el móvil usando tu cuenta habitual. No necesitas crear otra cuenta ni mover tus fotos.",16,muted));
      Action("Conectar un móvil  →",async()=>{page="Conectar";await Render();});
      Rule();
      content.Children.Add(Label("Todo permanece aquí",22));
      content.Children.Add(Label("Cerrar esta ventana no apaga el servidor. El inicio con Windows se configura en Ajustes.",16,muted));
      Action("Comprobar estado",async()=>{notice.Text="";await Render();});
    }
  }
}
