using System;
using System.IO;
using System.Diagnostics;
using System.Threading.Tasks;

namespace InhousePhotos {
  public static class EngineSetup {
    public static bool Installed {get{try{return File.Exists(Backend.DockerExe());}catch{return false;}}}
    public static async Task PrepareWindows() {
      // Explicit user action; Windows owns the elevation prompt. Never reboot
      // automatically or change security settings to suppress that prompt.
      using(var child=Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory,"wsl.exe"),"--install --no-distribution"){UseShellExecute=true,Verb="runas",WindowStyle=ProcessWindowStyle.Hidden})) {
        await Task.Run(()=>child.WaitForExit());
        if(child.ExitCode!=0&&child.ExitCode!=3010)throw new IOException("Windows no pudo preparar el componente. Revisa si necesita un reinicio o si la virtualización está desactivada.");
      }
    }
    public static async Task Install(bool accepted,Action<string> progress) {
      if(Installed){await Backend.EnsureEngine(progress);return;}
      if(!accepted)throw new InvalidOperationException("Lee y acepta las condiciones del motor antes de instalarlo.");
      if(!Environment.Is64BitOperatingSystem)throw new IOException("Se necesita Windows de 64 bits.");
      var file=Path.Combine(Backend.SettingsDir,"components","Docker Desktop Installer.exe");
      await NewServer.Download("https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe",file,null,progress);
      var verified=await Backend.PowerShell("$s=Get-AuthenticodeSignature -LiteralPath "+Backend.PsString(file)+"; if($s.Status -eq 'Valid' -and $s.SignerCertificate.Subject -match '(^|, )CN=Docker Inc\\.?($|,)'){'verified'}else{throw 'Firma no válida'}",45);
      if(verified.Trim()!="verified")throw new IOException("No se ha podido verificar al editor del componente. No se ejecutará.");
      progress("Instalando el motor. Windows puede solicitar permisos…");
      using(var child=Process.Start(new ProcessStartInfo(file,"install --user --quiet --accept-license --backend=wsl-2"){UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden})) {
        await Task.Run(()=>child.WaitForExit());
        if(child.ExitCode==3010)throw new IOException("Reinicia Windows cuando te venga bien y vuelve a abrir Inhouse Photos para continuar.");
        if(child.ExitCode!=0)throw new IOException("No se completó la instalación del motor. Comprueba los requisitos de Windows y vuelve a intentarlo.");
      }
      await Backend.EnsureEngine(progress);
    }
  }
}
