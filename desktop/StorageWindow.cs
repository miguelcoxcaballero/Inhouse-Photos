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
    static readonly Brush page=new SolidColorBrush(Color.FromRgb(246,243,238));
    static readonly Brush ink=new SolidColorBrush(Color.FromRgb(32,28,24));
    static readonly Brush muted=new SolidColorBrush(Color.FromRgb(104,95,85));
    static readonly Brush line=new SolidColorBrush(Color.FromRgb(220,213,203));
    static readonly Brush accent=new SolidColorBrush(Color.FromRgb(169,71,18));
    readonly StackPanel rows=new StackPanel();readonly TextBlock status=new TextBlock();readonly ComboBox mode=new ComboBox();readonly ComboBox pool=new ComboBox();readonly TextBox confirmation=new TextBox();
    readonly Dictionary<CheckBox,StorageDisk> selection=new Dictionary<CheckBox,StorageDisk>();bool busy;
    public StorageWindow() {
      Title="Inhouse Photos · Discos protegidos";Width=760;Height=760;MinWidth=640;MinHeight=600;WindowStartupLocation=WindowStartupLocation.CenterScreen;
      Background=page;Foreground=ink;FontFamily=new FontFamily("Segoe UI");FontSize=15;
      var panel=new StackPanel{Margin=new Thickness(32,28,32,32)};
      Content=new ScrollViewer{Content=panel,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};
      var title=Text("Discos y redundancia",30,ink,new Thickness(0,0,0,5));title.FontWeight=FontWeights.SemiBold;panel.Children.Add(title);
      panel.Children.Add(Text("Opciones avanzadas de almacenamiento para este PC.",15,muted,new Thickness(0,0,0,18)));
      var warning=new Border{Background=new SolidColorBrush(Color.FromRgb(246,231,216)),BorderBrush=accent,BorderThickness=new Thickness(3,0,0,0),Padding=new Thickness(15,12,15,12),Margin=new Thickness(0,0,0,22)};
      warning.Child=Text("Solo puedes seleccionar discos vacíos sin particiones. La biblioteca actual y el disco de Windows están protegidos. RAID no sustituye una copia de seguridad.",14,ink,new Thickness(0));panel.Children.Add(warning);

      var choose=Step(panel,"1","Selecciona discos vacíos","Los discos con datos o que Windows no puede identificar aparecen desactivados.");
      choose.Children.Add(rows);
      Divider(panel);

      var protect=Step(panel,"2","Elige la protección","El espejo requiere al menos 2 discos; la paridad, al menos 3.");
      mode.Items.Add("Espejo · mínimo 2 discos");mode.Items.Add("Paridad · mínimo 3 discos");mode.Items.Add("Añadir discos a un grupo existente");mode.SelectedIndex=0;
      StyleChoice(mode);mode.Margin=new Thickness(0,2,0,8);protect.Children.Add(mode);
      var poolTitle=Text("Grupo de destino",14,muted,new Thickness(0,0,0,6));poolTitle.Visibility=Visibility.Collapsed;protect.Children.Add(poolTitle);
      StyleChoice(pool);pool.Visibility=Visibility.Collapsed;protect.Children.Add(pool);
      mode.SelectionChanged+=(s,e)=>{var adding=mode.SelectedIndex==2;poolTitle.Visibility=adding?Visibility.Visible:Visibility.Collapsed;pool.Visibility=adding?Visibility.Visible:Visibility.Collapsed;};
      Divider(panel);

      var confirm=Step(panel,"3","Confirma antes de aplicar","Revisarás una última vez los discos elegidos antes de cambiar su organización.");
      confirm.Children.Add(Text("Para confirmar el uso de los discos seleccionados, escribe CREAR.",14,ink,new Thickness(0,0,0,7)));
      confirmation.Padding=new Thickness(10);confirmation.MinHeight=42;confirmation.MaxLength=5;confirmation.Background=Brushes.White;confirmation.Foreground=ink;confirmation.BorderBrush=line;confirmation.BorderThickness=new Thickness(1);confirmation.Margin=new Thickness(0,0,0,12);confirm.Children.Add(confirmation);
      var button=new Button{Content="Revisar y aplicar",Padding=new Thickness(18,12,18,12),MinHeight=44,HorizontalAlignment=HorizontalAlignment.Left,Background=accent,BorderBrush=accent,Foreground=Brushes.White,FontWeight=FontWeights.SemiBold};confirm.Children.Add(button);
      status.TextWrapping=TextWrapping.Wrap;status.Foreground=muted;status.Margin=new Thickness(0,16,0,0);confirm.Children.Add(status);
      button.Click+=async(s,e)=>{
        if(busy)return;
        try {
          var selected=selection.Where(x=>x.Key.IsChecked==true).Select(x=>x.Value).ToList();var add=mode.SelectedIndex==2;var resiliency=mode.SelectedIndex==1?"Parity":"Mirror";
          StorageBackend.ValidateSelection(selected,resiliency,add);
          if(confirmation.Text!="CREAR")throw new InvalidOperationException("Escribe CREAR para confirmar.");
          var destination=pool.SelectedItem as StoragePoolInfo;if(add&&destination==null)throw new InvalidOperationException("Selecciona el grupo de destino.");
          var summary=String.Join("\n",selected.Select(d=>d.Model+" · "+d.Serial+" · "+Backend.Size(d.Size)));
          var target=add?"Añadir al grupo "+destination.Name:resiliency=="Mirror"?"Crear un espejo":"Crear un grupo de paridad";
          if(MessageBox.Show(this,target+" con estos discos vacíos:\n\n"+summary+"\n\nLa operación cambia su organización de almacenamiento. ¿Continuar?","Confirmar discos",MessageBoxButton.OKCancel,MessageBoxImage.Warning)!=MessageBoxResult.OK)return;
          busy=true;button.IsEnabled=false;status.Text="Configurando almacenamiento. No desconectes los discos…";
          var result=Backend.Json.Deserialize<Dictionary<string,object>>(await StorageBackend.Execute(add?"Add":"Create",new{Disks=selected,Mode=resiliency,PoolId=destination==null?null:destination.Id,Confirmation=confirmation.Text},900));
          status.Text=Convert.ToString(result["Message"]);status.Foreground=muted;confirmation.Clear();await LoadDisks();
        }catch(Exception ex){status.Foreground=accent;status.Text=ex.Message+" Si se creó un grupo parcialmente, se conserva; no se deshacen operaciones borrando discos.";}
        finally{busy=false;button.IsEnabled=true;}
      };
      Loaded+=async(s,e)=>{status.Text="Comprobando los discos disponibles…";try{await LoadDisks();if(status.Text=="Comprobando los discos disponibles…")status.Text="";}catch(Exception ex){status.Foreground=accent;status.Text=ex.Message;}};
      Closing+=(s,e)=>{if(busy){e.Cancel=true;status.Text="Espera a que Windows confirme el resultado antes de cerrar.";}};
    }
    static TextBlock Text(string value,double size,Brush color,Thickness margin){return new TextBlock{Text=value,FontSize=size,Foreground=color,TextWrapping=TextWrapping.Wrap,Margin=margin};}
    static StackPanel Step(StackPanel panel,string number,string title,string detail) {
      var section=new StackPanel{Margin=new Thickness(0,0,0,18)};
      var heading=Text(number+"  "+title,20,ink,new Thickness(0,0,0,5));heading.FontWeight=FontWeights.SemiBold;section.Children.Add(heading);
      section.Children.Add(Text(detail,14,muted,new Thickness(0,0,0,13)));
      panel.Children.Add(section);return section;
    }
    static void Divider(StackPanel panel){panel.Children.Add(new Border{Height=1,Background=line,Margin=new Thickness(0,0,0,22)});}
    static void StyleChoice(ComboBox choice){choice.MinHeight=42;choice.Padding=new Thickness(9);choice.Background=Brushes.White;choice.Foreground=ink;choice.BorderBrush=line;choice.BorderThickness=new Thickness(1);}
    async Task LoadDisks() {
      var inventory=Backend.Json.Deserialize<StorageInventory>(await StorageBackend.Execute("Inspect",null));rows.Children.Clear();selection.Clear();pool.Items.Clear();
      foreach(var disk in inventory.Disks){
        var label=new StackPanel();
        var diskName=Text(disk.Model+" · "+Backend.Size(disk.Size),15,ink,new Thickness(0,0,0,3));diskName.FontWeight=FontWeights.SemiBold;label.Children.Add(diskName);
        label.Children.Add(Text(disk.Serial+" · "+disk.Reason,13,muted,new Thickness(0)));
        var box=new CheckBox{Content=label,IsEnabled=disk.Eligible,Foreground=ink,VerticalContentAlignment=VerticalAlignment.Center};
        rows.Children.Add(new Border{Child=box,BorderBrush=line,BorderThickness=new Thickness(0,0,0,1),Padding=new Thickness(2,10,0,10)});selection.Add(box,disk);
      }
      foreach(var item in inventory.Pools)pool.Items.Add(item);
      if(!inventory.Disks.Any(d=>d.Eligible)){status.Foreground=accent;status.Text="No hay discos vacíos disponibles. Conecta discos nuevos; los que contienen datos no se pueden seleccionar.";}
    }
  }
}
