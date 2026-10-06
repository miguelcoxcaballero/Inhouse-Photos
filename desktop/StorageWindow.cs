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
    static readonly Brush ink=Ui.Ink;
    static readonly Brush muted=Ui.Ink2;
    static readonly Brush accent=Ui.Accent;
    readonly StackPanel rows=new StackPanel();readonly TextBlock status=new TextBlock();readonly ComboBox mode=new ComboBox();readonly ComboBox pool=new ComboBox();readonly TextBox confirmation=new TextBox();
    readonly Dictionary<CheckBox,StorageDisk> selection=new Dictionary<CheckBox,StorageDisk>();bool busy;
    public StorageWindow() {
      Ui.Apply(this);
      Title="Inhouse Photos · Discos protegidos";Width=760;Height=760;MinWidth=640;MinHeight=600;WindowStartupLocation=WindowStartupLocation.CenterScreen;
      using(var brand=typeof(StorageWindow).Assembly.GetManifestResourceStream("InhousePhotos.brand.xaml"))Icon=(ImageSource)System.Windows.Markup.XamlReader.Load(brand);
      var panel=new StackPanel{Margin=new Thickness(40,32,40,40)};
      Content=new ScrollViewer{Content=panel,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled,Background=Ui.Paper,Focusable=false};
      var title=Ui.Display("Discos y redundancia");title.Margin=new Thickness(0,0,0,6);panel.Children.Add(title);
      var subtitle=Ui.Secondary("Opciones avanzadas de almacenamiento para este PC.");subtitle.Margin=new Thickness(0,0,0,24);panel.Children.Add(subtitle);
      // Safety-critical: stated once, with an icon, before any choice.
      var warning=new Grid{Margin=new Thickness(0,0,0,32)};
      warning.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(30)});warning.ColumnDefinitions.Add(new ColumnDefinition());
      var alert=Ui.Icon("alert",18,accent);alert.VerticalAlignment=VerticalAlignment.Top;alert.HorizontalAlignment=HorizontalAlignment.Left;alert.Margin=new Thickness(0,1,0,0);warning.Children.Add(alert);
      var warningText=Ui.Body("Solo puedes seleccionar discos vacíos sin particiones. La biblioteca actual y el disco de Windows están protegidos. RAID no sustituye una copia de seguridad.");
      Grid.SetColumn(warningText,1);warning.Children.Add(warningText);panel.Children.Add(warning);

      var choose=Step(panel,"1","Selecciona discos vacíos","Los discos con datos o que Windows no puede identificar aparecen desactivados.");
      rows.Margin=new Thickness(0,4,0,0);choose.Children.Add(rows);

      var protect=Step(panel,"2","Elige la protección","El espejo requiere al menos 2 discos; la paridad, al menos 3.");
      mode.Items.Add("Espejo · mínimo 2 discos");mode.Items.Add("Paridad · mínimo 3 discos");mode.Items.Add("Añadir discos a un grupo existente");mode.SelectedIndex=0;
      StyleChoice(mode);mode.Margin=new Thickness(0,4,0,12);System.Windows.Automation.AutomationProperties.SetName(mode,"Tipo de protección");protect.Children.Add(Ui.Constrain(mode,420));
      var poolTitle=Ui.Body("Grupo de destino");poolTitle.Margin=new Thickness(0,0,0,6);poolTitle.Visibility=Visibility.Collapsed;protect.Children.Add(poolTitle);
      StyleChoice(pool);pool.Visibility=Visibility.Collapsed;System.Windows.Automation.AutomationProperties.SetName(pool,"Grupo de destino");protect.Children.Add(Ui.Constrain(pool,420));
      mode.SelectionChanged+=(s,e)=>{var adding=mode.SelectedIndex==2;poolTitle.Visibility=adding?Visibility.Visible:Visibility.Collapsed;pool.Visibility=adding?Visibility.Visible:Visibility.Collapsed;};

      var confirm=Step(panel,"3","Confirma antes de aplicar","Revisarás una última vez los discos elegidos antes de cambiar su organización.");
      var typeHint=Ui.Body("Para confirmar el uso de los discos seleccionados, escribe CREAR.");typeHint.Margin=new Thickness(0,4,0,8);confirm.Children.Add(typeHint);
      confirmation.MaxLength=5;confirmation.Width=200;confirmation.HorizontalAlignment=HorizontalAlignment.Left;confirmation.Margin=new Thickness(0,0,0,16);
      System.Windows.Automation.AutomationProperties.SetName(confirmation,"Escribe CREAR para confirmar");confirm.Children.Add(confirmation);
      var button=Ui.Button("Revisar y aplicar","Primary");button.Margin=new Thickness(0);confirm.Children.Add(button);
      status.TextWrapping=TextWrapping.Wrap;status.Foreground=muted;status.Margin=new Thickness(0,16,0,0);
      System.Windows.Automation.AutomationProperties.SetLiveSetting(status,System.Windows.Automation.AutomationLiveSetting.Polite);confirm.Children.Add(status);
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
    // Numbered step: a marker, a title and one line, separated by hairlines.
    static StackPanel Step(StackPanel panel,string number,string title,string detail) {
      if(number!="1")panel.Children.Add(Ui.Divider(new Thickness(0,8,0,24)));
      var header=new Grid();header.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(36)});header.ColumnDefinitions.Add(new ColumnDefinition());
      var marker=new Ui.StepMarker(int.Parse(number));marker.VerticalAlignment=VerticalAlignment.Top;marker.HorizontalAlignment=HorizontalAlignment.Left;marker.Margin=new Thickness(0,1,0,0);header.Children.Add(marker);
      var words=new StackPanel();Grid.SetColumn(words,1);header.Children.Add(words);
      words.Children.Add(Ui.Subtitle(title));
      var line=Ui.Secondary(detail);line.Margin=new Thickness(0,2,0,0);words.Children.Add(line);
      panel.Children.Add(header);
      var section=new StackPanel{Margin=new Thickness(36,12,0,16)};
      panel.Children.Add(section);return section;
    }
    static void StyleChoice(ComboBox choice){choice.HorizontalAlignment=HorizontalAlignment.Stretch;}
    async Task LoadDisks() {
      Fill(Backend.Json.Deserialize<StorageInventory>(await StorageBackend.Execute("Inspect",null)));
    }
    // Preview only: sample rows so the layout can be reviewed without touching disks.
    internal void PreviewInventory() {
      Fill(new StorageInventory{Pools=new List<StoragePoolInfo>(),Disks=new List<StorageDisk>{
        new StorageDisk{Model="Samsung SSD 870 EVO",Serial="S6PNNX0T000001",Size=1000204886016,Eligible=true,Reason="Vacío y sin particiones"},
        new StorageDisk{Model="WDC WD40EFRX",Serial="WD-WCC7K0000002",Size=4000787030016,Eligible=true,Reason="Vacío y sin particiones"},
        new StorageDisk{Model="Samsung SSD 980",Serial="S64ANS0T000003",Size=500107862016,Eligible=false,Reason="Contiene la biblioteca actual"}}});
    }
    void Fill(StorageInventory inventory) {
      rows.Children.Clear();selection.Clear();pool.Items.Clear();
      rows.Children.Add(Ui.Divider(new Thickness(0)));
      foreach(var disk in inventory.Disks){
        var label=new StackPanel();
        var diskName=Ui.Text(disk.Model+" · "+Backend.Size(disk.Size),Ui.BodySize,ink,true);label.Children.Add(diskName);
        var detail=Ui.Caption(disk.Serial+" · "+disk.Reason);detail.Margin=new Thickness(0,2,0,0);label.Children.Add(detail);
        var box=new CheckBox{Content=label,IsEnabled=disk.Eligible,VerticalContentAlignment=VerticalAlignment.Center};
        System.Windows.Automation.AutomationProperties.SetName(box,disk.Model+" "+Backend.Size(disk.Size)+", "+disk.Reason);
        rows.Children.Add(new Border{Child=box,BorderBrush=Ui.Hairline,BorderThickness=new Thickness(0,0,0,1),Padding=new Thickness(0,12,0,12)});selection.Add(box,disk);
      }
      foreach(var item in inventory.Pools)pool.Items.Add(item);
      if(!inventory.Disks.Any(d=>d.Eligible)){status.Foreground=accent;status.Text="No hay discos vacíos disponibles. Conecta discos nuevos; los que contienen datos no se pueden seleccionar.";}
    }
  }
}
