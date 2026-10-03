#Requires -Version 7.4
# The real parent exits while its owned Python child retains both output pipes.
# No manager, installer, Docker process or managed library is changed.
$ErrorActionPreference='Stop'
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'RuntimeProcessOutput.cs'))
$harness=@'
namespace InhousePhotos {
 using System;using System.Diagnostics;using System.IO;using System.Threading;using System.Threading.Tasks;
 public static class RuntimeOutputHarness {
  static int checks;static void Assert(bool condition,string name){if(!condition)throw new Exception(name);checks++;}
  static Process Start(string python,string code,TaskCompletionSource<bool> eof,Action<string> line) {
   var process=new Process{StartInfo=new ProcessStartInfo(python,"-c \""+code+"\""){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true}};
   process.OutputDataReceived+=(s,e)=>{if(e.Data==null)eof.TrySetResult(true);else line(e.Data);};
   process.Start();process.BeginOutputReadLine();return process;
  }
  public static async Task<int> Run(string python) {
   var normalEof=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);string normalLine="";
   using(var normal=Start(python,"import sys; print('normal-output',flush=True); print('normal-error',file=sys.stderr,flush=True)",normalEof,line=>normalLine=line)) {
    var stderr=normal.StandardError.ReadToEndAsync();Assert(normal.WaitForExit(10000),"normal parent exits");
    Assert(await RuntimeProcessOutput.Drain(normal,stderr,normalEof.Task,3000),"normal output reaches EOF within the independent deadline");
    Assert(normalLine=="normal-output"&&await stderr=="normal-error"+Environment.NewLine,"normal drain preserves output and diagnostics");
   }
   var eof=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
   var childPid=new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
   Process child=null;
   using(var parent=Start(python,"import subprocess,sys; child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)']); print(child.pid,flush=True)",eof,line=>{int id;if(int.TryParse(line,out id))childPid.TrySetResult(id);})) {
    var stderr=parent.StandardError.ReadToEndAsync();
    try {
     Assert(parent.WaitForExit(10000),"parent exits while its owned child remains");
     if(await Task.WhenAny(childPid.Task,Task.Delay(3000))!=childPid.Task)throw new Exception("owned child PID was not received");
     child=Process.GetProcessById(await childPid.Task);
     Assert(!child.HasExited&&(!eof.Task.IsCompleted||!stderr.IsCompleted),"fixture really retains a pipe after the parent exits");
     var clock=Stopwatch.StartNew();var drained=await RuntimeProcessOutput.Drain(parent,stderr,eof.Task,150);
     Assert(!drained&&clock.ElapsedMilliseconds<2500,"inherited pipes cannot turn output draining into an unbounded wait");
     Assert(!child.HasExited,"draining closes readers without killing the owned child");
    }finally {if(child!=null){try{if(!child.HasExited)child.Kill();child.WaitForExit(3000);}finally{child.Dispose();}}}
   }
   var disposed=new Process();disposed.Dispose();
   var failed=Task.FromException(new IOException("controlled read failure"));
   Assert(!await RuntimeProcessOutput.Drain(disposed,failed,Task.CompletedTask,50),"faulted output and disposed process are observed without throwing");
   Assert(!await RuntimeProcessOutput.Drain(disposed,Task.CompletedTask,Task.FromCanceled(new CancellationToken(true)),50),"cancelled output cannot be reported as a complete drain");
   return checks;
  }
 }
}
'@
Add-Type -TypeDefinition ($source+$harness)
$python=[string](Get-Command python -ErrorAction Stop).Source
$task=[InhousePhotos.RuntimeOutputHarness]::Run($python)
$count=$task.GetAwaiter().GetResult()
Write-Output "$count runtime process output checks passed with real inherited output pipes."
