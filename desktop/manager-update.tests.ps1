#Requires -Version 7.4
# Exercise the actual manager state machine with owned child processes.
# No installer, managed library, network request or Docker process is changed.
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSHOME 'Microsoft.CodeAnalysis.dll')
Add-Type -Path (Join-Path $PSHOME 'Microsoft.CodeAnalysis.CSharp.dll')
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ManagerUpdates.cs'))
$stubs=@'
using System;using System.Diagnostics;using System.IO;using System.Reflection;using System.Text.Json;
namespace InhousePhotos {
 public sealed class Serializer {public T Deserialize<T>(string value){return JsonSerializer.Deserialize<T>(value);}}
 public static class Backend {public const string Version="3.1.96";public static string SettingsDir;public static Serializer Json=new Serializer();public static void PrivateDirectory(string path){Directory.CreateDirectory(path);}public static string Hash(string path){return "";}}
 public static class Harness {
  static int checks;static void Assert(bool condition,string name){if(!condition)throw new Exception(name);checks++;}
  static Process Child(string powershell,string command) {
   return Process.Start(new ProcessStartInfo(powershell,"-NoLogo -NoProfile -NonInteractive -Command \""+command+"\""){UseShellExecute=false,CreateNoWindow=true});
  }
  static void Track(Process process) {typeof(ManagerUpdates).GetMethod("TrackHelper",BindingFlags.Static|BindingFlags.NonPublic).Invoke(null,new object[]{process});}
  public static int Run(string powershell) {
   Backend.SettingsDir=Path.Combine(Path.GetTempPath(),"inhouse-manager-harness-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(Backend.SettingsDir);
   Process live=null;
   try {
    Assert(ManagerUpdates.TryBegin(),"initial manager update starts");
    live=Child(powershell,"Start-Sleep -Seconds 30; exit 0");Track(live);
    var status=ManagerUpdates.Status();Assert(status.Phase=="installing"&&status.Progress==100&&ManagerUpdates.IsApplying&&!ManagerUpdates.TryBegin(),"living helper blocks a duplicate installer");
    ManagerUpdates.Fail(new IOException("controlled close callback failure"));Assert(ManagerUpdates.IsApplying&&!ManagerUpdates.TryBegin(),"a close error cannot unlock while helper is still alive");
    // The fixture owns this process. Terminate it to model the installer exit;
    // production code never kills a helper or guesses from elapsed time.
    live.Kill();live.WaitForExit();
    status=ManagerUpdates.Status();live=null;Assert(status.Phase=="error"&&status.Error=="controlled close callback failure"&&!ManagerUpdates.IsApplying,"confirmed helper exit releases state and preserves the specific failure");
    Assert(ManagerUpdates.TryBegin(),"explicit retry accepted after helper exit");
    var failed=Child(powershell,"exit 7");Track(failed);if(!failed.WaitForExit(15000))throw new Exception("owned child failed to exit");
    var recorded=Path.Combine(Backend.SettingsDir,"last-manager-update-error.txt");File.WriteAllText(recorded,"El gestor anterior no se cerró. El servidor permanece disponible.");
    status=ManagerUpdates.Status();Assert(status.Phase=="error"&&status.Error==File.ReadAllText(recorded)&&!ManagerUpdates.IsApplying,"installer error is read even while prior status was installing");
    Assert(ManagerUpdates.TryBegin()&&!File.Exists(recorded),"retry clears only the known prior installer error");
    var completed=Child(powershell,"exit 0");Track(completed);if(!completed.WaitForExit(15000))throw new Exception("owned child failed to exit");
    status=ManagerUpdates.Status();Assert(status.Phase=="error"&&!ManagerUpdates.IsApplying&&status.Error.Contains("Pulsa Actualizar"),"zero exit cannot claim successful handoff while old manager is still alive");
    ManagerUpdates.TryBegin();var oversized=Child(powershell,"exit 1");Track(oversized);
    if(!oversized.WaitForExit(15000))throw new Exception("owned child failed to exit");
    File.WriteAllText(recorded,new string('X',5000));
    Assert(ManagerUpdates.Status().Error.Contains("Pulsa Actualizar"),"oversize installer diagnostic is rejected rather than exposed");
    return checks;
   }finally {if(live!=null){try{if(!live.HasExited)live.Kill();}catch{}live.Dispose();}Directory.Delete(Backend.SettingsDir,true);}
  }
 }
}
'@
$trees=[Microsoft.CodeAnalysis.SyntaxTree[]]@([Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($source),[Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($stubs))
$refs=[Microsoft.CodeAnalysis.MetadataReference[]]@([AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES').Split([IO.Path]::PathSeparator)|ForEach-Object{[Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile($_)})
$options=[Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
$compilation=[Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('ManagerUpdateHarness-'+[Guid]::NewGuid().ToString('N'),$trees,$refs,$options)
$stream=New-Object IO.MemoryStream
$result=$compilation.Emit($stream)
if(-not $result.Success){$result.Diagnostics|ForEach-Object{$_.ToString()};exit 1}
$assembly=[Reflection.Assembly]::Load($stream.ToArray())
$powershell=[string](Get-Process -Id $PID).Path
$count=$assembly.GetType('InhousePhotos.Harness').GetMethod('Run').Invoke($null,[object[]]@($powershell))
Write-Output "$count manager update handoff checks passed with real owned child processes."
