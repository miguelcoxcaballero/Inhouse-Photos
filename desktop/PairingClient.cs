using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Media.Imaging;
using QRCoder;

namespace InhousePhotos {
  public sealed class PairingSession {
    public string ServerKey {get;set;}
    public string AccessToken {get;set;}
    public string UserEmail {get;set;}
  }
  public sealed class PairingInvite {
    public string Invite {get;set;}
    public DateTime ExpiresUtc {get;set;}
  }
  public sealed class PairingState {
    public string Status {get;set;}
    public string Code {get;set;}
    public string DeviceName {get;set;}
    public DateTime ExpiresUtc {get;set;}
  }
  public sealed class PairingAuthenticationException:IOException {
    public PairingAuthenticationException():base("La sesión de administrador ha caducado. Inicia sesión de nuevo en este PC."){}
  }
  public static class PairingClient {
    static readonly Regex InvitePattern=new Regex("^[A-Za-z0-9_-]{43}$",RegexOptions.Compiled);
    static readonly Regex CodePattern=new Regex("^[0-9]{6}$",RegexOptions.Compiled);
    static readonly string SessionPath=Path.Combine(Backend.SettingsDir,"pairing-session.dpapi");
    static Assembly qrAssembly;

    public static void RegisterQrAssembly() {
      AppDomain.CurrentDomain.AssemblyResolve+=(sender,args)=>{
        if(new AssemblyName(args.Name).Name!="QRCoder")return null;
        if(qrAssembly!=null)return qrAssembly;
        using(var resource=Assembly.GetExecutingAssembly().GetManifestResourceStream("InhousePhotos.QRCoder.dll")) {
          if(resource==null)throw new IOException("Falta el generador local del código QR.");
          using(var buffer=new MemoryStream()) {resource.CopyTo(buffer);qrAssembly=Assembly.Load(buffer.ToArray());return qrAssembly;}
        }
      };
    }
    public static string QrLicense() {
      using(var resource=Assembly.GetExecutingAssembly().GetManifestResourceStream("InhousePhotos.QRCoder-LICENSE.txt")) {
        if(resource==null)throw new IOException("Falta la licencia del generador QR.");
        using(var reader=new StreamReader(resource))return reader.ReadToEnd();
      }
    }

    static string LocalEndpoint(Preferences prefs) {
      var endpoint=Backend.CanonicalEndpoint(prefs.LocalEndpoint);
      var uri=new Uri(endpoint);
      if(!uri.IsLoopback||uri.AbsolutePath!="/")throw new IOException("La vinculación solo se gestiona desde el servidor local de este PC.");
      return endpoint;
    }
    static string ServerKey(Preferences prefs) {
      var installation=Path.GetFullPath(prefs.Installation??"").TrimEnd('\\').ToUpperInvariant();
      return installation+"|"+LocalEndpoint(prefs)+"|"+(prefs.ProjectName??"");
    }
    public static void SaveSession(Preferences prefs,string accessToken,string userEmail) {
      if(String.IsNullOrWhiteSpace(accessToken))throw new ArgumentException("La sesión no contiene un token.");
      var record=new PairingSession{ServerKey=ServerKey(prefs),AccessToken=accessToken,UserEmail=userEmail??""};
      Backend.PrivateDirectory(Backend.SettingsDir);
      var encrypted=ProtectedData.Protect(Encoding.UTF8.GetBytes(Backend.Json.Serialize(record)),null,DataProtectionScope.CurrentUser);
      var temporary=SessionPath+"."+Guid.NewGuid().ToString("N")+".new";
      try {
        File.WriteAllBytes(temporary,encrypted);
        if(File.Exists(SessionPath))File.Replace(temporary,SessionPath,null);
        else File.Move(temporary,SessionPath);
      } finally {if(File.Exists(temporary))File.Delete(temporary);}
    }
    public static PairingSession LoadSession(Preferences prefs) {
      if(!File.Exists(SessionPath))return null;
      try {
        var plain=ProtectedData.Unprotect(File.ReadAllBytes(SessionPath),null,DataProtectionScope.CurrentUser);
        var record=Backend.Json.Deserialize<PairingSession>(Encoding.UTF8.GetString(plain));
        return record!=null&&record.ServerKey==ServerKey(prefs)&&!String.IsNullOrWhiteSpace(record.AccessToken)?record:null;
      } catch {return null;}
    }
    public static void ForgetSession() {if(File.Exists(SessionPath))File.Delete(SessionPath);}

