#Requires -Version 7.4
# Exercise the actual coordinator with controlled manager/engine dependencies.
# Intent creation, flush/replace, reload and retry decisions use real files.
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSHOME 'Microsoft.CodeAnalysis.dll')
Add-Type -Path (Join-Path $PSHOME 'Microsoft.CodeAnalysis.CSharp.dll')
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'SystemUpdates.cs'))
$stubs=@'
using System;using System.IO;using System.Threading.Tasks;using System.Text.Json;
namespace InhousePhotos {
 public sealed class Preferences {public bool Managed;public string Installation,ProjectName,ReceiptPath;}
 public sealed class Serializer {public string Serialize(object value){return JsonSerializer.Serialize(value);}public T Deserialize<T>(string value){return JsonSerializer.Deserialize<T>(value);}}
 public static class Backend {public const string Version="3.1.96";public static string SettingsDir;public static Serializer Json=new Serializer();public static void RejectLinks(string p){}public static void PrivateDirectory(string p){Directory.CreateDirectory(p);}}
 public sealed class ManagerUpdateStatus {public bool Available;public string LatestVersion="3.1.96",Phase="idle";public int Progress;}
 public static class ManagerUpdates {public static bool IsApplying;public static ManagerUpdateStatus Value=new ManagerUpdateStatus();public static ManagerUpdateStatus Status(){return Value;}public static Task<ManagerUpdateStatus> Check(bool force=false){return Task.FromResult(Value);}public static int Compare(string a,string b){return Version.Parse(a).CompareTo(Version.Parse(b));}public static bool TryBegin(){IsApplying=true;return true;}}
 public sealed class RuntimeUpdateStatus {public bool Available=true,RecoveryRequired;public string Phase="idle";public int Progress;}
 public static class RuntimeUpdates {public static bool IsApplying,Installed,ThrowApply;public static TaskCompletionSource<bool> Confirmation;public static bool IsBusy{get{return IsApplying;}}public static RuntimeUpdateStatus Status(){return new RuntimeUpdateStatus();}public static Task<RuntimeUpdateStatus> Check(Preferences p,bool force=false){return Task.FromResult(Status());}public static Task<bool> ConfirmInstalled(Preferences p){return Confirmation==null?Task.FromResult(Installed):Confirmation.Task;}public static bool TryBegin(){IsApplying=true;return true;}public static Task Apply(Preferences p){IsApplying=false;if(ThrowApply)throw new IOException("simulated loss of engine receipt");Installed=true;return Task.CompletedTask;}}
 public static class RemoteManagement {public const string SystemPath="/inhouse-manager/v1/system-update";public static bool Allowed(string method,string path){return (method=="GET"||method=="POST")&&path==SystemPath;}public static string ReadOnlyBrowserToken(string method,string path,string cookie){return null;}}
 public static class Harness {
  static int checks;static void Assert(bool condition,string name){if(!condition)throw new Exception(name);checks++;}
  static string Pathname{get{return Path.Combine(Backend.SettingsDir,"system-update.json");}}
  static SystemUpdateIntent Read(){return Backend.Json.Deserialize<SystemUpdateIntent>(File.ReadAllText(Pathname));}
  static void Save(SystemUpdateIntent value){File.WriteAllText(Pathname,Backend.Json.Serialize(value));}
  public static async Task<int> Run(){
   Backend.SettingsDir=Path.Combine(Path.GetTempPath(),"inhouse-system-harness-"+Guid.NewGuid().ToString("N"));
   var p=new Preferences{Managed=true,Installation=@"D:\photos",ProjectName="inhouse",ReceiptPath=@"C:\receipt.json"};
   try {
    Assert(SystemUpdates.SelfTest()==0,"pure contracts");Assert(SystemUpdates.VerifyIntent()==0,"durable real-file reload");
    SystemUpdates.QueueFromInstaller(p);var handoff=Read();handoff.State="running";handoff.Attempts=3;handoff.NextAttemptUtc=DateTime.UtcNow.AddMinutes(1).ToString("o");Save(handoff);
    SystemUpdates.QueueFromInstaller(p);Assert(Read().Attempts==3&&Read().NextAttemptUtc=="","installer continuation preserves budget before verified pointer");
    SystemUpdates.ManagerInstalled(p);Assert(Read().Attempts==0&&Read().NextAttemptUtc=="","verified manager stage starts immediate fresh engine budget");
    Assert(SystemUpdates.TryBegin(p,true),"legacy bootstrap resumes without phone");
    await SystemUpdates.Apply(p,()=>Task.CompletedTask);Assert(Read().State=="completed"&&SystemUpdates.Status().CurrentVersion==Backend.Version&&!SystemUpdates.BlocksOperations(p),"healthy receipt confirms complete product");
    SystemUpdates.QueueFromInstaller(p);RuntimeUpdates.Installed=false;RuntimeUpdates.ThrowApply=true;Assert(SystemUpdates.TryBegin(p,true),"pending starts");
    try{await SystemUpdates.Apply(p,()=>Task.CompletedTask);throw new Exception("did not fail");}catch(IOException){}
    Assert(Read().State=="error"&&Read().Attempts==1&&SystemUpdates.Status().CurrentVersion=="","failed receipt remains incomplete");
    Assert(!SystemUpdates.TryBegin(p,true),"retry delay survives reload");Assert(SystemUpdates.TryBegin(p,false),"explicit user retry available");
    try{await SystemUpdates.Apply(p,()=>Task.CompletedTask);}catch(IOException){}
    var stopped=Read();stopped.Attempts=3;stopped.State="running";stopped.NextAttemptUtc=DateTime.UtcNow.AddMinutes(-1).ToString("o");Save(stopped);
    Assert(!SystemUpdates.TryBegin(p,true),"restart cannot loop after max attempts");
    await SystemUpdates.Check(p,true);Assert(Read().State=="error"&&SystemUpdates.Status().Phase=="error"&&!SystemUpdates.Status().Busy&&SystemUpdates.Status().Available,"exhausted running crash exposes actionable retry");
    RuntimeUpdates.Installed=true;await SystemUpdates.Check(p,true);Assert(Read().State=="completed"&&!SystemUpdates.BlocksOperations(p)&&SystemUpdates.Status().CurrentVersion==Backend.Version,"healthy completion repairs last-write uncertainty at exhausted retry limit");
    SystemUpdates.QueueFromInstaller(p);RuntimeUpdates.Confirmation=new TaskCompletionSource<bool>();var checking=SystemUpdates.Check(p,true);
    Assert(SystemUpdates.TryBegin(p,true),"begin during check");RuntimeUpdates.Confirmation.SetResult(true);await checking;
    Assert(Read().State=="running"&&SystemUpdates.IsApplying,"in-flight check cannot overwrite active update");RuntimeUpdates.Confirmation=null;RuntimeUpdates.ThrowApply=false;
    await SystemUpdates.Apply(p,()=>Task.CompletedTask);
    var completed=Read();var other=new Preferences{Managed=true,Installation=@"E:\different",ProjectName=p.ProjectName,ReceiptPath=p.ReceiptPath};Assert(!SystemUpdates.BlocksOperations(other),"completed intent permits future library");
    completed.State="pending";Save(completed);await SystemUpdates.Check(other,true);
    Assert(SystemUpdates.BlocksOperations(other)&&SystemUpdates.Status().RequiresLocalRecovery&&!SystemUpdates.Status().Available,"active intent rejects changed library");
    return checks;
   }finally{Directory.Delete(Backend.SettingsDir,true);}
  }
 }
}
'@
$trees=[Microsoft.CodeAnalysis.SyntaxTree[]]@([Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($source),[Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($stubs))
$refs=[Microsoft.CodeAnalysis.MetadataReference[]]@([AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES').Split([IO.Path]::PathSeparator)|ForEach-Object{[Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile($_)})
$options=[Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
$compilation=[Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('SystemUpdateHarness-'+[Guid]::NewGuid().ToString('N'),$trees,$refs,$options)
$stream=New-Object IO.MemoryStream
$result=$compilation.Emit($stream)
if(-not $result.Success){$result.Diagnostics|ForEach-Object{$_.ToString()};exit 1}
$assembly=[Reflection.Assembly]::Load($stream.ToArray())
$task=$assembly.GetType('InhousePhotos.Harness').GetMethod('Run').Invoke($null,@())
$count=$task.GetAwaiter().GetResult()
Write-Output "$count system update workflow checks passed with real persisted intent files."
