#Requires -Version 7.4
# Compile the real publisher, then run its shell transaction against real files
# through a Docker fixture. No Docker daemon, phone or administrator login needed.
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSHOME 'Microsoft.CodeAnalysis.dll')
Add-Type -Path (Join-Path $PSHOME 'Microsoft.CodeAnalysis.CSharp.dll')
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'PublicDownloads.cs'))
$package=Join-Path ([IO.Path]::GetTempPath()) ('inhouse-downloads-test-'+[Guid]::NewGuid().ToString('N')+'.zip')
& (Join-Path $PSScriptRoot 'package-public-downloads.ps1') -OutFile $package|Out-Null
$stubs=@'
using System;using System.IO;using System.Linq;using System.Text;using System.Text.Json;using System.Collections.Generic;using System.Diagnostics;using System.Threading.Tasks;using System.IO.Compression;
namespace InhousePhotos {
 public sealed class Preferences {public bool Managed{get;set;}public string Installation{get;set;}public string ProjectName{get;set;}public string ReceiptPath{get;set;}}
 public sealed class ServerMount {public string Destination{get;set;}public string Type{get;set;}public string Source{get;set;}public bool RW{get;set;}}
 public sealed class ServerContainer {public string Id{get;set;}public string Image{get;set;}public string Service{get;set;}public string Project{get;set;}public ServerMount[] Mounts{get;set;}}
 public sealed class AdoptionReceipt {public bool RestoreVerified{get;set;}public string SnapshotSha256{get;set;}public List<ServerContainer> Containers{get;set;}public Dictionary<string,string> ConfigurationHashes{get;set;}}
 public sealed class Serializer {public string Serialize(object o){return JsonSerializer.Serialize(o);}public T Deserialize<T>(string s){return JsonSerializer.Deserialize<T>(s);}}
 public static class RuntimeUpdates {public static bool Recognised;public static bool HasRecognizedPendingTransaction(Preferences p){return Recognised;}}
 public static class Backend {
  public static string SettingsDir,FixtureRoot;public static Serializer Json=new Serializer();public static List<ServerContainer> Containers;public static int Writes;
  public static void RejectLinks(string p){}public static void PrivateDirectory(string p){Directory.CreateDirectory(p);}
  public static string Hash(string p){return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(p))).ToLowerInvariant();}
  public static string Argument(string s){return "@"+Convert.ToBase64String(Encoding.UTF8.GetBytes(s));}public static string Quote(string s){return Argument(s);}
  static string Decode(string s){return s.StartsWith("@")?Encoding.UTF8.GetString(Convert.FromBase64String(s.Substring(1))):s;}
  static string Translate(string p){if(p.StartsWith(PublicDownloads.Root,StringComparison.Ordinal))return Path.Combine(FixtureRoot,"public")+p.Substring(PublicDownloads.Root.Length);if(p.StartsWith("/tmp/inhouse-downloads-",StringComparison.Ordinal))return FixtureRoot+p;return p;}
  static string ShellPath(string p){if(Path.DirectorySeparatorChar=='\\'&&p.Length>2&&p[1]==':')return "/"+Char.ToLowerInvariant(p[0])+p.Substring(2).Replace('\\','/');return p;}
  public static Dictionary<string,string> ConfigurationHashes(Preferences p){return new[]{"docker-compose.yml",".env","Caddyfile"}.ToDictionary(n=>n,n=>Hash(Path.Combine(p.Installation,n)));}
  public static Task<List<ServerContainer>> InspectServer(Preferences p){return Task.FromResult(Containers);}
  public static void AssertManagedIdentity(Preferences p,List<ServerContainer> old,List<ServerContainer> now){if(old.Count!=now.Count||now.Any(c=>c.Project!=p.ProjectName))throw new IOException("fixture identity changed");}
  public static async Task<string> Docker(string command,int seconds){
   var args=command.Split(' ').Select(Decode).ToArray();
   if(args[0]=="cp"){
    var source=args[1].Contains(":/")?Translate(args[1].Substring(args[1].IndexOf(":/")+1)):args[1];
    var target=args[2].Contains(":/")?Translate(args[2].Substring(args[2].IndexOf(":/")+1)):args[2];
    File.Copy(source,target,false);Writes++;return "";
   }
   if(args.Length>3&&args[2]=="cat")return File.ReadAllText(Path.Combine(FixtureRoot,"installation","Caddyfile"));
   if(args.Length<6||args[0]!="exec"||args[2]!="sh"||args[3]!="-c")throw new IOException("unexpected Docker command");
   var executable=Path.DirectorySeparatorChar=='\\'?Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),"Git","bin","bash.exe"):"/bin/sh";
   var start=new ProcessStartInfo(executable){UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=true};
   start.ArgumentList.Add("-c");start.ArgumentList.Add(args[4]);start.ArgumentList.Add(args[5]);
   foreach(var argument in args.Skip(6))start.ArgumentList.Add(ShellPath(Translate(argument)));
   using(var process=Process.Start(start)){
    var output=process.StandardOutput.ReadToEndAsync();var error=process.StandardError.ReadToEndAsync();await process.WaitForExitAsync();
    var result=await output;var detail=await error;if(process.ExitCode!=0)throw new IOException("fixture shell rejected transaction "+process.ExitCode+": "+detail+"; script="+args[4]);return result;
   }
  }
 }
 public static class Harness {
  static int checks;static void Assert(bool b,string name){if(!b)throw new Exception(name);checks++;}
  static void Reject(Action action,string name){try{action();throw new Exception("accepted: "+name);}catch(IOException){checks++;}}
  static string Hash=new string('a',64),OtherHash=new string('b',64);
  static PublicDownloadCatalogue Catalogue(string v){return new PublicDownloadCatalogue{windows=new PublicWindowsDownload{Version=v,InstallerUrl="https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/server-v"+v+"/Inhouse-Photos-Server-Setup.exe",Sha256=Hash},android=new PublicAndroidDownload{version=v,apkUrl="https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/v"+v+"-unified/Inhouse-Photos.apk",sha256=OtherHash}};}
  const string Route="fotos.example {\n handle_path /descargas/* {\n  root * /data/inhouse-downloads\n  header {\n   Content-Security-Policy \"default-src 'none'; script-src 'self'\"\n  }\n  file_server\n }\n handle {\n  reverse_proxy photos:2283\n }\n}\n";
  static Preferences Setup(string directory){
   Backend.FixtureRoot=directory;Backend.SettingsDir=Path.Combine(directory,"private");Directory.CreateDirectory(Backend.SettingsDir);
   var installation=Path.Combine(directory,"installation");Directory.CreateDirectory(installation);Directory.CreateDirectory(Path.Combine(directory,"tmp"));
   File.WriteAllText(Path.Combine(installation,"docker-compose.yml"),"verified compose");File.WriteAllText(Path.Combine(installation,".env"),"PRIVATE=must-never-publish");File.WriteAllText(Path.Combine(installation,"Caddyfile"),Route);
   var p=new Preferences{Managed=true,Installation=installation,ProjectName="photos",ReceiptPath=Path.Combine(directory,"receipt.json")};
   Backend.Containers=new List<ServerContainer>{new ServerContainer{Id=new string('c',64),Image="sha256:"+new string('d',64),Service="caddy",Project="photos",Mounts=new[]{new ServerMount{Destination="/data",Type="volume",Source="/persistent",RW=true}}}};
   File.WriteAllText(p.ReceiptPath,Backend.Json.Serialize(new AdoptionReceipt{RestoreVerified=true,SnapshotSha256=Hash,Containers=Backend.Containers,ConfigurationHashes=Backend.ConfigurationHashes(p)}));return p;
  }
  public static async Task<int> Run(string package){
   var directory=Path.Combine(Path.GetTempPath(),"inhouse downloads "+Guid.NewGuid().ToString("N"));
   var p=Setup(directory);
   try {
    Assert(PublicDownloads.HasDownloadsRoute(Route),"recognises production route and quoted policy");
    Assert(!PublicDownloads.HasDownloadsRoute(Route.Replace("handle_path","# handle_path")),"comment cannot authorise publication");
    Assert(!PublicDownloads.HasDownloadsRoute(Route.Replace("/data/inhouse-downloads","/data/library")),"different root rejected");
    Assert(!PublicDownloads.HasDownloadsRoute(Route+Route),"duplicate route rejected");
    Assert(!PublicDownloads.HasDownloadsRoute(Route.Replace("  file_server","  import extra.conf\n  file_server")),"import cannot alter verified route");
    Assert(!PublicDownloads.HasDownloadsRoute(Route.Replace("  file_server","  rewrite * /secret\n  file_server")),"rewrite rejected");
    var caddy=Backend.Containers[0];Assert(PublicDownloads.WritablePath(caddy,PublicDownloads.Root+"/index.html"),"persistent volume accepted");
    caddy.Mounts[0].RW=false;Assert(!PublicDownloads.WritablePath(caddy,PublicDownloads.Root+"/index.html"),"readonly mount rejected");caddy.Mounts[0].RW=true;
    caddy.Mounts=caddy.Mounts.Concat(new[]{new ServerMount{Destination=PublicDownloads.Root+"/servidor",Type="bind",Source="/custom",RW=false}}).ToArray();
    Assert(!PublicDownloads.WritablePath(caddy,PublicDownloads.Root+"/servidor/index.html"),"more specific readonly mount wins");caddy.Mounts=caddy.Mounts.Take(1).ToArray();
    var old=Catalogue("3.1.96");var next=Catalogue("3.1.97");Assert(PublicDownloads.ParseCatalogue(PublicDownloads.Document(next)).windows.Version=="3.1.97","valid public callback roundtrip");
    Reject(()=>PublicDownloads.ParseCatalogue(PublicDownloads.Document(next)+"alert('bad');"),"trailing executable content");
    var untrusted=Catalogue("3.1.97");untrusted.windows.InstallerUrl=untrusted.windows.InstallerUrl.Replace("github.com","evil.example");Assert(!PublicDownloads.Valid(untrusted.windows),"untrusted download host rejected");
    untrusted=Catalogue("3.1.97");untrusted.android.apkUrl+="?token=secret";Assert(!PublicDownloads.Valid(untrusted.android),"query parameters rejected");
    Assert(PublicDownloads.Merge(next,old).windows.Version=="3.1.97"&&PublicDownloads.Merge(next,old).android.version=="3.1.97","offline fallback cannot downgrade installed catalogue");
    Dictionary<string,byte[]> bundle;using(var stream=File.OpenRead(package))bundle=PublicDownloads.ReadBundle(stream);
    Assert(bundle.Count==9&&!bundle.Keys.Any(n=>n.Contains("..")),"only exact nine public resources packaged");
    var html=PublicDownloads.RefreshHtml(Encoding.UTF8.GetString(bundle["index.html"]),next,true);Assert(html.Contains(next.windows.InstallerUrl)&&html.Contains(next.android.apkUrl)&&html.Contains("Versión 3.1.97"),"HTML offline links and labels refreshed");
    Assert(PublicDownloads.RefreshHtml(Encoding.UTF8.GetString(bundle["servidor/index.html"]),next,false).Contains(next.windows.InstallerUrl),"USB upgrade link refreshed");
    using(var stream=new MemoryStream()){
     using(var zip=new ZipArchive(stream,ZipArchiveMode.Create,true)){using(var output=new StreamWriter(zip.CreateEntry("../library/.env").Open()))output.Write("bad");}
     stream.Position=0;Reject(()=>PublicDownloads.ReadBundle(stream),"archive traversal rejected");
    }
    PublicDownloads.ValidatePublicConfiguration(p);checks++;
    File.WriteAllText(Path.Combine(p.Installation,"docker-compose.yml"),"in flight image change");Reject(()=>PublicDownloads.ValidatePublicConfiguration(p),"unrecognised compose change");
    RuntimeUpdates.Recognised=true;PublicDownloads.ValidatePublicConfiguration(p);checks++;
    File.AppendAllText(Path.Combine(p.Installation,".env"),"changed");Reject(()=>PublicDownloads.ValidatePublicConfiguration(p),"pending journal never permits environment changes");
    File.WriteAllText(Path.Combine(p.Installation,".env"),"PRIVATE=must-never-publish");
    File.AppendAllText(Path.Combine(p.Installation,"Caddyfile"),"changed");Reject(()=>PublicDownloads.ValidatePublicConfiguration(p),"pending journal never permits Caddy changes");File.WriteAllText(Path.Combine(p.Installation,"Caddyfile"),Route);
    var publicRoot=Path.Combine(directory,"public");Directory.CreateDirectory(publicRoot);Directory.CreateDirectory(Path.Combine(publicRoot,"servidor"));
    File.WriteAllText(Path.Combine(publicRoot,"lan.json"),"preserve LAN hints");File.WriteAllText(Path.Combine(publicRoot,"servidor","index.html"),"custom authenticated browser");
    File.WriteAllText(Path.Combine(publicRoot,"servidor","usb.js"),"custom authenticated script");
    var preserved=await PublicDownloads.PublishBundle(p,caddy,bundle,"fixture");Assert(preserved==2,"custom USB resources preserved");
    Assert(File.ReadAllText(Path.Combine(publicRoot,"servidor","index.html"))=="custom authenticated browser"&&File.ReadAllText(Path.Combine(publicRoot,"servidor","usb.js"))=="custom authenticated script","authenticated browser not overwritten");
    Assert(File.ReadAllText(Path.Combine(publicRoot,"lan.json"))=="preserve LAN hints","unrelated files preserved");
    Assert(File.ReadAllText(Path.Combine(p.Installation,".env"))=="PRIVATE=must-never-publish"&&!Directory.GetFiles(publicRoot,"*",SearchOption.AllDirectories).Any(f=>File.ReadAllText(f).Contains("must-never-publish")),"private configuration never published");
    bundle["index.html"]=Encoding.UTF8.GetBytes(html);bundle["download-catalogue.js"]=Encoding.UTF8.GetBytes(PublicDownloads.Document(next));
    await PublicDownloads.PublishBundle(p,caddy,bundle,"fixture");Assert(File.ReadAllText(Path.Combine(publicRoot,"index.html"))==html,"recorded owned HTML upgraded atomically");
    Assert(Directory.GetFiles(Path.Combine(Backend.SettingsDir,"public-downloads"),"*.before",SearchOption.AllDirectories).Length==1&&!Directory.GetFiles(publicRoot,"*.before",SearchOption.AllDirectories).Any(),"prior HTML backup remains private");
    Assert(!Directory.GetFiles(publicRoot,"*.inhouse-*",SearchOption.AllDirectories).Any(),"no incomplete public files remain");
    var writes=Backend.Writes;await PublicDownloads.PublishBundle(p,caddy,bundle,"fixture");Assert(Backend.Writes==writes,"unchanged publication performs no copies");
    var ownership=Path.Combine(Backend.SettingsDir,"public-downloads","fixture-owned.json");File.Delete(ownership);
    await PublicDownloads.PublishBundle(p,caddy,bundle,"fixture");Assert(File.Exists(ownership)&&Backend.Json.Deserialize<Dictionary<string,string>>(File.ReadAllText(ownership)).ContainsKey("index.html"),"matching existing bundle records ownership without copying files");
    File.WriteAllText(Path.Combine(publicRoot,"index.html"),"custom download homepage");
    var custom=await PublicDownloads.PublishBundle(p,caddy,bundle,"fixture");Assert(custom==3&&File.ReadAllText(Path.Combine(publicRoot,"index.html"))=="custom download homepage","unrecognised custom homepage preserved");
    var mark=Path.Combine(publicRoot,"mark.svg");File.Delete(mark);
    try {
     File.CreateSymbolicLink(mark,Path.Combine(p.Installation,".env"));
     try{await PublicDownloads.PublishBundle(p,caddy,bundle,"fixture");throw new Exception("symbolic target accepted");}catch(IOException){checks++;}
     Assert(File.ReadAllText(Path.Combine(p.Installation,".env"))=="PRIVATE=must-never-publish","symbolic target cannot overwrite private data");
    }catch(UnauthorizedAccessException){/* Some Windows hosts do not permit creating test links. */}
    finally{if(File.Exists(mark))File.Delete(mark);}
    return checks;
   }finally{Directory.Delete(directory,true);}
  }
 }
}
'@
$trees=[Microsoft.CodeAnalysis.SyntaxTree[]]@([Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($source),[Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($stubs))
$refs=[Microsoft.CodeAnalysis.MetadataReference[]]@([AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES').Split([IO.Path]::PathSeparator)|ForEach-Object{[Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile($_)})
$options=[Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
$compilation=[Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('PublicDownloadsHarness-'+[Guid]::NewGuid().ToString('N'),$trees,$refs,$options)
$stream=New-Object IO.MemoryStream
try {
  $result=$compilation.Emit($stream)
  if(-not $result.Success){$result.Diagnostics|ForEach-Object{$_.ToString()};exit 1}
  $assembly=[Reflection.Assembly]::Load($stream.ToArray())
  $task=$assembly.GetType('InhousePhotos.Harness').GetMethod('Run').Invoke($null,[object[]]@([string]$package))
  $count=$task.GetAwaiter().GetResult()
  Write-Output "$count public download safety and real-file publication checks passed."
}finally{$stream.Dispose();if([IO.File]::Exists($package)){[IO.File]::Delete($package)}}