    public static string Link(string publicEndpoint,string invite) {
      if(!InvitePattern.IsMatch(invite??""))throw new ArgumentException("El código de vinculación no es válido.");
      var endpoint=Backend.CanonicalEndpoint(publicEndpoint);
      var uri=new Uri(endpoint);
      if(uri.Scheme!="https"||uri.AbsolutePath!="/")throw new ArgumentException("La vinculación requiere un dominio HTTPS sin rutas, accesible desde el móvil.");
      return "https://fotos.miguelcoxcaballero.com/vincular#origin="+Uri.EscapeDataString(endpoint)+"&invite="+Uri.EscapeDataString(invite);
    }
    public static byte[] QrPng(string link) {
      using(var generator=new QRCodeGenerator())using(var data=generator.CreateQrCode(link,QRCodeGenerator.ECCLevel.Q))
      using(var qr=new PngByteQRCode(data))return qr.GetGraphic(5);
    }
    public static BitmapSource QrImage(string link) {
      var png=QrPng(link);
      using(var stream=new MemoryStream(png)) {
        var bitmap=new BitmapImage();bitmap.BeginInit();bitmap.CacheOption=BitmapCacheOption.OnLoad;bitmap.StreamSource=stream;bitmap.EndInit();bitmap.Freeze();return bitmap;
      }
    }

