using System;
using System.IO;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace InhousePhotos {
  public sealed class StartupReceipt {
    public string DockerRun {get;set;}
    public bool LegacyWatchdogEnabled {get;set;}
    public bool OwnsLegacyWatchdog {get;set;}
    public string Installation {get;set;}
  }
  public static class Startup {
    public const string TaskName="Inhouse Photos Server";
    static string ReceiptPath {get{return Path.Combine(Backend.SettingsDir,"startup-previous.json");}}
    static string LegacyProbe(StartupReceipt receipt) {
      var expected="-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \""+Path.Combine(receipt.Installation,@"operations\immich-watchdog.ps1")+"\"";
      return "$legacy=Get-ScheduledTask -TaskName 'Inhouse Photos Watchdog' -ErrorAction SilentlyContinue; if($legacy -and ($legacy.Actions.Count -ne 1 -or $legacy.Actions[0].Arguments -cne "+Backend.PsString(expected)+")){throw 'La tarea anterior ha cambiado; no se modificará'}; ";
    }
    static string TaskProbe {
      get{return "$t=Get-ScheduledTask -TaskName 'Inhouse Photos Server' -ErrorAction SilentlyContinue; if($t){if($t.Actions.Count -ne 1 -or $t.Actions[0].Execute -ne "+Backend.PsString(Backend.Launcher)+" -or $t.Actions[0].Arguments -ne '--startup'){throw 'Existe otra tarea con el mismo nombre; no se modificará'}}; ";}
    }
    public static async Task<bool> IsEnabled() {
      return (await Backend.PowerShell(TaskProbe+"if($t -and $t.State -ne 'Disabled'){'enabled'}else{'disabled'}",15)).Trim()=="enabled";
    }
    public static async Task SetEnabled(Preferences p,bool enabled) {
      if(!enabled){await Backend.PowerShell(TaskProbe+"if($t){Disable-ScheduledTask -InputObject $t | Out-Null}",15);return;}
      Backend.ValidateManagedConfiguration(p);
      if(!File.Exists(Backend.Launcher))throw new InvalidOperationException("Instala primero el programa con el instalador descargado de la web.");
      Backend.PrivateDirectory(Backend.SettingsDir);
      StartupReceipt previous;
      if(File.Exists(ReceiptPath))previous=Backend.Json.Deserialize<StartupReceipt>(File.ReadAllText(ReceiptPath));
      else {
        var expected=Path.Combine(p.Installation,@"operations\immich-watchdog.ps1");
        var script="$t=Get-ScheduledTask -TaskName 'Inhouse Photos Watchdog' -ErrorAction SilentlyContinue; if($t -and $t.Actions.Count -eq 1 -and $t.Actions[0].Arguments -eq "+Backend.PsString("-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \""+expected+"\"")+"){if($t.State -eq 'Disabled'){'disabled'}else{'enabled'}}else{'unowned'}";
        var legacy=(await Backend.PowerShell(script,15)).Trim();
        string dockerRun;using(var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))dockerRun=key==null?null:key.GetValue("Docker Desktop") as string;
        previous=new StartupReceipt{DockerRun=dockerRun,LegacyWatchdogEnabled=legacy=="enabled",OwnsLegacyWatchdog=legacy!="unowned",Installation=p.Installation};
        File.WriteAllText(ReceiptPath,Backend.Json.Serialize(previous));
      }
      var register=TaskProbe+@"
$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$action=New-ScheduledTaskAction -Execute "+Backend.PsString(Backend.Launcher)+@" -Argument '--startup'
$trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
$trigger.Delay='PT15S'
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'Inhouse Photos Server' -Description 'Inhouse Photos: inicio y supervisión del servidor al entrar en Windows.' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null";
      bool registered=false;
      try {
        await Backend.PowerShell(register,20);registered=true;
        if(!await IsEnabled())throw new IOException("Windows no confirmó el inicio automático.");
        if(previous.OwnsLegacyWatchdog&&String.Equals(previous.Installation,p.Installation,StringComparison.OrdinalIgnoreCase))
          await Backend.PowerShell(LegacyProbe(previous)+"if($legacy){Disable-ScheduledTask -InputObject $legacy | Out-Null}",15);
        // Preserve third-party startup values and never disable the independent
        // DDNS task: the existing public hostname still needs it.
        var engine=Path.GetFullPath(Path.Combine(Path.GetDirectoryName(Backend.DockerExe()),@"..\..\Docker Desktop.exe"));
        using(var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run",true)) {
          var current=key==null?null:key.GetValue("Docker Desktop") as string;
          if(current!=null&&String.Equals(current.Trim('"'),engine,StringComparison.OrdinalIgnoreCase))key.DeleteValue("Docker Desktop",false);
        }
      } catch {
        if(registered){try{await Backend.PowerShell(TaskProbe+"if($t){Disable-ScheduledTask -InputObject $t | Out-Null}",15);}catch{}}
        await RestoreLegacy(previous);throw;
      }
    }
    static async Task RestoreLegacy(StartupReceipt previous) {
      if(previous.OwnsLegacyWatchdog&&previous.LegacyWatchdogEnabled)
        await Backend.PowerShell(LegacyProbe(previous)+"if($legacy){Enable-ScheduledTask -InputObject $legacy | Out-Null}",15);
      if(previous.DockerRun!=null)using(var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) {
        if(key.GetValue("Docker Desktop")==null)key.SetValue("Docker Desktop",previous.DockerRun,RegistryValueKind.String);
      }
    }
    public static async Task ReleaseOwnership(Preferences p) {
      await SetEnabled(p,false);
      if(File.Exists(ReceiptPath))await RestoreLegacy(Backend.Json.Deserialize<StartupReceipt>(File.ReadAllText(ReceiptPath)));
      p.Managed=false;Backend.Save(p);
    }
  }
}
