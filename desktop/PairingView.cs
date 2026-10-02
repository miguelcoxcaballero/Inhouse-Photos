using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
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
      Heading("Conectar un móvil","Escanea el QR y confirma el mismo número en el móvil y en este PC.");
      string address=null;
      try {
        if(!String.IsNullOrWhiteSpace(prefs.Endpoint))address=Backend.CanonicalEndpoint(prefs.Endpoint);
      } catch(ArgumentException) {}
      if(address==null||LocalOnlyEndpoint(address)||new Uri(address).Scheme!="https") {
        var setup=Column();setup.Children.Add(StatusLine("FALTA UNA DIRECCIÓN HTTPS PARA EL MÓVIL",accent));
        setup.Children.Add(Label("Prepara el acceso desde el móvil",23));
        setup.Children.Add(Fine("El QR necesita una dirección HTTPS que apunte a esta biblioteca. Una dirección local de este PC no funcionará en el móvil."));
        content.Children.Add(Panel(setup));
        content.Children.Add(Fine("Guarda la dirección en Ajustes y pruébala desde el móvil con datos móviles para verificar el acceso exterior."));
        Action("Abrir Ajustes  →",()=>GoTo("Configuración"),true);
        return Task.CompletedTask;
      }

      content.Children.Add(Fine("Instala Inhouse Photos en el móvil, abre su cámara y escanea el código. El enlace se genera aquí, sin enviarlo a ningún servicio de QR."));
      Action("Abrir página de descargas  ↗",()=>{Open("https://fotos.miguelcoxcaballero.com/descargas/");return Task.CompletedTask;});
      RenderUsbConnection();
      Rule();

      if(DisablePairingRequests) {
        RenderQr(address,new PairingInvite{Invite=new string('A',43),ExpiresUtc=DateTime.UtcNow.AddMinutes(3)});
        content.Children.Add(Fine("Vista previa: no se ha creado una vinculación real."));
        RenderManualAddress(address);
        return Task.CompletedTask;
      }

      var stored=PairingClient.LoadSession(prefs);
      if(stored==null||connectSession==null||connectSession.AccessToken!=stored.AccessToken||connectSession.ServerKey!=stored.ServerKey) {
        connectSession=stored;connectInvite=null;connectState=null;connectStarting=false;connectAutoStart=true;
      }
      if(connectSession==null) {
        RenderPairingLogin();
      } else {
        if(connectInvite==null) {
          if(connectStarting) {
            content.Children.Add(StatusLine("CREANDO CÓDIGO SEGURO",accent));
            content.Children.Add(Fine("El código aparece en unos segundos."));
          } else if(connectAutoStart) {
            connectStarting=true;
            content.Children.Add(StatusLine("CREANDO CÓDIGO SEGURO",accent));
            content.Children.Add(Fine("El código aparece en unos segundos."));
            _=StartConnectInvite(connectSession);
          } else {
            content.Children.Add(Label("Listo para conectar otro móvil",22));
            Action("Crear un nuevo QR",async()=>{connectAutoStart=true;await Render();},true);
          }
        } else {
          if(DateTime.UtcNow>=connectInvite.ExpiresUtc&&!IsTerminal(connectState==null?"pending":connectState.Status))
            connectState=new PairingState{Status="expired",ExpiresUtc=connectInvite.ExpiresUtc};
          RenderCurrentInvite(address);
          if(!IsTerminal(connectState==null?"pending":connectState.Status))_=PollConnectInvite(generation,connectSession,connectInvite);
        }
        var account=Column();account.Children.Add(Fine("Sesión de administrador en este PC: "+connectSession.UserEmail));
        PlaceLink(account,"Cerrar sesión en este PC",async()=>{
          if(connectInvite!=null&&!IsTerminal(connectState==null?"pending":connectState.Status)) {
            await PairingClient.Cancel(prefs,connectSession,connectInvite.Invite);
          }
          PairingClient.ForgetSession();connectSession=null;connectInvite=null;connectState=null;connectAutoStart=false;
          await Render();notice.Text="La sesión guardada se eliminó de este PC.";
        });
        content.Children.Add(Panel(account));
      }
      if(!String.IsNullOrWhiteSpace(connectError))content.Children.Add(Fine(connectError,accent));
      Rule();
      RenderManualAddress(address);
      return Task.CompletedTask;
    }

    void RenderPairingLogin() {
      var login=Column();login.Children.Add(StatusLine("SOLO LA PRIMERA VEZ EN ESTE PC",accent));
      login.Children.Add(Label("Entra como administrador",22));
      login.Children.Add(Fine("Confirma tu cuenta para crear un QR de un solo uso. La contraseña no se guarda; solo la sesión se protege con Windows."));
      var email=new TextBox{Padding=new Thickness(12),FontSize=15,Background=surface,Foreground=Foreground,
        BorderBrush=divider,BorderThickness=new Thickness(1),Margin=new Thickness(0,2,0,10)};
      email.SetValue(System.Windows.Automation.AutomationProperties.NameProperty,"Correo de administrador");
      var password=new PasswordBox{Padding=new Thickness(12),FontSize=15,Background=surface,Foreground=Foreground,
        BorderBrush=divider,BorderThickness=new Thickness(1),Margin=new Thickness(0,2,0,10)};
      password.SetValue(System.Windows.Automation.AutomationProperties.NameProperty,"Contraseña de administrador");
      login.Children.Add(Fine("Correo de administrador"));login.Children.Add(email);
      login.Children.Add(Fine("Contraseña"));login.Children.Add(password);
      PlaceAction(login,"Iniciar sesión y crear QR",async()=>{
        connectError=null;
        connectSession=await PairingClient.Login(prefs,email.Text,password.Password);
        password.Clear();connectInvite=null;connectState=null;connectAutoStart=true;
        await Render();
      },true);
      content.Children.Add(Panel(login));
    }

    void RenderQr(string address,PairingInvite invite) {
      var qr=Column();qr.Children.Add(StatusLine("ESCANEA ESTE CÓDIGO",good));
      qr.Children.Add(Fine("Abre la cámara del móvil. El enlace contiene una invitación temporal, no tu contraseña."));
      var image=new Image{Source=PairingClient.QrImage(PairingClient.Link(address,invite.Invite)),Width=252,Height=252,Stretch=Stretch.Uniform};
      qr.Children.Add(new Border{Child=image,Background=Brushes.White,Padding=new Thickness(10),
        BorderBrush=divider,BorderThickness=new Thickness(1),CornerRadius=new CornerRadius(10),HorizontalAlignment=HorizontalAlignment.Left,
        Margin=new Thickness(0,2,0,12)});
      qr.Children.Add(Fine("Caduca a las "+invite.ExpiresUtc.ToLocalTime().ToString("HH:mm")+". Solo se puede usar una vez."));
      content.Children.Add(Panel(qr));
    }

    void RenderCurrentInvite(string address) {
      var status=connectState==null?"pending":connectState.Status;
      if(DateTime.UtcNow>=connectInvite.ExpiresUtc&&!IsTerminal(status))status="expired";
      if(status=="pending") {
        RenderQr(address,connectInvite);
        content.Children.Add(Fine("Esperando a que el móvil escanee el código…"));
      } else if(status=="claimed"||status=="phone-confirmed"||status=="pc-confirmed") {
        var match=Column();match.Children.Add(StatusLine("COMPRUEBA EL NÚMERO",accent));
        match.Children.Add(Label("¿Es este tu móvil?",23));
        match.Children.Add(Label(String.IsNullOrWhiteSpace(connectState.DeviceName)?"Móvil sin nombre":connectState.DeviceName,17));
        var code=Label(connectState.Code??"------",36,Foreground);code.FontWeight=FontWeights.Bold;code.Margin=new Thickness(0,1,0,8);match.Children.Add(code);
        match.Children.Add(Fine("Comprueba que el mismo número aparece en el móvil. Autoriza solo si coinciden y reconoces el dispositivo."));
        if(status=="claimed"||status=="phone-confirmed") {
          PlaceAction(match,"Sí, coincide. Autorizar este móvil",async()=>{
            var result=await PairingClient.ConfirmPc(prefs,connectSession,connectInvite.Invite,connectState.Code);
            connectState=result;connectError=null;await Render();
          },true);
        } else match.Children.Add(Fine("Confirmado en este PC. Falta la confirmación del móvil."));
        if(status=="phone-confirmed")match.Children.Add(Fine("El móvil ya lo ha confirmado. Falta tu autorización aquí."));
        content.Children.Add(Panel(match));
      } else if(status=="ready") {
        content.Children.Add(StatusLine("AMBOS DISPOSITIVOS CONFIRMADOS",good));
        content.Children.Add(Fine("Esperando a que el móvil termine de iniciar sesión…"));
      } else if(status=="redeemed") {
        content.Children.Add(StatusLine("MÓVIL CONECTADO",good));
        content.Children.Add(Label("La vinculación ha terminado",23));
        content.Children.Add(Fine("La invitación ya no se puede reutilizar."));
        Action("Conectar otro móvil",async()=>{connectInvite=null;connectState=null;connectAutoStart=true;await Render();},true);
      } else {
        content.Children.Add(StatusLine("CÓDIGO NO DISPONIBLE",accent));
        content.Children.Add(Label(status=="expired"?"El QR ha caducado":status=="cancelled"?"Vinculación cancelada":"No se pudo completar la vinculación",22));
        Action("Crear otro QR",async()=>{connectInvite=null;connectState=null;connectError=null;connectAutoStart=true;await Render();},true);
      }
      if(!IsTerminal(status)) {
        Action("Cancelar este QR",async()=>{
          await PairingClient.Cancel(prefs,connectSession,connectInvite.Invite);
          connectState=new PairingState{Status="cancelled",ExpiresUtc=connectInvite.ExpiresUtc};connectAutoStart=false;
          await Render();
        });
      }
    }

    void RenderManualAddress(string address) {
      var manual=Column();manual.Children.Add(Fine("Si no puedes escanear, puedes conectar el móvil con tu cuenta habitual."));
      var field=new TextBox{Text=address,IsReadOnly=true,TextWrapping=TextWrapping.Wrap,FontSize=15,
        Padding=new Thickness(10),Background=surface,Foreground=Foreground,BorderBrush=divider,BorderThickness=new Thickness(1)};
      manual.Children.Add(field);
      PlaceAction(manual,"Copiar dirección",()=>{Clipboard.SetText(address);notice.Text="Dirección copiada. Pégala en la app e inicia sesión con tu cuenta.";return Task.CompletedTask;});
      content.Children.Add(new Expander{Header="Conexión manual con dirección y contraseña",Content=manual,
        Foreground=muted,Margin=new Thickness(0,4,0,12)});
      content.Children.Add(Fine("La disponibilidad desde este PC no confirma el acceso desde fuera de casa. Pruébalo con datos móviles."));
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