    static async Task<Dictionary<string,object>> Post(Preferences prefs,string route,object body,string token) {
      var request=(HttpWebRequest)WebRequest.Create(LocalEndpoint(prefs)+route);
      request.Method="POST";request.ContentType="application/json";request.Accept="application/json";
      request.AllowAutoRedirect=false;request.Proxy=null;request.Timeout=10000;request.ReadWriteTimeout=10000;
      if(!String.IsNullOrEmpty(token))request.Headers[HttpRequestHeader.Authorization]="Bearer "+token;
      var bytes=Encoding.UTF8.GetBytes(Backend.Json.Serialize(body));request.ContentLength=bytes.Length;
      using(var deadline=new CancellationTokenSource(12000))using(deadline.Token.Register(()=>request.Abort())) {
        try {
          using(var stream=await request.GetRequestStreamAsync())await stream.WriteAsync(bytes,0,bytes.Length);
          using(var response=(HttpWebResponse)await request.GetResponseAsync()) {
            if((int)response.StatusCode==204)return new Dictionary<string,object>();
            using(var reader=new StreamReader(response.GetResponseStream()))return Backend.Json.Deserialize<Dictionary<string,object>>(await reader.ReadToEndAsync());
          }
        } catch(WebException ex) {
          var response=ex.Response as HttpWebResponse;
          if(response!=null) {
            var code=(int)response.StatusCode;response.Dispose();
            if(code==401||code==403)throw new PairingAuthenticationException();
            if(code==404)throw new IOException("Este servidor todavía no admite la vinculación por QR.");
            if(code==429)throw new IOException("Se han solicitado demasiados códigos. Espera unos minutos y vuelve a intentarlo.");
            throw new IOException("El servidor rechazó la vinculación ("+code+"). Vuelve a intentarlo.");
          }
          throw new IOException("No se pudo contactar con el servidor local. Comprueba que esté en marcha.",ex);
        }
      }
    }
    static string Required(Dictionary<string,object> data,string key) {
      if(data==null||!data.ContainsKey(key)||!(data[key] is string)||String.IsNullOrWhiteSpace((string)data[key]))throw new IOException("El servidor devolvió una respuesta de vinculación incompleta.");
      return (string)data[key];
    }
    static DateTime Expiry(Dictionary<string,object> data) {
      DateTime value;
      if(!DateTime.TryParse(Required(data,"expiresAt"),System.Globalization.CultureInfo.InvariantCulture,
        System.Globalization.DateTimeStyles.AssumeUniversal|System.Globalization.DateTimeStyles.AdjustToUniversal,out value))
        throw new IOException("El servidor devolvió una caducidad no válida.");
      return value;
    }
    public static async Task<PairingSession> Login(Preferences prefs,string email,string password) {
      if(String.IsNullOrWhiteSpace(email)||String.IsNullOrWhiteSpace(password))throw new ArgumentException("Introduce el correo y la contraseña de administrador.");
      Dictionary<string,object> result;
      try {result=await Post(prefs,"/api/auth/login",new{email=email.Trim(),password=password},null);}
      catch(PairingAuthenticationException){throw new IOException("Correo o contraseña incorrectos.");}
      if(!result.ContainsKey("isAdmin")||!(result["isAdmin"] is bool)||(bool)result["isAdmin"]!=true)
        throw new IOException("Esta cuenta no es administradora de la biblioteca.");
      var token=Required(result,"accessToken");var userEmail=Required(result,"userEmail");
      SaveSession(prefs,token,userEmail);
      return new PairingSession{ServerKey=ServerKey(prefs),AccessToken=token,UserEmail=userEmail};
    }
    public static async Task<PairingInvite> Start(Preferences prefs,PairingSession session) {
      var result=await Post(prefs,"/api/auth/pairing/start",new{},session.AccessToken);
      var invite=Required(result,"invite");if(!InvitePattern.IsMatch(invite))throw new IOException("El servidor devolvió un código de vinculación no válido.");
      return new PairingInvite{Invite=invite,ExpiresUtc=Expiry(result)};
    }
    public static async Task<PairingState> Status(Preferences prefs,PairingSession session,string invite) {
      if(!InvitePattern.IsMatch(invite??""))throw new ArgumentException("El código de vinculación no es válido.");
      var result=await Post(prefs,"/api/auth/pairing/status",new{invite=invite},session.AccessToken);
      return ParseState(result);
    }
    static PairingState ParseState(Dictionary<string,object> result) {
      var status=Required(result,"status");
      if(!new[]{"pending","claimed","phone-confirmed","pc-confirmed","ready","redeemed","cancelled","failed","expired"}.Contains(status))
        throw new IOException("El servidor devolvió un estado de vinculación desconocido.");
      var code=result.ContainsKey("code")?result["code"] as string:null;
      if((status=="claimed"||status=="phone-confirmed"||status=="pc-confirmed"||status=="ready")&&code==null)
        throw new IOException("El servidor no devolvió el número de confirmación.");
      if(code!=null&&!CodePattern.IsMatch(code))throw new IOException("El servidor devolvió un código de confirmación no válido.");
      return new PairingState{Status=status,Code=code,DeviceName=result.ContainsKey("deviceName")?result["deviceName"] as string:null,ExpiresUtc=Expiry(result)};
    }
    public static Task<PairingState> ConfirmPc(Preferences prefs,PairingSession session,string invite,string code) {
      if(!InvitePattern.IsMatch(invite??"")||!CodePattern.IsMatch(code??""))throw new ArgumentException("El código de confirmación no es válido.");
      return StatusFromPost(prefs,"/api/auth/pairing/pc-confirm",new{invite=invite,code=code},session.AccessToken);
    }
    static async Task<PairingState> StatusFromPost(Preferences prefs,string route,object body,string token) {
      var result=await Post(prefs,route,body,token);
      return ParseState(result);
    }
    public static async Task Cancel(Preferences prefs,PairingSession session,string invite) {
      if(!InvitePattern.IsMatch(invite??""))throw new ArgumentException("El código de vinculación no es válido.");
      await Post(prefs,"/api/auth/pairing/cancel",new{invite=invite},session.AccessToken);
    }
  }
}
