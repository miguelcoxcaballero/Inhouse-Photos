using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;

namespace InhousePhotos {
  /// A child can retain inherited pipe handles after PowerShell has exited.
  /// Process exit is checked by the caller; draining its output has its own bound.
  public static class RuntimeProcessOutput {
    static void Observe(Task task) {
      task.ContinueWith(failed=>{var observed=failed.Exception;},CancellationToken.None,
        TaskContinuationOptions.OnlyOnFaulted|TaskContinuationOptions.ExecuteSynchronously,TaskScheduler.Default);
    }
    public static async Task<bool> Drain(Process process,Task stderr,Task stdoutClosed,int timeoutMilliseconds=3000) {
      if(process==null)throw new ArgumentNullException("process");
      if(stderr==null)throw new ArgumentNullException("stderr");
      if(stdoutClosed==null)throw new ArgumentNullException("stdoutClosed");
      if(timeoutMilliseconds<=0)throw new ArgumentOutOfRangeException("timeoutMilliseconds");
      Observe(stderr);Observe(stdoutClosed);
      var output=Task.WhenAll(stderr,stdoutClosed);Observe(output);
      if(await Task.WhenAny(output,Task.Delay(timeoutMilliseconds))==output) {
        try{await output;return true;}catch{ /* Close failed readers below. */ }
      }
      // Closing the known readers must not replace one unbounded wait with
      // another. The task owns only this already-exited process's pipe handles.
      var close=Task.Run(()=>{
        try{process.CancelOutputRead();}catch{}
        try{process.StandardError.Close();}catch{}
        try{process.StandardOutput.Close();}catch{}
      });
      Observe(close);
      await Task.WhenAny(close,Task.Delay(100));
      return false;
    }
  }
}
