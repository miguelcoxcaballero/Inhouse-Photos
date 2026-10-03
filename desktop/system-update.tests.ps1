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
 public static class Backend {public static string Version="3.1.96";public static string SettingsDir;public static Serializer Json=new Serializer();public static void RejectLinks(string p){}public static void PrivateDirectory(string p){Directory.CreateDirectory(p);}}
 public sealed class ManagerUpdateStatus {public bool Available;public string LatestVersion="3.1.96",Phase="idle";public int Progress;public string Error;}
 public static class ManagerUpdates {public static bool IsApplying;public static int CheckCalls;public static ManagerUpdateStatus Value=new ManagerUpdateStatus();public static ManagerUpdateStatus Status(){return Value;}public static Task<ManagerUpdateStatus> Check(bool force=false){CheckCalls++;return Task.FromResult(Value);}public static int Compare(string a,string b){return Version.Parse(a).CompareTo(Version.Parse(b));}public static bool TryBegin(){IsApplying=true;Value.Phase="downloading";return true;}public static void Fail(Exception e){IsApplying=false;Value.Phase="error";Value.Error=e.Message;}}
 public sealed class RuntimeUpdateStatus {public bool Available=true,RecoveryRequired;public string Phase="idle",Stage="";public int Progress,StageElapsedSeconds;}
 public static class RuntimeUpdates {public static bool IsApplying,Installed,ThrowApply,KeepUnconfirmed;public static int ApplyCalls;public static RuntimeUpdateStatus Value=new RuntimeUpdateStatus();public static TaskCompletionSource<bool> Confirmation,HoldApply;public static bool IsBusy{get{return IsApplying;}}public static RuntimeUpdateStatus Status(){return Value;}public static Task<RuntimeUpdateStatus> Check(Preferences p,bool force=false){return Task.FromResult(Status());}public static Task<bool> ConfirmInstalled(Preferences p){return Confirmation==null?Task.FromResult(Installed):Confirmation.Task;}public static bool TryBegin(){IsApplying=true;return true;}public static async Task Apply(Preferences p){ApplyCalls++;try{if(HoldApply!=null)await HoldApply.Task;if(ThrowApply)throw new IOException("simulated loss of engine receipt");if(!KeepUnconfirmed)Installed=true;}finally{IsApplying=false;}}}
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
    SystemUpdates.QueueFromInstaller(p);var newer=Read();newer.TargetVersion="3.1.97";newer.State="pending";newer.Attempts=2;Save(newer);
    var preserved=File.ReadAllBytes(Pathname);bool downgradeRejected=false;
    try{SystemUpdates.QueueFromInstaller(p);}catch(IOException){downgradeRejected=true;}
    Assert(downgradeRejected&&Convert.ToBase64String(File.ReadAllBytes(Pathname))==Convert.ToBase64String(preserved),"installer rejects a newer active product intent without rewriting its bytes or retry budget");
    newer.State="completed";Save(newer);
    SystemUpdates.QueueFromInstaller(p);var handoff=Read();handoff.State="running";handoff.Attempts=3;handoff.NextAttemptUtc=DateTime.UtcNow.AddMinutes(1).ToString("o");Save(handoff);
    SystemUpdates.QueueFromInstaller(p);Assert(Read().Attempts==3&&Read().NextAttemptUtc=="","installer continuation preserves budget before verified pointer");
    SystemUpdates.ManagerInstalled(p);Assert(Read().Attempts==0&&Read().NextAttemptUtc=="","verified manager stage starts immediate fresh engine budget");
    Assert(SystemUpdates.TryBegin(p,true),"legacy bootstrap resumes without phone");
    await SystemUpdates.Apply(p,()=>Task.CompletedTask);Assert(Read().State=="completed"&&SystemUpdates.Status().CurrentVersion==Backend.Version&&!SystemUpdates.BlocksOperations(p),"healthy receipt confirms complete product");
    ManagerUpdates.Value=new ManagerUpdateStatus{Available=true,LatestVersion="3.1.97"};ManagerUpdates.CheckCalls=0;RuntimeUpdates.ApplyCalls=0;
    SystemUpdates.QueueFromInstaller(p);SystemUpdates.ManagerInstalled(p);
    await SystemUpdates.CompletePinnedInstallation(p);
    Assert(ManagerUpdates.CheckCalls==0&&!ManagerUpdates.IsApplying&&Read().State=="completed"&&SystemUpdates.Status().CurrentVersion==Backend.Version,"installer completion ignores a newer live catalogue and never recursively starts another manager upgrade");
    Assert(RuntimeUpdates.ApplyCalls==0,"already verified pinned runtime does not download or restart again");
    SystemUpdates.QueueFromInstaller(p);SystemUpdates.ManagerInstalled(p);RuntimeUpdates.Installed=false;RuntimeUpdates.KeepUnconfirmed=true;
    bool confirmationRejected=false;try{await SystemUpdates.CompletePinnedInstallation(p);}catch(IOException){confirmationRejected=true;}
    Assert(confirmationRejected&&Read().State=="error"&&SystemUpdates.Status().CurrentVersion==""&&!SystemUpdates.Status().Busy,"a helper returning successfully without real final confirmation never completes the product or exposes its version");
    Assert(ManagerUpdates.CheckCalls==0,"failed pinned confirmation still cannot trigger a catalogue-driven manager update");
    RuntimeUpdates.KeepUnconfirmed=false;
    SystemUpdates.QueueFromInstaller(p);SystemUpdates.ManagerInstalled(p);RuntimeUpdates.HoldApply=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
    var installing=SystemUpdates.CompletePinnedInstallation(p);var attempts=Read().Attempts;int refused=0;
    for(int duplicate=0;duplicate<6;duplicate++){try{await SystemUpdates.CompletePinnedInstallation(p);}catch(IOException){refused++;}}
    Assert(refused==6&&SystemUpdates.IsApplying&&Read().State=="running"&&Read().Attempts==attempts&&attempts==1,"duplicate installer completions cannot start a second engine operation or consume retry attempts");
    await SystemUpdates.Check(p,true);Assert(Read().State=="running"&&Read().Attempts==1,"concurrent status refresh cannot finish a still-running installation");
    RuntimeUpdates.HoldApply.SetResult(true);await installing;RuntimeUpdates.HoldApply=null;
    Assert(Read().State=="completed"&&SystemUpdates.Status().CurrentVersion==Backend.Version&&!SystemUpdates.Status().Busy,"one owned completion finishes after its held engine stage is genuinely verified");
    ManagerUpdates.Value=new ManagerUpdateStatus();
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
    Assert(Read().State=="running"&&SystemUpdates.IsApplying,"in-flight check cannot overwrite active update");
    RuntimeUpdates.IsApplying=true;RuntimeUpdates.Value=new RuntimeUpdateStatus{Phase="installing",Progress=80,Stage="image",StageElapsedSeconds=37};
    var preparing=SystemUpdates.Status();Assert(preparing.Stage=="image"&&preparing.StageElapsedSeconds==37&&preparing.Phase=="installing"&&preparing.Busy,"actual engine stage and elapsed time remain visible during product update");
    RuntimeUpdates.IsApplying=false;RuntimeUpdates.Value=new RuntimeUpdateStatus();RuntimeUpdates.Confirmation=null;RuntimeUpdates.ThrowApply=false;
    await SystemUpdates.Apply(p,()=>Task.CompletedTask);
    ManagerUpdates.Value=new ManagerUpdateStatus{Available=true,LatestVersion="3.1.97"};
    await SystemUpdates.Check(p,true);Assert(SystemUpdates.TryBegin(p,false),"manager handoff requested");
    await SystemUpdates.Apply(p,()=>{ManagerUpdates.Value.Phase="installing";ManagerUpdates.Value.Progress=100;return Task.CompletedTask;});
    var handedOff=SystemUpdates.Status();Assert(handedOff.Phase=="installing"&&handedOff.Stage=="manager"&&handedOff.Busy&&!SystemUpdates.IsApplying&&!SystemUpdates.TryBegin(p,false),"returned handoff reports real live manager activity and rejects duplicate installer");
    await SystemUpdates.Check(p,true);Assert(Read().State=="running"&&SystemUpdates.Status().Phase=="installing","checks cannot reconcile a living manager handoff");
    ManagerUpdates.Fail(new IOException("controlled installer exited without closing the manager"));await SystemUpdates.Check(p,true);
    Assert(Read().State=="error"&&SystemUpdates.Status().Phase=="error"&&!SystemUpdates.Status().Busy&&SystemUpdates.Status().Available,"dead handoff persists actionable error and unlocks retry");
    Assert(SystemUpdates.TryBegin(p,false),"dead handoff explicit retry accepted");
    try{await SystemUpdates.Apply(p,()=>{throw new IOException("controlled handoff callback failure");});throw new Exception("handoff did not fail");}catch(IOException){}
    Assert(!ManagerUpdates.IsApplying&&!SystemUpdates.Status().Busy&&Read().State=="error","callback failure centrally releases manager state");
    // Model the requested newer installer, not an older installer overwriting
    // its pending higher target. Production versions are immutable; only this
    // controlled dependency changes version at the simulated process handoff.
    Backend.Version="3.1.97";ManagerUpdates.Value=new ManagerUpdateStatus();RuntimeUpdates.Installed=true;SystemUpdates.QueueFromInstaller(p);await SystemUpdates.Check(p,true);
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
