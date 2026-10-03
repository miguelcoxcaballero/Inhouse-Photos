using System;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;

namespace InhousePhotos {
  /// The web installer carries a bounded, separately SHA-256-pinned runtime ZIP.
  /// It is appended to the PE rather than loaded as an 800 MB CLR resource.
  /// The compact updater and stable launcher remain small executables.
  public static class FullInstallerPackage {
    const string Marker="INHOUSE_FULL_V1!";
    const int FooterSize=32;
    static long PayloadOffset(string source,out long length) {
      length=0;
      using(var input=File.OpenRead(source)) {
        if(input.Length<FooterSize)return -1;
        input.Seek(-FooterSize,SeekOrigin.End);
        using(var reader=new BinaryReader(input,Encoding.ASCII,true)) {
          if(Encoding.ASCII.GetString(reader.ReadBytes(16))!=Marker)return -1;
          var compactLength=reader.ReadInt64();length=reader.ReadInt64();
          if(compactLength<65536||compactLength>20L*1024*1024||length<1||length>2L*1024*1024*1024||
            compactLength+length+FooterSize!=input.Length)
            throw new IOException("El instalador completo está incompleto. Descárgalo de nuevo desde la web.");
          return compactLength;
        }
      }
    }
    static string HashRange(string source,long offset,long length) {
      using(var input=File.OpenRead(source))using(var sha=System.Security.Cryptography.SHA256.Create()) {
        input.Position=offset;var buffer=new byte[1024*1024];
        while(length>0) {
          var count=input.Read(buffer,0,(int)Math.Min(buffer.Length,length));
          if(count<=0)throw new EndOfStreamException("La descarga del instalador no está completa.");
          sha.TransformBlock(buffer,0,count,buffer,0);length-=count;
        }
        sha.TransformFinalBlock(new byte[0],0,0);
        return BitConverter.ToString(sha.Hash).Replace("-","").ToLowerInvariant();
      }
    }
    public static void Verify(string source) {
      long length;var offset=PayloadOffset(source,out length);
      if(offset<0||HashRange(source,offset,length)!=RuntimeUpdates.PackageSha256)
        throw new IOException("El motor incluido no coincide con esta versión. No se instalará.");
    }
    public static Task Import(string source,Action<string> notify) {
      return Task.Run(()=>{
        long length;var offset=PayloadOffset(source,out length);
        if(offset<0)return; // The compact in-app updater fetches the same pinned ZIP.
        notify("Comprobando el motor incluido en el instalador…");
        Verify(source);
        var directory=Path.Combine(Backend.SettingsDir,"runtime-components",RuntimeUpdates.LatestVersion);
        Backend.PrivateDirectory(directory);
        var target=Path.Combine(directory,RuntimeUpdates.PackageFile);
        if(File.Exists(target)&&((File.GetAttributes(target)&FileAttributes.ReparsePoint)!=0||new FileInfo(target).Length>2L*1024*1024*1024))
          throw new IOException("El paquete guardado necesita revisarse antes de instalar.");
        if(File.Exists(target)&&Backend.Hash(target)==RuntimeUpdates.PackageSha256)return;
        if(new DriveInfo(Path.GetPathRoot(directory)).AvailableFreeSpace<length+4L*1024*1024*1024)
          throw new IOException("Necesitas al menos 5 GB libres para preparar la instalación completa.");
        var partial=target+"."+Guid.NewGuid().ToString("N")+".partial";
        try {
          notify("Preparando el motor incluido, sin otra descarga…");
          using(var input=File.OpenRead(source))using(var output=new FileStream(partial,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {
            input.Position=offset;var remaining=length;var buffer=new byte[1024*1024];
            while(remaining>0) {
              var count=input.Read(buffer,0,(int)Math.Min(buffer.Length,remaining));
              if(count==0)throw new EndOfStreamException("La descarga del instalador no está completa.");
              output.Write(buffer,0,count);remaining-=count;
            }
            output.Flush(true);
          }
          if(Backend.Hash(partial)!=RuntimeUpdates.PackageSha256)throw new IOException("El motor no pasa la comprobación de integridad.");
          if(File.Exists(target))File.Replace(partial,target,null);else File.Move(partial,target);
        }finally{if(File.Exists(partial))File.Delete(partial);}
      });
    }
    public static void CopyLauncher(string source,string target) {
      long packageLength;var offset=PayloadOffset(source,out packageLength);
      if(offset<0){File.Copy(source,target,false);return;}
      using(var input=File.OpenRead(source))using(var output=new FileStream(target,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {
        var remaining=offset;var buffer=new byte[65536];
        while(remaining>0) {
          var count=input.Read(buffer,0,(int)Math.Min(buffer.Length,remaining));
          if(count==0)throw new EndOfStreamException();
          output.Write(buffer,0,count);remaining-=count;
        }
        output.Flush(true);
      }
    }
  }
}
