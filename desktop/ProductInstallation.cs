using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace InhousePhotos {
  /// Installer completion runs in the hash-verified installed manager, keeping
  /// the same helper process identity and transaction checks as remote updates.
  public static class ProductInstallation {
    internal static string StageMessage(string stage) {
      switch(stage) {
        case "verify":return "Comprobando tu biblioteca y la copia de recuperación…";
        case "download":return "Preparando los componentes de esta versión…";
        case "image":return "Preparando el motor de fotos…";
        case "queues":return "Conservando los trabajos de procesamiento pendientes…";
        case "quiesce":return "Esperando a que termine el procesamiento activo, sin perder trabajos…";
        case "recovery":return "Recuperando la instalación anterior antes de continuar…";
        case "restart":return "Iniciando el servidor actualizado…";
        case "receipt":return "Verificando el servidor y la biblioteca…";
        case "complete":return "Instalación completa verificada.";
        default:return null;
      }
    }
    public static int Complete() {
      using(var manager=new Mutex(false,@"Local\InhousePhotosServer")) {
        bool owned=false;
        try {
          try{owned=manager.WaitOne(0);}catch(AbandonedMutexException){owned=true;}
          if(!owned)throw new IOException("Inhouse Photos sigue abierto. Cierra el programa antes de terminar la instalación.");
          var installed=SetupProgram.ReadInstalled();
          if(installed.Version!=Backend.Version||Backend.Hash(System.Reflection.Assembly.GetExecutingAssembly().Location)!=installed.Sha256)
            throw new IOException("El programa activo no coincide con la instalación verificada.");
          var prefs=Backend.Load();
          if(!prefs.Managed)throw new IOException("Selecciona primero dónde guardar la biblioteca.");
          Console.WriteLine("INHOUSE_INSTALL_STAGE:verify");
          using(var bridge=new RemoteManagement(prefs,async()=>new RemoteManagerStatus {
            Version=SystemUpdates.Status().CurrentVersion,ServerOnline=await Backend.Ping(prefs.LocalEndpoint),Busy=true,
            Operation="system-update",SystemUpdate=SystemUpdates.Status(),RuntimeUpdate=RuntimeUpdates.Status(),Disks=new RemoteDiskStatus[0]
          },action=>Task.FromResult(false),()=>true)) {
          var completion=SystemUpdates.CompletePinnedInstallation(prefs);
          string previous="";
          while(!completion.IsCompleted) {
            var current=RuntimeUpdates.Status();
            var stage=current.Stage;
            if(current.Phase=="downloading")stage="download";
            if(stage!=previous&&StageMessage(stage)!=null){previous=stage;Console.WriteLine("INHOUSE_INSTALL_STAGE:"+stage);}
            Thread.Sleep(250);
          }
          completion.GetAwaiter().GetResult();
          }
          Console.WriteLine("INHOUSE_INSTALL_STAGE:complete");
          return 0;
        }catch(Exception ex){Console.Error.WriteLine(ex.Message);return 1;}
        finally{if(owned)manager.ReleaseMutex();}
      }
    }
  }
}
