using System;
using System.Globalization;
using System.IO;
using System.Text;

namespace InhousePhotos {
  // This is a record of the full media + database backup workflow. A database
  // snapshot (including the adoption/restore-test snapshot) is not a photo backup.
  public sealed class FullBackupStatus {
    public string Destination { get; set; }
    public string CompletedUtc { get; set; }
    public string BackupFolder { get; set; }
    public string MediaFolder { get; set; }
    public string DatabaseFile { get; set; }
    public bool HasCompletedRecord { get; set; }
    public bool FilesPresent { get; set; }
    public string Message { get; set; }
  }

  // Kept separate from Preferences: changing the backup disk must not erase the
  // date or location of the last completed copy on the previous disk.
  public sealed class FullBackupRecord {
    public int Format { get; set; }
    public string Installation { get; set; }
    public string SourceLibrary { get; set; }
    public string Destination { get; set; }
    public string BackupFolder { get; set; }
    public string DatabaseFile { get; set; }
    public long DatabaseBytes { get; set; }
    public string CompletedUtc { get; set; }
  }

  public static partial class Backend {
    static string FullBackupRecordPath { get { return Path.Combine(SettingsDir,"last-full-backup.json"); } }

    static bool SameFullPath(string left,string right) {
      return String.Equals(Path.GetFullPath(left).TrimEnd('\\'),Path.GetFullPath(right).TrimEnd('\\'),StringComparison.OrdinalIgnoreCase);
    }

    static bool IsDirectChild(string parent,string child) {
      var directory=Path.GetDirectoryName(Path.GetFullPath(child));
      return !String.IsNullOrEmpty(directory) && SameFullPath(parent,directory);
    }

    static bool IsSqlDump(string path) {
      if(!String.Equals(Path.GetExtension(path),".sql",StringComparison.OrdinalIgnoreCase))return false;
      using(var reader=new StreamReader(path,Encoding.UTF8,true)) {
        var header=new char[256];var count=reader.Read(header,0,header.Length);
        return new string(header,0,count).Contains("PostgreSQL database dump");
      }
    }

    // Call only after the media copy AND the database dump copy have completed
    // successfully. This does not certify that a restore has been tested.
    public static FullBackupStatus SaveFullBackupSuccess(Preferences p,string target,string snapshotPath) {
      if(p==null)throw new ArgumentNullException("p");
      if(String.IsNullOrWhiteSpace(p.Installation)||String.IsNullOrWhiteSpace(p.BackupDestination))
        throw new InvalidOperationException("Selecciona un servidor y un disco de copia antes de guardar el resultado.");
      var installation=Path.GetFullPath(p.Installation);
      var library=Library(p);
      var destination=Path.GetFullPath(p.BackupDestination);
      ValidateBackup(library,destination);
      if(String.IsNullOrWhiteSpace(target)||String.IsNullOrWhiteSpace(snapshotPath))
        throw new ArgumentException("La copia de archivos y la de la base de datos deben estar completas.");
      target=Path.GetFullPath(target);snapshotPath=Path.GetFullPath(snapshotPath);
      var expected=Path.GetFullPath(Path.Combine(destination,"Inhouse Photos backup"));
      var media=Path.Combine(target,"library");
      if(!SameFullPath(target,expected)||!IsDirectChild(target,snapshotPath)||
          !Directory.Exists(media)||!File.Exists(snapshotPath))
        throw new IOException("Faltan los archivos o la base de datos de la copia completa.");
      RejectLinks(target);RejectLinks(media);RejectLinks(snapshotPath);
      if((File.GetAttributes(snapshotPath)&FileAttributes.ReparsePoint)!=0||
          (File.GetAttributes(media)&FileAttributes.ReparsePoint)!=0)
        throw new IOException("La copia no puede apuntar a un enlace o carpeta redirigida.");
      var databaseBytes=new FileInfo(snapshotPath).Length;
      if(databaseBytes==0||!IsSqlDump(snapshotPath))
        throw new IOException("La copia de la base de datos no es válida. No se marcará la copia como terminada.");
      var record=new FullBackupRecord {
        Format=1,Installation=installation,SourceLibrary=library,Destination=destination,
        BackupFolder=target,DatabaseFile=snapshotPath,DatabaseBytes=databaseBytes,
        CompletedUtc=DateTime.UtcNow.ToString("o",CultureInfo.InvariantCulture)
      };
      PrivateDirectory(SettingsDir);
      var path=FullBackupRecordPath;
      var temp=path+"."+RandomHex(8)+".new";
      try {
        File.WriteAllText(temp,Json.Serialize(record),new UTF8Encoding(false));
        if(File.Exists(path))File.Replace(temp,path,null);else File.Move(temp,path);
      } finally {if(File.Exists(temp))File.Delete(temp);}
      return ReadFullBackupStatus(p);
    }

