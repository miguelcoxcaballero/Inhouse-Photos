using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

namespace InhousePhotos {
  public sealed class BackupCapacityEstimate {
    // The media copy uses robocopy /XC /XN /XO, so an existing destination
    // file is deliberately not counted again even when its metadata differs.
    public long MissingMediaBytes { get; internal set; }
    public long HeadroomBytes { get; internal set; }
    public long RequiredBytes { get; internal set; }
    public long FreeBytes { get; internal set; }
    public long FilesToCopy { get; internal set; }
    public long FilesExamined { get; internal set; }
    public bool EnoughSpace { get { return FreeBytes >= RequiredBytes; } }
    internal readonly List<BackupFileStamp> PendingFiles=new List<BackupFileStamp>();
  }

  internal sealed class BackupFileStamp {
    internal readonly string Destination;
    internal readonly long Length;
    internal readonly DateTime ModifiedUtc;
    internal BackupFileStamp(string destination,long length,DateTime modifiedUtc) {
      Destination=destination;Length=length;ModifiedUtc=modifiedUtc;
    }
  }

  public sealed class InsufficientBackupSpaceException : IOException {
    public BackupCapacityEstimate Estimate { get; private set; }

    public InsufficientBackupSpaceException(BackupCapacityEstimate estimate)
      : base("No hay espacio suficiente en el disco de copia. Se necesitan aproximadamente " +
             Backend.Size(estimate == null ? 0 : estimate.RequiredBytes) + " y hay " +
             Backend.Size(estimate == null ? 0 : estimate.FreeBytes) + " libres.") {
      Estimate=estimate;
    }
  }

  public static partial class Backend {
    const long BackupHeadroomFloorBytes=5L*1024*1024*1024;
    const long BackupPreflightMaxEntries=10000000L;

    sealed class BackupScanFrame : IDisposable {
      public readonly IEnumerator<FileSystemInfo> Entries;
      public readonly string TargetDirectory;
      public readonly bool TargetExists;

      public BackupScanFrame(string sourceDirectory,string targetDirectory,bool targetExists) {
        Entries=new DirectoryInfo(sourceDirectory).EnumerateFileSystemInfos().GetEnumerator();
        TargetDirectory=targetDirectory;
        TargetExists=targetExists;
      }

      public void Dispose() { Entries.Dispose(); }
    }

    // backupTarget is the "Inhouse Photos backup" directory, not its parent
    // disk/folder. This method reads metadata only: it creates no directories,
    // snapshots or files. It must run before Snapshot(), on a worker thread.
    // The estimate is a preflight, not a guarantee against files growing or
    // another process consuming free space while the copy runs.
    public static BackupCapacityEstimate EstimateBackupCapacity(string source,string backupTarget,CancellationToken token) {
      return EstimateBackupCapacity(source,backupTarget,token,null);
    }

