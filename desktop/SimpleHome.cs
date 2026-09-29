using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace InhousePhotos {
  public sealed partial class ServerWindow {
    StackPanel SetupCard(string number,string eyebrow,string title,string description,bool highlighted=false) {
      var row=new Grid{Margin=new Thickness(0,5,0,19)};
      row.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(40)});
      row.ColumnDefinitions.Add(new ColumnDefinition());
      row.Children.Add(new TextBlock{Text=number,Foreground=highlighted?accent:muted,FontSize=14,
        FontWeight=FontWeights.SemiBold,VerticalAlignment=VerticalAlignment.Top,Margin=new Thickness(0,3,0,0)});
      var body=new StackPanel();Grid.SetColumn(body,1);row.Children.Add(body);
      var caption=Label(eyebrow,12,muted);caption.FontWeight=FontWeights.SemiBold;caption.Margin=new Thickness(0,0,0,5);body.Children.Add(caption);
      var heading=Label(title,20);heading.FontWeight=FontWeights.SemiBold;heading.Margin=new Thickness(0,0,0,7);body.Children.Add(heading);
      var detail=Label(description,14,muted);detail.Margin=new Thickness(0,0,0,12);body.Children.Add(detail);
      content.Children.Add(row);
      content.Children.Add(new Border{Height=1,Background=divider,Margin=new Thickness(0,0,0,17)});
      return body;
    }

    Button SetupAction(StackPanel host,string title,Func<Task> task,bool primary=false) {
      var button=Action(title,task,primary);
      content.Children.Remove(button);
      button.Margin=new Thickness(0,5,8,3);
      host.Children.Add(button);
      return button;
    }

    Task RenderSimpleHome() {
      Heading("Tu biblioteca, en este PC.","Elige cómo empezar. Tus fotos y cuentas no se moverán al conectar un servidor existente.");
      if(String.IsNullOrEmpty(prefs.Installation)) {
        var existing=SetupCard("01","Ya tengo mis fotos aquí","Conectar mi servidor","Buscaremos la biblioteca que ya funciona en este ordenador. Podrás confirmar la carpeta antes de conectar nada.",true);
        var matchesPanel=new StackPanel();
        SetupAction(existing,"Buscar mi biblioteca",async()=>{
          matchesPanel.Children.Clear();
          var matches=await Backend.DiscoverExistingInstallations();
          if(matches.Count==1){prefs.Installation=matches[0];Backend.Save(prefs);await Render();notice.Text="Hemos encontrado tu biblioteca. Comprueba la carpeta y pulsa Conectar.";return;}
          if(matches.Count==0){notice.Text="No hemos podido encontrarla automáticamente. Elige la carpeta donde está tu servidor; no se modificará nada al seleccionarla.";return;}
          notice.Text="Hay varias bibliotecas en este PC. Elige cuál quieres conectar:";
          foreach(var folder in matches){var selected=folder;SetupAction(matchesPanel,"Usar "+selected,async()=>{prefs.Installation=selected;Backend.Save(prefs);await Render();});}
        },true);
        SetupAction(existing,"Elegir carpeta manualmente",async()=>{
          var folder=PickFolder();if(folder==null)return;
          if(!File.Exists(Path.Combine(folder,"docker-compose.yml"))||!File.Exists(Path.Combine(folder,".env")))throw new IOException("Esa carpeta no contiene la configuración de un servidor compatible. No se ha cambiado nada.");
          prefs.Installation=folder;Backend.Save(prefs);await Render();
        });
        existing.Children.Add(matchesPanel);

        var fresh=SetupCard("02","Empiezo de cero","Crear una biblioteca nueva","Te guiaremos para elegir dónde guardar las fotos y preparar un servidor nuevo. No modifica otra biblioteca existente.");
        SetupAction(fresh,File.Exists(NewServer.PendingFile)?"Continuar configuración":"Crear biblioteca nueva",async()=>{
          var wizard=new NewServerWindow{Owner=this};
          if(wizard.ShowDialog()==true){prefs=wizard.Result;notice.Text="Tu biblioteca está preparada.";await Render();}
        });
      } else {
        var found=SetupCard("01","Servidor existente","Biblioteca encontrada","Esta es la carpeta que vamos a comprobar. Puedes cambiarla antes de continuar.",true);
        var path=Label(prefs.Installation,15,accent);path.FontWeight=FontWeights.SemiBold;path.Margin=new Thickness(0,0,0,9);found.Children.Add(path);
        SetupAction(found,"Cambiar carpeta",async()=>{
          var folder=PickFolder();if(folder==null)return;
          if(!File.Exists(Path.Combine(folder,"docker-compose.yml"))||!File.Exists(Path.Combine(folder,".env")))throw new IOException("Esa carpeta no contiene la configuración de un servidor compatible. No se ha cambiado nada.");
          prefs.Installation=folder;Backend.Save(prefs);await Render();
        });
        var body=SetupCard("02","Antes de conectar","Una comprobación en 5 pasos","Probamos una copia de la base de datos en un entorno aislado. El servidor seguirá encendido y las fotos permanecerán en su sitio.");
        var names=new[]{"Comprobar el servidor","Guardar la base de datos para la prueba","Probar recuperación aislada","Confirmar que nada cambió","Conectar el gestor"};
        var markers=new TextBlock[names.Length];var labels=new TextBlock[names.Length];
        for(var i=0;i<names.Length;i++){
          var step=new Grid{Margin=new Thickness(0,1,0,6)};step.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(28)});step.ColumnDefinitions.Add(new ColumnDefinition());
          markers[i]=new TextBlock{Text=(i+1).ToString(),FontSize=13,Foreground=muted,FontWeight=FontWeights.SemiBold,VerticalAlignment=VerticalAlignment.Center};step.Children.Add(markers[i]);
          labels[i]=new TextBlock{Text=names[i],FontSize=14,Foreground=muted,TextWrapping=TextWrapping.Wrap};Grid.SetColumn(labels[i],1);step.Children.Add(labels[i]);body.Children.Add(step);
        }
        var status=Label("Lista para comprobar. Puedes seguir usando tus fotos.",14,muted);status.Margin=new Thickness(0,7,0,4);body.Children.Add(status);
        var progress=new ProgressBar{Minimum=0,Maximum=5,Value=0,Height=5,Foreground=accent,Margin=new Thickness(0,5,0,13),Visibility=Visibility.Collapsed};body.Children.Add(progress);
        SetupAction(body,"Conectar esta biblioteca",async()=>{
          progress.Visibility=Visibility.Visible;
          Action<int,string> milestone=(index,message)=>Dispatcher.Invoke(()=>{
            for(var i=0;i<labels.Length;i++){
              markers[i].Text=i<index?"✓":i==index?"●":(i+1).ToString();
              markers[i].Foreground=i<=index?accent:muted;
              labels[i].Foreground=i<=index?Foreground:muted;
            }
            progress.Value=index;
            status.Text="Paso "+(index+1)+" de 5 · "+message;
            notice.Text=message;
          });
          try {
            await Backend.Adopt(prefs,text=>Dispatcher.Invoke(()=>status.Text=text),true,milestone);
            status.Text="Comprobación terminada. Iniciando tu biblioteca si hace falta…";
            await Backend.StartManaged(prefs,text=>Dispatcher.Invoke(()=>status.Text=text));
            progress.Value=5;progress.Visibility=Visibility.Collapsed;
            await Render();notice.Text="Listo. Tus fotos y cuentas siguen en el mismo sitio.";
          }catch(Exception ex){
            progress.Visibility=Visibility.Collapsed;
            status.Text="No se ha completado la conexión. Puedes reintentarlo.";
            if(prefs.Managed){await Render();notice.Text="La biblioteca se verificó, pero no respondió al iniciarla: "+ex.Message;}
            else notice.Text="No hemos cambiado tus fotos ni cuentas. "+ex.Message;
          }
        },true);
        var safety=Label("Esta verificación comprueba la base de datos; no es una copia completa de tus fotos y vídeos.",13,muted);
        safety.Margin=new Thickness(0,11,0,0);body.Children.Add(safety);

        var fresh=SetupCard("03","Otra opción","Crear una biblioteca nueva","Solo si prefieres empezar de cero. Tu biblioteca encontrada no se sustituirá desde esta pantalla.");
        SetupAction(fresh,File.Exists(NewServer.PendingFile)?"Continuar configuración nueva":"Configurar servidor nuevo",async()=>{
          var wizard=new NewServerWindow{Owner=this};
          if(wizard.ShowDialog()==true){prefs=wizard.Result;notice.Text="Tu biblioteca está preparada.";await Render();}
        });
      }
      return Task.CompletedTask;
    }
  }
}
