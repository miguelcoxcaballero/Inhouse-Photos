using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace InhousePhotos {
  public sealed class StorageDisk {
    public string PhysicalId {get;set;} public string DiskId {get;set;} public string Serial {get;set;} public string Model {get;set;}
    public long Size {get;set;} public bool Eligible {get;set;} public string Reason {get;set;}
  }
  public sealed class StoragePoolInfo {public string Id {get;set;} public string Name {get;set;} public long Size {get;set;} public long Free {get;set;} public string Health {get;set;} public override string ToString(){return Name+" · "+Backend.Size(Free)+" libres";}}
  public sealed class StorageInventory {public List<StorageDisk> Disks {get;set;} public List<StoragePoolInfo> Pools {get;set;}}
  public static class StorageBackend {
    public static string Script {get{using(var resource=typeof(StorageBackend).Assembly.GetManifestResourceStream("InhousePhotos.storage.ps1"))using(var reader=new StreamReader(resource))return reader.ReadToEnd();}}
    public static Task<string> Execute(string action,object request,int timeout=30) {
      if(!new[]{"Inspect","Create","Add"}.Contains(action))throw new ArgumentException("Operación no válida.");
      var encoded=Convert.ToBase64String(Encoding.UTF8.GetBytes(Backend.Json.Serialize(request)));
      return Backend.PowerShell("& {\n"+Script+"\n} -Action "+action+" -RequestBase64 '"+encoded+"'",timeout);
    }
    public static void ValidateSelection(IEnumerable<StorageDisk> disks,string mode,bool add) {
      var list=disks.ToList();var minimum=add?1:mode=="Mirror"?2:mode=="Parity"?3:99;
      if(list.Count<minimum||list.Count>16||list.Any(d=>!d.Eligible||String.IsNullOrWhiteSpace(d.PhysicalId)||String.IsNullOrWhiteSpace(d.DiskId)||String.IsNullOrWhiteSpace(d.Serial)||d.Size<16L*1024*1024*1024)||list.Select(d=>d.PhysicalId).Distinct().Count()!=list.Count)
        throw new InvalidOperationException("Selecciona suficientes discos vacíos, identificados y en buen estado.");
    }
  }
  public sealed class StorageWindow:Window {
    readonly StackPanel rows=new StackPanel();readonly TextBlock status=new TextBlock();readonly ComboBox mode=new ComboBox();readonly ComboBox pool=new ComboBox();readonly TextBox confirmation=new TextBox();
    readonly Dictionary<CheckBox,StorageDisk> selection=new Dictionary<CheckBox,StorageDisk>();bool busy;
    public StorageWindow() {
      Title="Inhouse Photos · Discos protegidos";Width=760;Height=760;MinWidth=640;MinHeight=600;WindowStartupLocation=WindowStartupLocation.CenterScreen;Background=new SolidColorBrush(Color.FromRgb(19,17,14));Foreground=Brushes.White;FontFamily=new FontFamily("Segoe UI");FontSize=16;
      var panel=new StackPanel{Margin=new Thickness(32)};Content=new ScrollViewer{Content=panel,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
      panel.Children.Add(Text("Discos y redundancia",30));panel.Children.Add(Text("Solo puedes seleccionar discos vacíos sin particiones. La biblioteca actual y el disco de Windows están protegidos. RAID no sustituye una copia de seguridad.",15));panel.Children.Add(rows);
      mode.Items.Add("Espejo · mínimo 2 discos");mode.Items.Add("Paridad · mínimo 3 discos");mode.Items.Add("Añadir discos a un grupo existente");mode.SelectedIndex=0;mode.Margin=new Thickness(0,16,0,10);panel.Children.Add(mode);panel.Children.Add(pool);pool.Visibility=Visibility.Collapsed;
      mode.SelectionChanged+=(s,e)=>pool.Visibility=mode.SelectedIndex==2?Visibility.Visible:Visibility.Collapsed;
      panel.Children.Add(Text("Para confirmar el uso de los discos seleccionados, escribe CREAR.",15));confirmation.Margin=new Thickness(0,10,0,12);confirmation.Padding=new Thickness(10);panel.Children.Add(confirmation);
      var button=new Button{Content="Revisar y aplicar",Padding=new Thickness(18,12,18,12),Background=new SolidColorBrush(Color.FromRgb(237,153,90)),Foreground=Brushes.Black};panel.Children.Add(button);
      status.TextWrapping=TextWrapping.Wrap;status.Margin=new Thickness(0,16,0,0);panel.Children.Add(status);
      button.Click+=async(s,e)=>{
        if(busy)return;
        try {
          var selected=selection.Where(x=>x.Key.IsChecked==true).Select(x=>x.Value).ToList();var add=mode.SelectedIndex==2;var resiliency=mode.SelectedIndex==1?"Parity":"Mirror";
          StorageBackend.ValidateSelection(selected,resiliency,add);
          if(confirmation.Text!="CREAR")throw new InvalidOperationException("Escribe CREAR para confirmar.");
          var destination=pool.SelectedItem as StoragePoolInfo;if(add&&destination==null)throw new InvalidOperationException("Selecciona el grupo de destino.");
          var summary=String.Join("\n",selected.Select(d=>d.Model+" · "+d.Serial+" · "+Backend.Size(d.Size)));
          if(MessageBox.Show(this,"Se utilizarán exclusivamente estos discos vacíos:\n\n"+summary+"\n\nLa operación cambia su organización de almacenamiento. ¿Continuar?","Confirmar discos",MessageBoxButton.OKCancel,MessageBoxImage.Warning)!=MessageBoxResult.OK)return;
          busy=true;button.IsEnabled=false;status.Text="Configurando almacenamiento. No desconectes los discos…";
          var result=Backend.Json.Deserialize<Dictionary<string,object>>(await StorageBackend.Execute(add?"Add":"Create",new{Disks=selected,Mode=resiliency,PoolId=destination==null?null:destination.Id,Confirmation=confirmation.Text},900));
          status.Text=Convert.ToString(result["Message"]);confirmation.Clear();await LoadDisks();
        }catch(Exception ex){status.Text=ex.Message+" Si se creó un grupo parcialmente, se conserva; no se deshacen operaciones borrando discos.";}
        finally{busy=false;button.IsEnabled=true;}
      };
      Loaded+=async(s,e)=>{try{await LoadDisks();}catch(Exception ex){status.Text=ex.Message;}};
      Closing+=(s,e)=>{if(busy){e.Cancel=true;status.Text="Espera a que Windows confirme el resultado antes de cerrar.";}};
    }
    TextBlock Text(string text,double size){return new TextBlock{Text=text,FontSize=size,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,14)};}
    async Task LoadDisks() {
      var inventory=Backend.Json.Deserialize<StorageInventory>(await StorageBackend.Execute("Inspect",null));rows.Children.Clear();selection.Clear();pool.Items.Clear();
      foreach(var disk in inventory.Disks){var box=new CheckBox{Content=disk.Model+" · "+Backend.Size(disk.Size)+"\n"+disk.Serial+" · "+disk.Reason,IsEnabled=disk.Eligible,Foreground=Foreground,Margin=new Thickness(0,12,0,12)};rows.Children.Add(box);selection.Add(box,disk);}
      foreach(var item in inventory.Pools)pool.Items.Add(item);
      if(!inventory.Disks.Any(d=>d.Eligible))status.Text="No hay discos vacíos disponibles. Conecta discos nuevos; los que contienen datos no se pueden seleccionar.";
    }
  }
}