    public static BackupCapacityEstimate EstimateBackupCapacity(string source,string backupTarget,CancellationToken token,Action<long> onProgress) {
      token.ThrowIfCancellationRequested();
      if(String.IsNullOrWhiteSpace(source)||String.IsNullOrWhiteSpace(backupTarget))
        throw new ArgumentException("Selecciona la biblioteca y el disco de copia.");
      source=Path.GetFullPath(source);
      backupTarget=Path.GetFullPath(backupTarget);
      ValidateBackup(source,backupTarget);
      if(!Directory.Exists(source))throw new IOException("La biblioteca no está disponible para comprobar el espacio de copia.");
      if(String.Equals(source.TrimEnd('\\'),Path.GetPathRoot(source).TrimEnd('\\'),StringComparison.OrdinalIgnoreCase))
        throw new IOException("La biblioteca no puede ser la raíz de un disco.");
      if(File.Exists(backupTarget))throw new IOException("El destino de copia no es una carpeta.");

      var mediaTarget=Path.Combine(backupTarget,"library");
      RejectLinks(mediaTarget);
      var mediaTargetExists=Directory.Exists(mediaTarget);
      if(!mediaTargetExists&&File.Exists(mediaTarget))
        throw new IOException("El destino de fotos de la copia no es una carpeta.");

      var result=new BackupCapacityEstimate();
      var stack=new Stack<BackupScanFrame>();
      long entriesExamined=0;
      try {
        stack.Push(new BackupScanFrame(source,mediaTarget,mediaTargetExists));
        while(stack.Count>0) {
          token.ThrowIfCancellationRequested();
          var frame=stack.Peek();
          if(!frame.Entries.MoveNext()) {frame.Dispose();stack.Pop();continue;}
          var item=frame.Entries.Current;
          if(++entriesExamined>BackupPreflightMaxEntries)
            throw new IOException("La biblioteca tiene demasiados elementos para comprobar el espacio con seguridad.");
          if(onProgress!=null&&entriesExamined%1000==0)onProgress(entriesExamined);
          var attributes=item.Attributes;
          // Robocopy /XJ never follows junctions. Refuse all reparse points
          // instead of silently claiming a complete backup with missing data.
          if((attributes&FileAttributes.ReparsePoint)!=0)
            throw new IOException("La biblioteca contiene un enlace o carpeta redirigida. No se puede confirmar una copia completa.");
          var targetPath=Path.Combine(frame.TargetDirectory,item.Name);
          if((attributes&FileAttributes.Directory)!=0) {
            var targetExists=frame.TargetExists&&Directory.Exists(targetPath);
            if(frame.TargetExists&&!targetExists&&File.Exists(targetPath))
              throw new IOException("Un archivo del destino ocupa la carpeta necesaria para la copia.");
            if(targetExists&&((new DirectoryInfo(targetPath).Attributes&FileAttributes.ReparsePoint)!=0))
              throw new IOException("El destino contiene una carpeta redirigida. Elige otro destino de copia.");
            stack.Push(new BackupScanFrame(item.FullName,targetPath,targetExists));
          } else {
            result.FilesExamined=checked(result.FilesExamined+1);
            var existing=frame.TargetExists&&File.Exists(targetPath);
            if(existing&&((new FileInfo(targetPath).Attributes&FileAttributes.ReparsePoint)!=0))
              throw new IOException("El destino contiene un archivo enlazado. Elige otro destino de copia.");
            var sourceFile=(FileInfo)item;
            if(existing) {
              var targetFile=new FileInfo(targetPath);
              // Existing files are never overwritten. A changed file would
              // make an append-only copy look complete while keeping stale
              // bytes, so fail closed before recording a successful backup.
              if(sourceFile.Length!=targetFile.Length||
                  Math.Abs((sourceFile.LastWriteTimeUtc-targetFile.LastWriteTimeUtc).TotalSeconds)>2)
                throw new IOException("Un archivo existente ha cambiado desde la copia anterior. Para conservar esa copia sin sobrescribirla, elige una carpeta vacía como nuevo destino y haz una copia completa.");
            } else {
              var length=sourceFile.Length;
              result.MissingMediaBytes=checked(result.MissingMediaBytes+length);
              result.FilesToCopy=checked(result.FilesToCopy+1);
              result.PendingFiles.Add(new BackupFileStamp(targetPath,length,sourceFile.LastWriteTimeUtc));
            }
          }
        }
      } catch(UnauthorizedAccessException error) {
        throw new IOException("No se pudieron leer todos los archivos de la biblioteca o el destino. La copia no puede empezar con una estimación incompleta.",error);
      } catch(OverflowException error) {
        throw new IOException("La biblioteca es demasiado grande para estimar el espacio de copia con seguridad.",error);
      } finally {
        while(stack.Count>0)stack.Pop().Dispose();
      }

      var root=Path.GetPathRoot(backupTarget);
      var drive=new DriveInfo(root);
      if(!drive.IsReady)throw new IOException("El disco de copia no está disponible.");
      result.FreeBytes=drive.AvailableFreeSpace;
      // A full backup also creates a fresh SQL snapshot. Reserve at least
      // 5 GiB for it and filesystem headroom, or 10% for larger copies.
      try {
        var tenPercent=result.MissingMediaBytes/10+(result.MissingMediaBytes%10==0?0:1);
        result.HeadroomBytes=Math.Max(BackupHeadroomFloorBytes,tenPercent);
        result.RequiredBytes=checked(result.MissingMediaBytes+result.HeadroomBytes);
      } catch(OverflowException error) {
        throw new IOException("La biblioteca es demasiado grande para estimar el espacio de copia con seguridad.",error);
      }
      return result;
    }

    // The preflight has already examined every source file. Re-enumerating
    // ~100,000 files on a slow disk after robocopy would add many minutes.
    // Confirm only files that were absent at preflight, against the metadata
    // captured then; robocopy's exit status covers its own copy failures.
    public static void VerifyPendingBackupFiles(BackupCapacityEstimate estimate,CancellationToken token,Action<long> onProgress) {
      if(estimate==null)throw new ArgumentNullException("estimate");
      long checkedFiles=0;
      foreach(var stamp in estimate.PendingFiles) {
        token.ThrowIfCancellationRequested();
        if(!File.Exists(stamp.Destination))
          throw new IOException("Falta un archivo en la copia. No se marcará como terminada.");
        var file=new FileInfo(stamp.Destination);
        if((file.Attributes&FileAttributes.ReparsePoint)!=0||file.Length!=stamp.Length||
            Math.Abs((file.LastWriteTimeUtc-stamp.ModifiedUtc).TotalSeconds)>2)
          throw new IOException("Un archivo copiado no coincide con el original. No se marcará la copia como terminada.");
        if(++checkedFiles%1000==0&&onProgress!=null)onProgress(checkedFiles);
      }
    }
  }
}
