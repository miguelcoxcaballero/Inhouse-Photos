using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace InhousePhotos {
  public sealed partial class ServerWindow {
    PairingSession connectSession;
    PairingInvite connectInvite;
    PairingState connectState;
    string connectError;
    bool connectAutoStart=true;
    bool connectStarting;
    internal bool DisablePairingRequests {get;set;}

    Task RenderPairingPage() {
      var generation=++connectGeneration;
      Heading("Conectar un móvil","Escanea el código y confirma el mismo número en el móvil y en este PC.");
      string address=null;
      try {
        if(!String.IsNullOrWhiteSpace(prefs.Endpoint))address=Backend.CanonicalEndpoint(prefs.Endpoint);
      } catch(ArgumentException) {}
      if(address==null||LocalOnlyEndpoint(address)||new Uri(address).Scheme!="https") {
        content.Children.Add(EmptyState("globe",Tone.Attention,"Prepara el acceso desde el móvil",
          "El QR necesita una dirección HTTPS que apunte a esta biblioteca. Una dirección local de este PC no funcionará en el móvil."));
        var hint=Ui.Secondary("Guarda la dirección en Ajustes y pruébala desde el móvil con datos móviles para verificar el acceso exterior.");
        hint.Margin=new Thickness(0,12,0,0);hint.MaxWidth=520;hint.HorizontalAlignment=HorizontalAlignment.Left;content.Children.Add(hint);
        Action("Abrir Ajustes",()=>GoTo("Configuración"),true,"arrow").Margin=new Thickness(0,20,0,0);
        return Task.CompletedTask;
      }

      // The live pairing state renders into the left column; the right column
      // keeps the three steps so the flow is always visible.
      var steps=Column();
      var stateStart=content.Children.Count;
      var currentStep=0;
      if(DisablePairingRequests) {
        RenderQr(address,new PairingInvite{Invite=new string('A',43),ExpiresUtc=DateTime.UtcNow.AddMinutes(3)});
        content.Children.Add(Fine("Vista previa: no se ha creado una vinculación real."));
        currentStep=2;
      } else {
        var stored=PairingClient.LoadSession(prefs);
        if(stored==null||connectSession==null||connectSession.AccessToken!=stored.AccessToken||connectSession.ServerKey!=stored.ServerKey) {
          connectSession=stored;connectInvite=null;connectState=null;connectStarting=false;connectAutoStart=true;
        }
        if(connectSession==null) {
          RenderPairingLogin();
        } else {
          if(connectInvite==null) {
            if(connectStarting) {
              Waiting("Creando un código seguro…");
            } else if(connectAutoStart) {
              connectStarting=true;
              Waiting("Creando un código seguro…");
              _=StartConnectInvite(connectSession);
            } else {
              var ready=Ui.Subtitle("Listo para conectar otro móvil");content.Children.Add(ready);
              Action("Crear un nuevo QR",async()=>{connectAutoStart=true;await Render();},true);
            }
          } else {
            if(DateTime.UtcNow>=connectInvite.ExpiresUtc&&!IsTerminal(connectState==null?"pending":connectState.Status))
              connectState=new PairingState{Status="expired",ExpiresUtc=connectInvite.ExpiresUtc};
            currentStep=RenderCurrentInvite(address);
            if(!IsTerminal(connectState==null?"pending":connectState.Status))_=PollConnectInvite(generation,connectSession,connectInvite);
          }
          var account=Column();account.Margin=new Thickness(0,24,0,0);
          account.Children.Add(Ui.Divider(new Thickness(0,0,0,16)));
          var who=Ui.Caption("Sesión de administrador en este PC");account.Children.Add(who);
          var email=Ui.Body(connectSession.UserEmail);email.Margin=new Thickness(0,2,0,0);account.Children.Add(email);
          PlaceLink(account,"Cerrar sesión en este PC",async()=>{
            if(connectInvite!=null&&!IsTerminal(connectState==null?"pending":connectState.Status)) {
              await PairingClient.Cancel(prefs,connectSession,connectInvite.Invite);
            }
            PairingClient.ForgetSession();connectSession=null;connectInvite=null;connectState=null;connectAutoStart=false;
            await Render();notice.Text="La sesión guardada se eliminó de este PC.";
          });
          steps.Children.Add(account);
        }
        if(!String.IsNullOrWhiteSpace(connectError)){var error=Ui.Text(connectError,Ui.BodySize,accent);error.Margin=new Thickness(0,16,0,0);content.Children.Add(error);}
      }
      var state=Column();
      while(content.Children.Count>stateStart){var child=content.Children[stateStart];content.Children.RemoveAt(stateStart);state.Children.Add(child);}

      var guide=Column();
      guide.Children.Add(Ui.Subtitle("Cómo conectar"));
      var labels=new[]{"Instala Inhouse Photos en el móvil.","Abre la cámara y escanea el código. Se genera en este PC, sin servicios externos.","Comprueba que el número coincide en los dos dispositivos y autoriza aquí."};
      for(var i=0;i<labels.Length;i++){
        var stepRow=new Grid{Margin=new Thickness(0,16,0,0)};
        stepRow.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(36)});stepRow.ColumnDefinitions.Add(new ColumnDefinition());
        var marker=new Ui.StepMarker(i+1);marker.VerticalAlignment=VerticalAlignment.Top;marker.HorizontalAlignment=HorizontalAlignment.Left;
        marker.Set(currentStep==4||(currentStep==3&&i<2)?Ui.StepState.Done:i==currentStep-1?Ui.StepState.Current:Ui.StepState.Pending);
        stepRow.Children.Add(marker);
        var stepBody=Column();Grid.SetColumn(stepBody,1);stepRow.Children.Add(stepBody);
        var text=Ui.Body(labels[i]);text.Margin=new Thickness(0,1,0,0);stepBody.Children.Add(text);
        if(i==0)PlaceLink(stepBody,"Página de descargas",()=>{Open("https://fotos.miguelcoxcaballero.com/descargas/");return Task.CompletedTask;},"external").Margin=new Thickness(0,4,0,0);
        guide.Children.Add(stepRow);
      }
      steps.Children.Insert(0,guide);
      content.Children.Add(Ui.Columns(state,steps,300,48,640));
      RenderUsbConnection();
      RenderManualAddress(address);
      return Task.CompletedTask;
    }

    void Waiting(string text) {
      var row=new StackPanel{Orientation=Orientation.Horizontal,Margin=new Thickness(0,4,0,0)};
      row.Children.Add(new Ui.Spinner(20,2,Ui.Hairline,Ui.Brand){VerticalAlignment=VerticalAlignment.Center,Margin=new Thickness(0,0,12,0)});
      var label=Ui.Secondary(text);label.VerticalAlignment=VerticalAlignment.Center;row.Children.Add(label);
      content.Children.Add(row);
    }

    void RenderPairingLogin() {
      var login=Column();
      login.Children.Add(Ui.Subtitle("Entra como administrador"));
      var why=Ui.Secondary("Solo la primera vez en este PC. La contraseña no se guarda; solo la sesión, protegida por Windows.");why.Margin=new Thickness(0,4,0,16);login.Children.Add(why);
      var email=new TextBox{Margin=new Thickness(0,6,0,14)};
      email.SetValue(System.Windows.Automation.AutomationProperties.NameProperty,"Correo de administrador");
      var password=new PasswordBox{Margin=new Thickness(0,6,0,0)};
      password.SetValue(System.Windows.Automation.AutomationProperties.NameProperty,"Contraseña de administrador");
      login.Children.Add(Ui.Text("Correo de administrador",Ui.BodySize,Ui.Ink));login.Children.Add(email);
      login.Children.Add(Ui.Text("Contraseña",Ui.BodySize,Ui.Ink));login.Children.Add(password);
      PlaceAction(login,"Iniciar sesión y crear QR",async()=>{
        connectError=null;
        connectSession=await PairingClient.Login(prefs,email.Text,password.Password);
        password.Clear();connectInvite=null;connectState=null;connectAutoStart=true;
        await Render();
      },true).Margin=new Thickness(0,20,0,0);
      content.Children.Add(login);
    }

    void RenderQr(string address,PairingInvite invite) {
      var qr=Column();
      // The bitmap has 5 px per module. Four DIPs per module keeps every module
      // a whole number of device pixels at 100, 125, 150 and 200 % scaling.
      var code=PairingClient.QrImage(PairingClient.Link(address,invite.Invite));
      var side=Math.Round(code.PixelWidth/5.0)*4;
      var image=new Image{Source=code,Width=side,Height=side,Stretch=Stretch.Fill};
      RenderOptions.SetBitmapScalingMode(image,BitmapScalingMode.NearestNeighbor);
      AutomationProperties.SetName(image,"Código QR de vinculación");
      qr.Children.Add(new Border{Child=image,Background=Brushes.White,Padding=new Thickness(8),
        BorderBrush=Ui.Hairline,BorderThickness=new Thickness(1),CornerRadius=new CornerRadius(8),HorizontalAlignment=HorizontalAlignment.Left});
      var expiry=Ui.Body("Caduca a las "+invite.ExpiresUtc.ToLocalTime().ToString("HH:mm")+". Solo se puede usar una vez.");expiry.Margin=new Thickness(0,14,0,0);qr.Children.Add(expiry);
      var safe=Ui.Caption("El enlace contiene una invitación temporal, no tu contraseña.");safe.Margin=new Thickness(0,4,0,0);qr.Children.Add(safe);
      content.Children.Add(qr);
    }

    // Returns the step of the guide that is in progress (0 none, 4 all done).
    int RenderCurrentInvite(string address) {
      var status=connectState==null?"pending":connectState.Status;
      if(DateTime.UtcNow>=connectInvite.ExpiresUtc&&!IsTerminal(status))status="expired";
      var step=0;
      if(status=="pending") {
        RenderQr(address,connectInvite);
        content.Children.Add(new Border{Height=12});
        Waiting("Esperando a que el móvil escanee el código…");
        step=2;
      } else if(status=="claimed"||status=="phone-confirmed"||status=="pc-confirmed") {
        var match=Column();match.Children.Add(Pill("Comprueba el número",Tone.Attention));
        match.Children.Add(Ui.Subtitle("¿Es este tu móvil?"));
        var device=Ui.Secondary(String.IsNullOrWhiteSpace(connectState.DeviceName)?"Móvil sin nombre":connectState.DeviceName);device.Margin=new Thickness(0,2,0,0);match.Children.Add(device);
        var code=Ui.Text(connectState.Code??"------",40,Ui.Ink,true);code.LineHeight=52;code.Margin=new Thickness(0,12,0,8);
        AutomationProperties.SetName(code,"Código de confirmación "+(connectState.Code??""));match.Children.Add(code);
        match.Children.Add(Fine("Comprueba que el mismo número aparece en el móvil. Autoriza solo si coinciden y reconoces el dispositivo."));
        if(status=="claimed"||status=="phone-confirmed") {
          PlaceAction(match,"Sí, coincide. Autorizar este móvil",async()=>{
            var result=await PairingClient.ConfirmPc(prefs,connectSession,connectInvite.Invite,connectState.Code);
            connectState=result;connectError=null;await Render();
          },true).Margin=new Thickness(0,8,0,0);
        } else match.Children.Add(Fine("Confirmado en este PC. Falta la confirmación del móvil."));
        if(status=="phone-confirmed"){var phone=Fine("El móvil ya lo ha confirmado. Falta tu autorización aquí.");phone.Margin=new Thickness(0,12,0,0);match.Children.Add(phone);}
        content.Children.Add(match);
        step=3;
      } else if(status=="ready") {
        content.Children.Add(Pill("Ambos dispositivos confirmados",Tone.Good));
        Waiting("Esperando a que el móvil termine de iniciar sesión…");
        step=3;
      } else if(status=="redeemed") {
        content.Children.Add(new Ui.StatusMark(44){HorizontalAlignment=HorizontalAlignment.Left,Margin=new Thickness(0,0,0,16)});
        ((Ui.StatusMark)content.Children[content.Children.Count-1]).Set(Tone.Good);
        content.Children.Add(Ui.Subtitle("Móvil conectado"));
        var reuse=Ui.Secondary("La vinculación ha terminado. La invitación ya no se puede reutilizar.");reuse.Margin=new Thickness(0,4,0,0);content.Children.Add(reuse);
        Action("Conectar otro móvil",async()=>{connectInvite=null;connectState=null;connectAutoStart=true;await Render();},true).Margin=new Thickness(0,20,0,0);
        step=4;
      } else {
        var mark=new Ui.StatusMark(44){HorizontalAlignment=HorizontalAlignment.Left,Margin=new Thickness(0,0,0,16)};mark.Set(Tone.Attention);content.Children.Add(mark);
        content.Children.Add(Ui.Subtitle(status=="expired"?"El QR ha caducado":status=="cancelled"?"Vinculación cancelada":"No se pudo completar la vinculación"));
        Action("Crear otro QR",async()=>{connectInvite=null;connectState=null;connectError=null;connectAutoStart=true;await Render();},true).Margin=new Thickness(0,20,0,0);
      }
      if(!IsTerminal(status)) {
        Action("Cancelar este QR",async()=>{
          await PairingClient.Cancel(prefs,connectSession,connectInvite.Invite);
          connectState=new PairingState{Status="cancelled",ExpiresUtc=connectInvite.ExpiresUtc};connectAutoStart=false;
          await Render();
        }).Margin=new Thickness(0,20,0,0);
      }
      return step;
    }

    void RenderManualAddress(string address) {
      var manual=Column();
      var why=Ui.Secondary("Si no puedes escanear, conecta el móvil con tu cuenta habitual usando esta dirección.");why.Margin=new Thickness(0,0,0,12);manual.Children.Add(why);
      var row=new Grid();
      row.ColumnDefinitions.Add(new ColumnDefinition());row.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
      var field=new TextBox{Text=address,IsReadOnly=true,TextWrapping=TextWrapping.Wrap};
      AutomationProperties.SetName(field,"Dirección del servidor");row.Children.Add(field);
      var copyHost=new StackPanel{Orientation=Orientation.Horizontal,Margin=new Thickness(8,0,0,0)};Grid.SetColumn(copyHost,1);row.Children.Add(copyHost);
      manual.Children.Add(Ui.Constrain(row,640));
      PlaceAction(copyHost,"Copiar dirección",()=>{Clipboard.SetText(address);notice.Text="Dirección copiada. Pégala en la app e inicia sesión con tu cuenta.";return Task.CompletedTask;}).Margin=new Thickness(0);
      content.Children.Add(new Expander{Header="Conexión manual con dirección y contraseña",Content=manual,Margin=new Thickness(0,36,0,0)});
      var reach=Ui.Caption("La disponibilidad desde este PC no confirma el acceso desde fuera de casa. Pruébalo con datos móviles.");reach.Margin=new Thickness(0,4,0,0);content.Children.Add(reach);
    }

    static bool IsTerminal(string status) {
      return status=="redeemed"||status=="cancelled"||status=="expired"||status=="failed";
    }
    async Task StartConnectInvite(PairingSession session) {
      bool showResult=false;
      try {
        var invite=await PairingClient.Start(prefs,session);
        if(connectSession!=session)return;
        connectInvite=invite;connectState=new PairingState{Status="pending",ExpiresUtc=invite.ExpiresUtc};connectError=null;
        showResult=true;
      } catch(PairingAuthenticationException ex) {
        if(connectSession==session) {
          PairingClient.ForgetSession();connectSession=null;connectInvite=null;connectError=ex.Message;
          showResult=true;
        }
      } catch(Exception ex) {
        if(connectSession==session){connectError=ex.Message;connectAutoStart=false;showResult=true;}
      } finally {
        if(showResult){connectStarting=false;if(page=="Conectar")await Render();}
      }
    }
    async Task PollConnectInvite(int generation,PairingSession session,PairingInvite invite) {
      while(generation==connectGeneration&&page=="Conectar") {
        await Task.Delay(1800);
        if(generation!=connectGeneration||page!="Conectar"||connectInvite!=invite)return;
        if(DateTime.UtcNow>=invite.ExpiresUtc) {
          connectState=new PairingState{Status="expired",ExpiresUtc=invite.ExpiresUtc};
          await Render();return;
        }
        try {
          var state=await PairingClient.Status(prefs,session,invite.Invite);
          if(generation!=connectGeneration||page!="Conectar"||connectInvite!=invite)return;
          if(connectState==null||state.Status!=connectState.Status||state.Code!=connectState.Code||state.DeviceName!=connectState.DeviceName||connectError!=null) {
            connectState=state;connectError=null;
            await Render();return;
          }
          if(IsTerminal(state.Status))return;
        } catch(PairingAuthenticationException ex) {
          if(generation!=connectGeneration||connectInvite!=invite)return;
          PairingClient.ForgetSession();connectSession=null;connectInvite=null;connectState=null;connectError=ex.Message;
          await Render();return;
        } catch(Exception ex) {
          if(generation!=connectGeneration||connectInvite!=invite)return;
          if(connectError!=ex.Message){connectError=ex.Message;await Render();return;}
        }
      }
    }
  }
}
