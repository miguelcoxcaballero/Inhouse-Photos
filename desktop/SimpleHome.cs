using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace InhousePhotos {
  public sealed partial class ServerWindow {
    Task RenderSimpleHome() {
      Heading("Vamos a conectar tus fotos.","Elige tu servidor actual. No moveremos fotos ni cambiaremos cuentas.");
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
        content.Children.Add(Label("Comprobaremos la base de datos en un entorno aislado antes de conectar el gestor. Esto no es una copia de tus fotos; el servidor seguirá encendido y todo permanecerá donde está.",16,muted));
        Action("Elegir otra carpeta",async()=>{
          var folder=PickFolder();if(folder==null)return;
          if(!File.Exists(Path.Combine(folder,"docker-compose.yml"))||!File.Exists(Path.Combine(folder,".env")))throw new IOException("Esa carpeta no contiene la configuración de un servidor compatible. No se ha cambiado nada.");
          prefs.Installation=folder;Backend.Save(prefs);await Render();
        });
        Rule();
        content.Children.Add(Label("Conexión segura en cinco pasos",20));
        var names=new[]{"Comprobar el servidor","Guardar la base de datos para la prueba","Probar recuperación aislada","Confirmar que nada cambió","Dejar la biblioteca lista"};
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
      return Task.CompletedTask;
    }
  }
}
