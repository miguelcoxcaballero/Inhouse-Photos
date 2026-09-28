using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace InhousePhotos {
  public sealed partial class ServerWindow {
    async Task RenderSimpleHome() {
      Heading(prefs.Managed?"Tu biblioteca, en casa.":"Vamos a conectar tus fotos.",
        prefs.Managed?"Gestiona tu biblioteca sin cambiar tus fotos ni tus cuentas.":"Elige tu servidor actual. No moveremos fotos ni cambiaremos cuentas.");
      if(!prefs.Managed) {
        if(String.IsNullOrEmpty(prefs.Installation)) {
          content.Children.Add(Label("¿Ya tienes un servidor de fotos en este PC?",24));
          content.Children.Add(Label("Lo buscaremos entre los servidores activos. También puedes elegir su carpeta; no necesitas saber nada de Docker.",16,muted));
          var matchesPanel=new StackPanel();
          Action("Buscar mi biblioteca",async()=>{
            matchesPanel.Children.Clear();
            var matches=await Backend.DiscoverExistingInstallations();
            if(matches.Count==1){prefs.Installation=matches[0];Backend.Save(prefs);await Render();notice.Text="Hemos encontrado tu biblioteca. Comprueba la carpeta y pulsa Conectar.";return;}
            if(matches.Count==0){notice.Text="No hemos podido encontrarla automáticamente. Elige la carpeta donde está tu servidor; no se modificará nada al seleccionarla.";return;}
            notice.Text="Hay varias bibliotecas en este PC. Elige cuál quieres conectar:";
            foreach(var folder in matches){var selected=folder;var choice=Action("Usar "+selected,async()=>{prefs.Installation=selected;Backend.Save(prefs);await Render();});content.Children.Remove(choice);matchesPanel.Children.Add(choice);}
          },true);
          content.Children.Add(matchesPanel);
          Action("Elegir la carpeta manualmente",async()=>{
            var folder=PickFolder();if(folder==null)return;
            if(!File.Exists(Path.Combine(folder,"docker-compose.yml"))||!File.Exists(Path.Combine(folder,".env")))throw new IOException("Esa carpeta no contiene la configuración de un servidor compatible. No se ha cambiado nada.");
            prefs.Installation=folder;Backend.Save(prefs);await Render();
          });
        } else {
          content.Children.Add(Label("Biblioteca encontrada",24));
          content.Children.Add(Label(prefs.Installation,15,accent));
          content.Children.Add(Label("Comprobaremos una copia de recuperación antes de conectar el gestor. Tu servidor seguirá encendido y las fotos permanecerán donde están.",16,muted));
          Action("Elegir otra carpeta",async()=>{
            var folder=PickFolder();if(folder==null)return;
            if(!File.Exists(Path.Combine(folder,"docker-compose.yml"))||!File.Exists(Path.Combine(folder,".env")))throw new IOException("Esa carpeta no contiene la configuración de un servidor compatible. No se ha cambiado nada.");
            prefs.Installation=folder;Backend.Save(prefs);await Render();
          });
          Rule();
          content.Children.Add(Label("Conexión segura en cinco pasos",20));
          var names=new[]{"Comprobar el servidor","Guardar copia de verificación","Probar recuperación aislada","Confirmar que nada cambió","Dejar la biblioteca lista"};
          var steps=names.Select((name,index)=>Label((index+1)+"  "+name,15,muted)).ToArray();
          foreach(var step in steps)content.Children.Add(step);
          var status=Label("Puedes seguir usando tus fotos durante esta comprobación.",15,muted);content.Children.Add(status);
          var progress=new ProgressBar{IsIndeterminate=true,Height=4,Foreground=accent,Margin=new Thickness(0,10,0,14),Visibility=Visibility.Collapsed};content.Children.Add(progress);
          Action("Conectar biblioteca existente",async()=>{
            progress.Visibility=Visibility.Visible;
            Action<int,string> milestone=(index,message)=>Dispatcher.Invoke(()=>{
              for(var i=0;i<steps.Length;i++){steps[i].Text=(i<index?"✓  ":i==index?"●  ":"○  ")+names[i];steps[i].Foreground=i<=index?accent:muted;}
              status.Text=message;notice.Text=message;
            });
            try {
              await Backend.Adopt(prefs,text=>Dispatcher.Invoke(()=>status.Text=text),true,milestone);
              status.Text="Comprobación terminada. Iniciando tu biblioteca si hace falta…";
              await Backend.StartManaged(prefs,text=>Dispatcher.Invoke(()=>status.Text=text));
              progress.Visibility=Visibility.Collapsed;
              await Render();notice.Text="Listo. Tus fotos y cuentas siguen en el mismo sitio.";
            }catch(Exception ex){
              progress.Visibility=Visibility.Collapsed;
              status.Text="No se ha completado la conexión. Puedes reintentarlo.";
              if(prefs.Managed){await Render();notice.Text="La biblioteca se verificó, pero no respondió al iniciarla: "+ex.Message;}
              else notice.Text="No hemos cambiado tus fotos ni cuentas. "+ex.Message;
            }
          },true);
        }
        Rule();
        Action(File.Exists(NewServer.PendingFile)?"Continuar biblioteca nueva":"Crear una biblioteca nueva",async()=>{var wizard=new NewServerWindow{Owner=this};if(wizard.ShowDialog()==true){prefs=wizard.Result;notice.Text="Tu biblioteca está preparada.";await Render();}},String.IsNullOrEmpty(prefs.Installation));
        return;
      }
      var state=Label("Comprobando disponibilidad…",22,muted);content.Children.Add(state);
      var online=await Backend.Ping(prefs.LocalEndpoint);
      var verified=true;
      if(online)try{
        Backend.ValidateManagedConfiguration(prefs);
        var receipt=Backend.Json.Deserialize<AdoptionReceipt>(File.ReadAllText(prefs.ReceiptPath));
        Backend.AssertIdentity(receipt.Containers,await Backend.InspectServer(prefs));
      }catch{verified=false;}
      state.Text=online?(verified?"●  Tu biblioteca está disponible":"Tu biblioteca funciona; hay que renovar la verificación"):"Tu servidor necesita arrancar";
      state.Foreground=online&&verified?new SolidColorBrush(Color.FromRgb(160,201,145)):accent;
      content.Children.Add(Label(online?"Puedes abrir tus fotos o conectar otro dispositivo.":"Prepararemos el motor en segundo plano. No tienes que abrir otros programas.",16,muted));
      if(online)Action("Abrir mis fotos  ↗",()=>{Open(Backend.CanonicalEndpoint(String.IsNullOrEmpty(prefs.Endpoint)?prefs.LocalEndpoint:prefs.Endpoint));return Task.FromResult(0);},true);
      else Action("Iniciar mi servidor",async()=>{await Backend.StartManaged(prefs,text=>Dispatcher.Invoke(()=>notice.Text=text));notice.Text="";await Render();},true);
      if(online&&!verified){
        content.Children.Add(Label("El servidor o su configuración cambió desde la última comprobación. Tus fotos siguen disponibles; antes de gestionar el arranque, verificaremos de nuevo una copia recuperable.",16,muted));
        var status=Label("No se moverán ni borrarán fotos.",15,muted);content.Children.Add(status);
        var progress=new ProgressBar{IsIndeterminate=true,Height=4,Foreground=accent,Margin=new Thickness(0,8,0,12),Visibility=Visibility.Collapsed};content.Children.Add(progress);
        Action("Volver a verificar este servidor",async()=>{
          progress.Visibility=Visibility.Visible;
          try{
            await Backend.ReverifyExisting(prefs,text=>Dispatcher.Invoke(()=>status.Text=text),(step,text)=>Dispatcher.Invoke(()=>{status.Text=(step+1)+" de 5 · "+text;notice.Text=text;}));
            progress.Visibility=Visibility.Collapsed;await Render();notice.Text="Vinculación renovada. La biblioteca y las cuentas no han cambiado.";
          }catch(Exception ex){progress.Visibility=Visibility.Collapsed;status.Text="No se ha completado la verificación. La vinculación anterior se conserva.";notice.Text=ex.Message;}
        },true);
      }
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
