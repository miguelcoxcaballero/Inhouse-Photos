using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace InhousePhotos {
  public sealed partial class ServerWindow {
    // One option of the first-run choice: icon, title, one sentence, actions.
    StackPanel SetupCard(string icon,string title,string description,bool first=false) {
      if(!first)content.Children.Add(Ui.Divider(new Thickness(0,28,0,28)));
      var row=new Grid();
      row.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(40)});
      row.ColumnDefinitions.Add(new ColumnDefinition());
      var glyph=Ui.Icon(icon,22,Ui.Ink2);glyph.VerticalAlignment=VerticalAlignment.Top;glyph.HorizontalAlignment=HorizontalAlignment.Left;glyph.Margin=new Thickness(0,0,0,0);row.Children.Add(glyph);
      var body=new StackPanel();Grid.SetColumn(body,1);row.Children.Add(body);
      body.Children.Add(Ui.Subtitle(title));
      var detail=Ui.Secondary(description);detail.Margin=new Thickness(0,4,0,0);detail.MaxWidth=620;detail.HorizontalAlignment=HorizontalAlignment.Left;body.Children.Add(detail);
      content.Children.Add(row);
      return body;
    }

    StackPanel SetupActions(StackPanel body) {
      var actions=new StackPanel{Orientation=Orientation.Horizontal,Margin=new Thickness(0,16,0,0)};body.Children.Add(actions);return actions;
    }
    Button SetupAction(StackPanel host,string title,Func<Task> task,bool primary=false) {
      var button=PlaceAction(host,title,task,primary);
      if(!Horizontal(host))button.Margin=new Thickness(0,8,8,0);
      return button;
    }

    Task RenderSimpleHome() {
      Heading("Configura tu biblioteca","Tus fotos y cuentas no se mueven al conectar un servidor existente.");
      if(String.IsNullOrEmpty(prefs.Installation)) {
        var existing=SetupCard("photo","Conectar mi servidor","Buscaremos la biblioteca que ya funciona en este ordenador. Podrás confirmar la carpeta antes de conectar nada.",true);
        var existingActions=SetupActions(existing);
        var matchesPanel=new StackPanel{Margin=new Thickness(0,8,0,0)};
        SetupAction(existingActions,"Buscar mi biblioteca",async()=>{
          matchesPanel.Children.Clear();
          var matches=await Backend.DiscoverExistingInstallations();
          if(matches.Count==1){prefs.Installation=matches[0];Backend.Save(prefs);await Render();notice.Text="Hemos encontrado tu biblioteca. Comprueba la carpeta y pulsa Conectar.";return;}
          if(matches.Count==0){notice.Text="No hemos podido encontrarla automáticamente. Elige la carpeta donde está tu servidor; no se modificará nada al seleccionarla.";return;}
          notice.Text="Hay varias bibliotecas en este PC. Elige cuál quieres conectar:";
          foreach(var folder in matches){var selected=folder;SetupAction(matchesPanel,"Usar "+selected,async()=>{prefs.Installation=selected;Backend.Save(prefs);await Render();});}
        },true);
        SetupAction(existingActions,"Elegir carpeta…",async()=>{
          var folder=PickFolder();if(folder==null)return;
          if(!File.Exists(Path.Combine(folder,"docker-compose.yml"))||!File.Exists(Path.Combine(folder,".env")))throw new IOException("Esa carpeta no contiene la configuración de un servidor compatible. No se ha cambiado nada.");
          prefs.Installation=folder;Backend.Save(prefs);await Render();
        });
        existing.Children.Add(matchesPanel);

        var fresh=SetupCard("folder","Crear una biblioteca nueva","Elige dónde guardar las fotos y prepara un servidor nuevo. No modifica otra biblioteca existente.");
        SetupAction(SetupActions(fresh),File.Exists(NewServer.PendingFile)?"Continuar configuración":"Crear biblioteca nueva",async()=>{
          var wizard=new NewServerWindow{Owner=this};
          if(wizard.ShowDialog()==true){prefs=wizard.Result;notice.Text="Tu biblioteca está preparada.";await Render();}
        });
      } else {
        var found=SetupCard("folder","Biblioteca encontrada","Esta es la carpeta que vamos a comprobar. Puedes cambiarla antes de continuar.",true);
        var pathRow=new Grid{Margin=new Thickness(0,12,0,0)};
        pathRow.ColumnDefinitions.Add(new ColumnDefinition());pathRow.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
        var path=Ui.Text(prefs.Installation,Ui.BodySize,Ui.Ink,true);path.VerticalAlignment=VerticalAlignment.Center;path.TextTrimming=TextTrimming.CharacterEllipsis;path.TextWrapping=TextWrapping.NoWrap;path.ToolTip=prefs.Installation;
        pathRow.Children.Add(path);
        var change=new StackPanel{Orientation=Orientation.Horizontal,Margin=new Thickness(16,0,0,0)};Grid.SetColumn(change,1);pathRow.Children.Add(change);
        found.Children.Add(pathRow);
        SetupAction(change,"Cambiar carpeta",async()=>{
          var folder=PickFolder();if(folder==null)return;
          if(!File.Exists(Path.Combine(folder,"docker-compose.yml"))||!File.Exists(Path.Combine(folder,".env")))throw new IOException("Esa carpeta no contiene la configuración de un servidor compatible. No se ha cambiado nada.");
          prefs.Installation=folder;Backend.Save(prefs);await Render();
        }).Margin=new Thickness(0);
        var body=SetupCard("shield","Comprobación antes de conectar","Probamos una copia de la base de datos en un entorno aislado. El servidor seguirá encendido y las fotos permanecerán en su sitio.");
        var names=new[]{"Comprobar el servidor","Guardar la base de datos para la prueba","Probar recuperación aislada","Confirmar que nada cambió","Conectar el gestor"};
        var markers=new Ui.StepMarker[names.Length];var labels=new TextBlock[names.Length];
        var checklist=new StackPanel{Margin=new Thickness(0,16,0,0)};body.Children.Add(checklist);
        for(var i=0;i<names.Length;i++){
          var step=new Grid{Margin=new Thickness(0,0,0,10)};step.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(34)});step.ColumnDefinitions.Add(new ColumnDefinition());
          markers[i]=new Ui.StepMarker(i+1);markers[i].HorizontalAlignment=HorizontalAlignment.Left;step.Children.Add(markers[i]);
          labels[i]=Ui.Text(names[i],Ui.BodySize,Ui.Ink2);labels[i].VerticalAlignment=VerticalAlignment.Center;Grid.SetColumn(labels[i],1);step.Children.Add(labels[i]);checklist.Children.Add(step);
        }
        var status=Ui.Secondary("Lista para comprobar. Puedes seguir usando tus fotos.");status.Margin=new Thickness(0,6,0,0);
        AutomationProperties.SetLiveSetting(status,AutomationLiveSetting.Polite);body.Children.Add(status);
        var progress=new ProgressBar{Minimum=0,Maximum=5,Value=0,Margin=new Thickness(0,12,0,0),Visibility=Visibility.Collapsed};
        AutomationProperties.SetName(progress,"Progreso de la comprobación");body.Children.Add(Ui.Constrain(progress,420));
        SetupAction(SetupActions(body),"Conectar esta biblioteca",async()=>{
          progress.Visibility=Visibility.Visible;
          Action<int,string> milestone=(index,message)=>Dispatcher.Invoke(()=>{
            for(var i=0;i<labels.Length;i++){
              markers[i].Set(i<index?Ui.StepState.Done:i==index?Ui.StepState.Current:Ui.StepState.Pending);
              labels[i].Foreground=i<=index?Ui.Ink:Ui.Ink2;
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
        var safety=Ui.Caption("Esta verificación comprueba la base de datos; no es una copia completa de tus fotos y vídeos.");
        safety.Margin=new Thickness(0,12,0,0);body.Children.Add(safety);

        var fresh=SetupCard("photo","Crear una biblioteca nueva","Solo si prefieres empezar de cero. La biblioteca encontrada no se sustituirá desde esta pantalla.");
        SetupAction(SetupActions(fresh),File.Exists(NewServer.PendingFile)?"Continuar configuración nueva":"Configurar servidor nuevo",async()=>{
          var wizard=new NewServerWindow{Owner=this};
          if(wizard.ShowDialog()==true){prefs=wizard.Result;notice.Text="Tu biblioteca está preparada.";await Render();}
        });
      }
      return Task.CompletedTask;
    }
  }
}