    // Read-only, inexpensive filesystem checks. FilesPresent means the media
    // directory and this SQL file are still there; it is NOT a restore test or
    // a per-photo integrity verification.
    public static FullBackupStatus ReadFullBackupStatus(Preferences p) {
      var status=new FullBackupStatus {
        Destination=p==null?null:p.BackupDestination,
        Message="Todavía no se ha terminado una copia de fotos y base de datos desde este gestor."
      };
      if(p==null)return status;
      try {
        if(!File.Exists(FullBackupRecordPath))return status;
        var record=Json.Deserialize<FullBackupRecord>(File.ReadAllText(FullBackupRecordPath));
        DateTime completed;
        if(record==null||record.Format!=1||String.IsNullOrWhiteSpace(record.Installation)||
           String.IsNullOrWhiteSpace(record.SourceLibrary)||String.IsNullOrWhiteSpace(record.Destination)||
           String.IsNullOrWhiteSpace(record.BackupFolder)||String.IsNullOrWhiteSpace(record.DatabaseFile)||
           record.DatabaseBytes<=0||!DateTime.TryParseExact(record.CompletedUtc,"o",CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind,out completed)||
           completed.ToUniversalTime()>DateTime.UtcNow.AddMinutes(5)||
           !SameFullPath(record.Installation,p.Installation)||!SameFullPath(record.SourceLibrary,Library(p))||
           !SameFullPath(record.BackupFolder,Path.Combine(record.Destination,"Inhouse Photos backup"))||
           !IsDirectChild(record.BackupFolder,record.DatabaseFile))return status;
        status.HasCompletedRecord=true;
        status.CompletedUtc=record.CompletedUtc;
        status.BackupFolder=record.BackupFolder;
        status.MediaFolder=Path.Combine(record.BackupFolder,"library");
        status.DatabaseFile=record.DatabaseFile;
        status.FilesPresent=Directory.Exists(status.MediaFolder)&&File.Exists(status.DatabaseFile)&&
          new FileInfo(status.DatabaseFile).Length==record.DatabaseBytes;
        if(status.FilesPresent) {
          RejectLinks(status.MediaFolder);RejectLinks(status.DatabaseFile);
          status.FilesPresent=(File.GetAttributes(status.MediaFolder)&FileAttributes.ReparsePoint)==0&&
            (File.GetAttributes(status.DatabaseFile)&FileAttributes.ReparsePoint)==0;
        }
        status.Message=status.FilesPresent?
          "Copia de fotos y base de datos terminada. El destino y el archivo SQL están presentes; no se ha comprobado cada foto ni probado una restauración.":
          "La última copia terminada no está disponible ahora. Conecta el disco y comprueba los archivos antes de depender de ella.";
      }catch(IOException){status.FilesPresent=false;}
      catch(UnauthorizedAccessException){status.FilesPresent=false;}
      catch(ArgumentException){status.FilesPresent=false;}
      catch(InvalidOperationException){status.FilesPresent=false;}
      if(status.HasCompletedRecord&&!status.FilesPresent)
        status.Message="La última copia terminada no está disponible ahora. Conecta el disco y comprueba los archivos antes de depender de ella.";
      return status;
    }
  }
}
