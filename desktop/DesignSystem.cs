using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Data;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace InhousePhotos {
  public enum Tone { Neutral, Good, Attention, Critical, Busy }

  // One design system for every window: the manager, the setup wizard, the
  // storage tool and the installer. Colours, type and control templates live
  // here so individual pages only describe structure, never styling.
  public static class Ui {
    // Warm neutrals with a single, restrained accent. "Accent" is the
    // text-safe brand orange (5.3:1 on paper); "Brand" is the logo orange and
    // is used only for non-text graphics such as the backup ring.
    static readonly Dictionary<string,string> Tokens=new Dictionary<string,string> {
      {"paper","F6F3EE"},{"surface","FFFCF8"},{"sidebar","EFEAE3"},
      {"ink","201C18"},{"ink2","5F574E"},{"ink3","6E655B"},
      {"hairline","E4DCD1"},{"stroke","D6CDC0"},{"strokeStrong","8F7F6E"},
      {"accent","A94712"},{"accentHover","963F10"},{"accentPressed","82370E"},
      {"brand","D97736"},{"accentTint","F5E6D9"},
      {"good","2C724D"},{"goodTint","E2EEE5"},{"critical","B13E2D"},{"criticalTint","F7E2DD"},
      {"controlHover","F9F5EF"},{"controlPressed","F1EBE3"},
      {"hover","0C201C18"},{"pressed","16201C18"},{"selected","12201C18"},{"neutralTint","ECE6DD"}
    };
    static SolidColorBrush Token(string key) {
      var brush=new SolidColorBrush((Color)ColorConverter.ConvertFromString("#"+Tokens[key]));brush.Freeze();return brush;
    }
    public static readonly SolidColorBrush Paper=Token("paper"),Surface=Token("surface"),Sidebar=Token("sidebar"),
      Ink=Token("ink"),Ink2=Token("ink2"),Ink3=Token("ink3"),Hairline=Token("hairline"),Stroke=Token("stroke"),
      StrokeStrong=Token("strokeStrong"),Accent=Token("accent"),Brand=Token("brand"),AccentTint=Token("accentTint"),
      Good=Token("good"),GoodTint=Token("goodTint"),Critical=Token("critical"),CriticalTint=Token("criticalTint"),
      NeutralTint=Token("neutralTint"),Selected=Token("selected");

    // WPF cannot drive the weight axis of Segoe UI Variable (semibold would be
    // synthesised), so the static Segoe UI family is used deliberately.
    public static readonly FontFamily Font=new FontFamily("Segoe UI");
    public const double DisplaySize=28,TitleSize=20,SubtitleSize=16,BodySize=14,CaptionSize=12;

    // Previews and reduced-motion settings both disable decorative motion.
    public static bool ReduceMotion {get;set;}
    public static bool MotionAllowed {get{return !ReduceMotion&&SystemParameters.ClientAreaAnimation;}}

    static ResourceDictionary shared;
    public static ResourceDictionary Resources {
      get {
        if(shared==null) {
          var xaml=Xaml;
          foreach(var token in Tokens)xaml=xaml.Replace("$"+token.Key+"'","#"+token.Value+"'");
          shared=(ResourceDictionary)XamlReader.Parse(xaml);
        }
        return shared;
      }
    }
    public static Style StyleOf(string key){return (Style)Resources[key];}

    public static void Apply(Window window) {
      window.Resources.MergedDictionaries.Add(Resources);
      window.FontFamily=Font;window.FontSize=BodySize;window.Foreground=Ink;window.Background=Paper;
      window.UseLayoutRounding=true;window.SnapsToDevicePixels=true;
      TextOptions.SetTextFormattingMode(window,TextFormattingMode.Display);
      window.SourceInitialized+=(s,e)=>Chrome(window);
    }

    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd,int attribute,ref int value,int size);
    // Windows 11 lets the native title bar take the page colour, so the frame
    // reads as one surface. Older Windows versions ignore the request.
    static void Chrome(Window window) {
      try {
        var handle=new WindowInteropHelper(window).Handle;
        int caption=Colorref(Tokens["paper"]),text=Colorref(Tokens["ink"]),border=Colorref(Tokens["stroke"]);
        DwmSetWindowAttribute(handle,35,ref caption,4);
        DwmSetWindowAttribute(handle,36,ref text,4);
        DwmSetWindowAttribute(handle,34,ref border,4);
      } catch {}
    }
    static int Colorref(string hex){var c=(Color)ColorConverter.ConvertFromString("#"+hex);return c.R|(c.G<<8)|(c.B<<16);}

    // Type: one scale, one line-height rhythm, tabular numerals everywhere so
    // sizes, dates and counts align and do not jitter when they update.
    public static TextBlock Text(string text,double size=BodySize,Brush color=null,bool strong=false) {
      var block=new TextBlock{Text=text??"",FontSize=size,Foreground=color??Ink,TextWrapping=TextWrapping.Wrap,
        FontWeight=strong?FontWeights.SemiBold:FontWeights.Normal,
        LineStackingStrategy=LineStackingStrategy.BlockLineHeight,LineHeight=Math.Round(size*1.43)};
      Typography.SetNumeralAlignment(block,FontNumeralAlignment.Tabular);
      if(size>=TitleSize)TextOptions.SetTextFormattingMode(block,TextFormattingMode.Ideal);
      return block;
    }
    public static TextBlock Display(string text){var t=Text(text,DisplaySize,null,true);return t;}
    public static TextBlock Title(string text){return Text(text,TitleSize,null,true);}
    public static TextBlock Subtitle(string text){return Text(text,SubtitleSize,null,true);}
    public static TextBlock Body(string text,Brush color=null){return Text(text,BodySize,color);}
    public static TextBlock Secondary(string text){return Text(text,BodySize,Ink2);}
    public static TextBlock Caption(string text,Brush color=null){return Text(text,CaptionSize,color??Ink3);}

    public static Border Divider(Thickness margin) {
      return new Border{Height=1,Background=Ui.Hairline,Margin=margin,SnapsToDevicePixels=true};
    }

    // Simple 24-unit outline icons drawn as geometry. No glyph fonts or emoji.
    static readonly Dictionary<string,string> IconData=new Dictionary<string,string> {
      {"home","M4,10.6 L12,4.2 L20,10.6 M6.2,9 V19.6 H17.8 V9 M10.2,19.6 V14.2 H13.8 V19.6"},
      {"phone","M8.2,3 H15.8 A1.7,1.7 0 0 1 17.5,4.7 V19.3 A1.7,1.7 0 0 1 15.8,21 H8.2 A1.7,1.7 0 0 1 6.5,19.3 V4.7 A1.7,1.7 0 0 1 8.2,3 Z M10.8,18 H13.2"},
      {"shield","M12,3.2 L19,6 V11.6 C19,15.9 16.1,19.2 12,20.8 C7.9,19.2 5,15.9 5,11.6 V6 Z M9.2,12 L11.2,14 L14.9,10.2"},
      {"drive","M4,13.2 H20 V17.8 A1.6,1.6 0 0 1 18.4,19.4 H5.6 A1.6,1.6 0 0 1 4,17.8 Z M4,13.2 L6.3,5.9 A1.6,1.6 0 0 1 7.8,4.8 H16.2 A1.6,1.6 0 0 1 17.7,5.9 L20,13.2 M16.6,16.3 L16.7,16.3"},
      {"sliders","M4,7.5 H13.5 M18.5,7.5 H20 M4,16.5 H5.5 M10.5,16.5 H20 M16,5.2 A2.3,2.3 0 1 1 16,9.8 A2.3,2.3 0 1 1 16,5.2 Z M8,14.2 A2.3,2.3 0 1 1 8,18.8 A2.3,2.3 0 1 1 8,14.2 Z"},
      {"external","M13.5,4.5 H19.5 V10.5 M19.5,4.5 L11,13 M17.5,14 V18 A1.5,1.5 0 0 1 16,19.5 H6 A1.5,1.5 0 0 1 4.5,18 V8 A1.5,1.5 0 0 1 6,6.5 H10"},
      {"chevron","M9.5,6 L15.5,12 L9.5,18"},
      {"arrow","M5,12 H18.5 M13,6.5 L18.5,12 L13,17.5"},
      {"check","M5.5,12.5 L10,17 L18.5,7.5"},
      {"alert","M12,4.2 L20.6,19.2 H3.4 Z M12,10 V13.8 M12,16.6 L12,16.7"},
      {"info","M12,3.8 A8.2,8.2 0 1 1 12,20.2 A8.2,8.2 0 1 1 12,3.8 Z M12,11 V16.2 M12,7.9 L12,8"},
      {"usb","M12,3.5 V16.5 M9.6,6 L12,3.5 L14.4,6 M12,12.6 L8,10.2 V8.6 M12,14.6 L16,12.2 V10.6 M12,16.5 A1.9,1.9 0 1 1 12,20.3 A1.9,1.9 0 1 1 12,16.5 Z M8,6.4 A1.1,1.1 0 1 1 8,8.6 A1.1,1.1 0 1 1 8,6.4 Z M15,8.6 H17 V10.6 H15 Z"},
      {"folder","M3.5,7.2 A1.7,1.7 0 0 1 5.2,5.5 H9.4 L11.4,7.5 H18.8 A1.7,1.7 0 0 1 20.5,9.2 V17.3 A1.7,1.7 0 0 1 18.8,19 H5.2 A1.7,1.7 0 0 1 3.5,17.3 Z"},
      {"globe","M12,3.8 A8.2,8.2 0 1 1 12,20.2 A8.2,8.2 0 1 1 12,3.8 Z M3.8,12 H20.2 M12,3.8 C9.4,6.4 9.4,17.6 12,20.2 C14.6,17.6 14.6,6.4 12,3.8 Z"},
      {"power","M12,3.8 V11 M7.6,6.6 A7,7 0 1 0 16.4,6.6"},
      {"refresh","M19,12 A7,7 0 1 1 16.4,6.6 M17.2,3.6 L17,7.2 L13.4,7"},
      {"calendar","M5.5,6 H18.5 A1.5,1.5 0 0 1 20,7.5 V18.5 A1.5,1.5 0 0 1 18.5,20 H5.5 A1.5,1.5 0 0 1 4,18.5 V7.5 A1.5,1.5 0 0 1 5.5,6 Z M4,10.5 H20 M8.5,4 V7.5 M15.5,4 V7.5"},
      {"photo","M5.5,4.5 H18.5 A1.5,1.5 0 0 1 20,6 V18 A1.5,1.5 0 0 1 18.5,19.5 H5.5 A1.5,1.5 0 0 1 4,18 V6 A1.5,1.5 0 0 1 5.5,4.5 Z M4.5,17 L10,11.5 L15,16.5 M13.5,15 L16,12.5 L19.5,16 M14.6,7.5 A1.4,1.4 0 1 1 14.6,10.3 A1.4,1.4 0 1 1 14.6,7.5 Z"},
      {"lock","M7,10.8 H17 A1.5,1.5 0 0 1 18.5,12.3 V18.5 A1.5,1.5 0 0 1 17,20 H7 A1.5,1.5 0 0 1 5.5,18.5 V12.3 A1.5,1.5 0 0 1 7,10.8 Z M8.5,10.8 V8 A3.5,3.5 0 0 1 15.5,8 V10.8"},
      {"cloud","M7.4,18.4 A4.1,4.1 0 0 1 6.9,10.24 A5.5,5.5 0 0 1 17.3,9.5 A4.45,4.45 0 0 1 17,18.4 Z"},
      {"cloudUp","M7.4,18.4 A4.1,4.1 0 0 1 6.9,10.24 A5.5,5.5 0 0 1 17.3,9.5 A4.45,4.45 0 0 1 17,18.4 Z M12,16 V11.4 M10,13.3 L12,11.3 L14,13.3"},
      {"cloudDone","M7.4,18.4 A4.1,4.1 0 0 1 6.9,10.24 A5.5,5.5 0 0 1 17.3,9.5 A4.45,4.45 0 0 1 17,18.4 Z M9.6,13.9 L11.3,15.6 L14.6,12.2"},
      {"cloudOff","M7.4,18.4 A4.1,4.1 0 0 1 6.9,10.24 A5.5,5.5 0 0 1 17.3,9.5 A4.45,4.45 0 0 1 17,18.4 Z M4,4.5 L20,20.5"},
      {"cloudAlert","M7.4,18.4 A4.1,4.1 0 0 1 6.9,10.24 A5.5,5.5 0 0 1 17.3,9.5 A4.45,4.45 0 0 1 17,18.4 Z M12,11.6 V14.4 M12,16.3 L12,16.4"},
      {"wrench","M14.8,4.4 A4.6,4.6 0 0 0 9.9,10.6 L4.4,16.1 A2.1,2.1 0 0 0 7.4,19.1 L12.9,13.6 A4.6,4.6 0 0 0 19.1,8.7 L16.4,11.4 L13.5,10.5 L12.6,7.6 Z"},
      {"dash","M7,12 H17"}
    };
    static readonly Dictionary<string,Geometry> IconCache=new Dictionary<string,Geometry>();
    public static Geometry IconGeometry(string name) {
      Geometry geometry;
      if(!IconCache.TryGetValue(name,out geometry)){geometry=Geometry.Parse(IconData[name]);geometry.Freeze();IconCache[name]=geometry;}
      return geometry;
    }
    public static Viewbox Icon(string name,double size=16,Brush color=null,double weight=1.6) {
      var path=new Path{Data=IconGeometry(name),Stroke=color??Ink2,StrokeThickness=weight,Width=24,Height=24,
        StrokeStartLineCap=PenLineCap.Round,StrokeEndLineCap=PenLineCap.Round,StrokeLineJoin=PenLineJoin.Round};
      return new Viewbox{Width=size,Height=size,Child=path,Stretch=Stretch.Uniform,SnapsToDevicePixels=true,Focusable=false};
    }
    public static Path IconPath(Viewbox icon){return (Path)icon.Child;}

    // Buttons. "Primary" is the single main action of a view, "Secondary" is
    // the default, "Link" is a quiet inline action and "Row" makes a whole
    // list row a keyboard-reachable navigation target.
    public static Button Button(string text,string style="Secondary",string icon=null) {
      var button=new Button{Style=StyleOf(style)};SetCaption(button,text,icon);return button;
    }
    public static void SetCaption(Button button,string text,string icon=null) {
      AutomationProperties.SetName(button,text);
      if(icon==null){button.Content=text;return;}
      var row=new StackPanel{Orientation=Orientation.Horizontal};
      row.Children.Add(new TextBlock{Text=text,VerticalAlignment=VerticalAlignment.Center});
      var glyph=Icon(icon,14,null,1.8);glyph.Margin=new Thickness(8,1,0,0);glyph.VerticalAlignment=VerticalAlignment.Center;
      IconPath(glyph).SetBinding(Shape.StrokeProperty,new Binding("Foreground"){Source=button});
      row.Children.Add(glyph);button.Content=row;
    }
    public static void SetStyle(Button button,string style){button.Style=StyleOf(style);}

    // A list row: leading icon, title and detail, optional trailing content.
    public sealed class Row {
      public Grid Root;public Viewbox Icon;public TextBlock Heading;public TextBlock Detail;public StackPanel Body;public StackPanel Trailing;
    }
    public static Row ListRow(string icon,string title,string detail) {
      var row=new Row{Root=new Grid{Margin=new Thickness(0,14,0,14)}};
      row.Root.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(40)});
      row.Root.ColumnDefinitions.Add(new ColumnDefinition());
      row.Root.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
      if(icon!=null){row.Icon=Icon(icon,20,Ink2);row.Icon.VerticalAlignment=VerticalAlignment.Top;row.Icon.HorizontalAlignment=HorizontalAlignment.Left;row.Icon.Margin=new Thickness(0,1,0,0);row.Root.Children.Add(row.Icon);}
      row.Body=new StackPanel{VerticalAlignment=VerticalAlignment.Center};Grid.SetColumn(row.Body,1);row.Root.Children.Add(row.Body);
      row.Heading=Text(title,BodySize,Ink,true);row.Body.Children.Add(row.Heading);
      row.Detail=Text(detail,BodySize,Ink2);row.Detail.Margin=new Thickness(0,2,0,0);
      if(String.IsNullOrEmpty(detail))row.Detail.Visibility=Visibility.Collapsed;
      row.Body.Children.Add(row.Detail);
      row.Trailing=new StackPanel{Orientation=Orientation.Horizontal,VerticalAlignment=VerticalAlignment.Center,Margin=new Thickness(16,0,0,0)};
      Grid.SetColumn(row.Trailing,2);row.Root.Children.Add(row.Trailing);
      return row;
    }

    // Left-aligned element that fills the available width up to a maximum.
    // (A stretched element with MaxWidth would otherwise be centred.)
    public static Grid Constrain(FrameworkElement child,double maxWidth) {
      var grid=new Grid();
      grid.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(1,GridUnitType.Star),MaxWidth=maxWidth});
      grid.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
      grid.Children.Add(child);return grid;
    }

    // Two columns that stack when the window is narrow.
    public static Grid Columns(FrameworkElement left,FrameworkElement right,double leftWidth,double gap,double stackBelow) {
      var grid=new Grid();
      grid.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(leftWidth)});
      grid.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(gap)});
      grid.ColumnDefinitions.Add(new ColumnDefinition());
      grid.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});
      grid.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});
      grid.Children.Add(left);grid.Children.Add(right);
      Action<double> layout=width=>{
        var stacked=width>0&&width<stackBelow;
        grid.ColumnDefinitions[0].Width=stacked?new GridLength(1,GridUnitType.Star):new GridLength(leftWidth);
        grid.ColumnDefinitions[1].Width=stacked?new GridLength(0):new GridLength(gap);
        grid.ColumnDefinitions[2].Width=stacked?new GridLength(0):new GridLength(1,GridUnitType.Star);
        Grid.SetRow(right,stacked?1:0);Grid.SetColumn(right,stacked?0:2);
        right.Margin=stacked?new Thickness(0,24,0,0):new Thickness(0);
      };
      layout(0);grid.SizeChanged+=(s,e)=>{if(e.WidthChanged)layout(e.NewSize.Width);};
      return grid;
    }

    // A calm activity ring: a hairline track with a short brand arc that
    // rotates only when Windows animations are on.
    public sealed class Spinner:Grid {
      readonly RotateTransform rotation=new RotateTransform();
      public Spinner(double size,double thickness,Brush track=null,Brush arc=null) {
        Width=size;Height=size;IsHitTestVisible=false;
        if(track!=null)Children.Add(new Ellipse{Stroke=track,StrokeThickness=thickness,Width=size,Height=size});
        var radius=(size-thickness)/2;var centre=size/2;var sweep=Math.PI*0.62;
        var figure=new PathFigure{StartPoint=new Point(centre,centre-radius),IsClosed=false,IsFilled=false};
        figure.Segments.Add(new ArcSegment(new Point(centre+radius*Math.Sin(sweep),centre-radius*Math.Cos(sweep)),new Size(radius,radius),0,false,SweepDirection.Clockwise,true));
        var geometry=new PathGeometry(new[]{figure});geometry.Freeze();
        Children.Add(new Path{Data=geometry,Stroke=arc??Brand,StrokeThickness=thickness,Width=size,Height=size,
          StrokeStartLineCap=PenLineCap.Round,StrokeEndLineCap=PenLineCap.Round,RenderTransform=rotation,RenderTransformOrigin=new Point(0.5,0.5)});
        rotation.Angle=-30;
        IsVisibleChanged+=(s,e)=>Sync();Loaded+=(s,e)=>Sync();Unloaded+=(s,e)=>rotation.BeginAnimation(RotateTransform.AngleProperty,null);
      }
      void Sync() {
        if(IsVisible&&IsLoaded&&MotionAllowed)
          rotation.BeginAnimation(RotateTransform.AngleProperty,new DoubleAnimation(0,360,new Duration(TimeSpan.FromSeconds(1.4))){RepeatBehavior=RepeatBehavior.Forever});
        else rotation.BeginAnimation(RotateTransform.AngleProperty,null);
      }
    }

    // Round status mark: tinted disc with an outline icon, or a ring while busy.
    public sealed class StatusMark:Grid {
      readonly Ellipse disc=new Ellipse();readonly Viewbox glyph;readonly Spinner ring;
      public StatusMark(double size) {
        Width=size;Height=size;IsHitTestVisible=false;
        Children.Add(disc);
        glyph=Icon("check",size*0.5,Good,1.9);glyph.HorizontalAlignment=HorizontalAlignment.Center;glyph.VerticalAlignment=VerticalAlignment.Center;Children.Add(glyph);
        ring=new Spinner(size,2.2,Hairline,Brand);Children.Add(ring);
        Set(Tone.Busy);
      }
      public void Set(Tone tone) {
        ring.Visibility=tone==Tone.Busy?Visibility.Visible:Visibility.Collapsed;
        glyph.Visibility=tone==Tone.Busy?Visibility.Collapsed:Visibility.Visible;
        disc.Fill=tone==Tone.Good?GoodTint:tone==Tone.Attention?AccentTint:tone==Tone.Critical?CriticalTint:tone==Tone.Busy?Brushes.Transparent:(Brush)NeutralTint;
        var path=IconPath(glyph);
        path.Data=IconGeometry(tone==Tone.Good?"check":tone==Tone.Neutral?"dash":"alert");
        path.Stroke=tone==Tone.Good?Good:tone==Tone.Attention?Accent:tone==Tone.Critical?Critical:(Brush)Ink2;
      }
    }

    // Step marker for checklists: number, current (accent ring) or done (check).
    public enum StepState {Pending,Current,Done}
    public sealed class StepMarker:Grid {
      readonly Ellipse disc=new Ellipse{StrokeThickness=1.2};readonly TextBlock number;readonly Viewbox mark;
      public StepMarker(int index,double size=22) {
        Width=size;Height=size;IsHitTestVisible=false;Children.Add(disc);
        number=Text(index.ToString(),CaptionSize,Ink3,true);number.HorizontalAlignment=HorizontalAlignment.Center;number.VerticalAlignment=VerticalAlignment.Center;
        number.TextWrapping=TextWrapping.NoWrap;number.LineHeight=Double.NaN;Children.Add(number);
        mark=Icon("check",size*0.62,Brushes.White,2.4);mark.HorizontalAlignment=HorizontalAlignment.Center;mark.VerticalAlignment=VerticalAlignment.Center;Children.Add(mark);
        Set(StepState.Pending);
      }
      public void Set(StepState state) {
        disc.Fill=state==StepState.Done?Accent:state==StepState.Current?AccentTint:(Brush)Brushes.Transparent;
        disc.Stroke=state==StepState.Pending?StrokeStrong:Accent;
        number.Visibility=state==StepState.Done?Visibility.Collapsed:Visibility.Visible;
        number.Foreground=state==StepState.Current?Accent:Ink3;
        mark.Visibility=state==StepState.Done?Visibility.Visible:Visibility.Collapsed;
      }
    }

    // The backup moment, after the mobile app's cloud hero: a cloud in a
    // tinted disc; while copying, a ring turns around it and the cloud floats
    // by a couple of pixels. Everything is static when animations are off.
    public enum CloudState {Off,Idle,Copying,Done,Attention}
    public sealed class BackupCloud:Grid {
      readonly Ellipse disc=new Ellipse{Width=72,Height=72};
      readonly Viewbox glyph=Icon("cloud",36,Accent,1.5);
      readonly Spinner ring=new Spinner(88,2.5,Hairline,Brand);
      readonly TranslateTransform bob=new TranslateTransform();
      CloudState? current;
      public BackupCloud() {
        Width=88;Height=88;IsHitTestVisible=false;Focusable=false;
        Children.Add(ring);Children.Add(disc);
        glyph.HorizontalAlignment=HorizontalAlignment.Center;glyph.VerticalAlignment=VerticalAlignment.Center;glyph.RenderTransform=bob;Children.Add(glyph);
        IsVisibleChanged+=(s,e)=>SyncMotion();Loaded+=(s,e)=>SyncMotion();
        Unloaded+=(s,e)=>bob.BeginAnimation(TranslateTransform.YProperty,null);
        Set(CloudState.Idle);
      }
      public void Set(CloudState state) {
        var changed=current.HasValue&&current.Value!=state;current=state;
        ring.Visibility=state==CloudState.Copying?Visibility.Visible:Visibility.Hidden;
        disc.Fill=state==CloudState.Done?GoodTint:state==CloudState.Off?NeutralTint:(Brush)AccentTint;
        var path=IconPath(glyph);
        path.Data=IconGeometry(state==CloudState.Off?"cloudOff":state==CloudState.Done?"cloudDone":state==CloudState.Attention?"cloudAlert":"cloudUp");
        path.Stroke=state==CloudState.Done?Good:state==CloudState.Off?Ink3:(Brush)Accent;
        if(changed&&MotionAllowed) {
          var duration=new Duration(TimeSpan.FromMilliseconds(280));
          glyph.BeginAnimation(OpacityProperty,new DoubleAnimation(0,1,duration){EasingFunction=new CubicEase{EasingMode=EasingMode.EaseOut},FillBehavior=FillBehavior.Stop});
        }
        SyncMotion();
      }
      void SyncMotion() {
        if(current==CloudState.Copying&&IsVisible&&IsLoaded&&MotionAllowed)
          bob.BeginAnimation(TranslateTransform.YProperty,new DoubleAnimation(0,-2.5,new Duration(TimeSpan.FromSeconds(1.1))){
            AutoReverse=true,RepeatBehavior=RepeatBehavior.Forever,EasingFunction=new SineEase{EasingMode=EasingMode.EaseInOut}});
        else {bob.BeginAnimation(TranslateTransform.YProperty,null);bob.Y=0;}
      }
    }

    // Indeterminate activity bar. A short segment glides across the track;
    // with animations off it rests as a static segment.
    public sealed class ActivityBar:Grid {
      readonly Border segment=new Border{CornerRadius=new CornerRadius(2),HorizontalAlignment=HorizontalAlignment.Left};
      readonly TranslateTransform shift=new TranslateTransform();
      public ActivityBar() {
        Height=4;ClipToBounds=true;IsHitTestVisible=false;
        Children.Add(new Border{Background=Ui.Hairline,CornerRadius=new CornerRadius(2)});
        segment.Background=Accent;segment.RenderTransform=shift;Children.Add(segment);
        AutomationProperties.SetName(this,"En curso");
        SizeChanged+=(s,e)=>Sync();IsVisibleChanged+=(s,e)=>Sync();Loaded+=(s,e)=>Sync();
        Unloaded+=(s,e)=>shift.BeginAnimation(TranslateTransform.XProperty,null);
      }
      void Sync() {
        var width=ActualWidth;var length=Math.Max(48,width*0.28);segment.Width=length;
        if(IsVisible&&IsLoaded&&MotionAllowed&&width>0)
          shift.BeginAnimation(TranslateTransform.XProperty,new DoubleAnimation(-length,width,new Duration(TimeSpan.FromSeconds(1.6))){
            RepeatBehavior=RepeatBehavior.Forever,EasingFunction=new SineEase{EasingMode=EasingMode.EaseInOut}});
        else {shift.BeginAnimation(TranslateTransform.XProperty,null);shift.X=0;}
      }
    }

    // Short, purposeful entrance used when a page or a state changes.
    public static void Enter(UIElement element,double offset=6,int milliseconds=160) {
      if(!MotionAllowed)return;
      var duration=new Duration(TimeSpan.FromMilliseconds(milliseconds));var easing=new CubicEase{EasingMode=EasingMode.EaseOut};
      var move=element.RenderTransform as TranslateTransform;
      if(move==null||move.IsFrozen){move=new TranslateTransform();element.RenderTransform=move;}
      element.BeginAnimation(UIElement.OpacityProperty,new DoubleAnimation(0,1,duration){EasingFunction=easing,FillBehavior=FillBehavior.Stop});
      move.BeginAnimation(TranslateTransform.YProperty,new DoubleAnimation(offset,0,duration){EasingFunction=easing,FillBehavior=FillBehavior.Stop});
    }

    const string Xaml=@"<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <Style x:Key='FocusRing'>
    <Setter Property='Control.Template'><Setter.Value><ControlTemplate>
      <Grid Margin='-3' SnapsToDevicePixels='True'>
        <Rectangle RadiusX='8' RadiusY='8' Stroke='$ink' StrokeThickness='2'/>
        <Rectangle Margin='2' RadiusX='6' RadiusY='6' Stroke='#FFFFFFFF' StrokeThickness='1'/>
      </Grid>
    </ControlTemplate></Setter.Value></Setter>
  </Style>

  <ControlTemplate x:Key='SecondaryTemplate' TargetType='Button'>
    <Border x:Name='bd' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' CornerRadius='6' SnapsToDevicePixels='True'>
      <ContentPresenter x:Name='cp' Margin='{TemplateBinding Padding}' HorizontalAlignment='{TemplateBinding HorizontalContentAlignment}' VerticalAlignment='{TemplateBinding VerticalContentAlignment}' RecognizesAccessKey='False'/>
    </Border>
    <ControlTemplate.Triggers>
      <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='bd' Property='Background' Value='$controlHover'/></Trigger>
      <Trigger Property='IsPressed' Value='True'><Setter TargetName='bd' Property='Background' Value='$controlPressed'/><Setter TargetName='cp' Property='Opacity' Value='0.75'/></Trigger>
      <Trigger Property='IsEnabled' Value='False'><Setter TargetName='bd' Property='Opacity' Value='0.45'/></Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate>
  <Style TargetType='Button'>
    <Setter Property='FocusVisualStyle' Value='{StaticResource FocusRing}'/>
    <Setter Property='Background' Value='$surface'/>
    <Setter Property='Foreground' Value='$ink'/>
    <Setter Property='BorderBrush' Value='$stroke'/>
    <Setter Property='BorderThickness' Value='1'/>
    <Setter Property='Padding' Value='16,0'/>
    <Setter Property='MinHeight' Value='34'/>
    <Setter Property='MinWidth' Value='88'/>
    <Setter Property='Margin' Value='0,0,8,0'/>
    <Setter Property='FontSize' Value='14'/>
    <Setter Property='HorizontalAlignment' Value='Left'/>
    <Setter Property='VerticalAlignment' Value='Center'/>
    <Setter Property='HorizontalContentAlignment' Value='Center'/>
    <Setter Property='VerticalContentAlignment' Value='Center'/>
    <Setter Property='SnapsToDevicePixels' Value='True'/>
    <Setter Property='Template' Value='{StaticResource SecondaryTemplate}'/>
  </Style>
  <Style x:Key='Secondary' TargetType='Button' BasedOn='{StaticResource {x:Type Button}}'/>
  <Style x:Key='Primary' TargetType='Button' BasedOn='{StaticResource {x:Type Button}}'>
    <Setter Property='Background' Value='$accent'/>
    <Setter Property='BorderBrush' Value='$accent'/>
    <Setter Property='Foreground' Value='#FFFFFFFF'/>
    <Setter Property='FontWeight' Value='SemiBold'/>
    <Setter Property='Template'><Setter.Value>
      <ControlTemplate TargetType='Button'>
        <Border x:Name='bd' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' CornerRadius='6' SnapsToDevicePixels='True'>
          <ContentPresenter x:Name='cp' Margin='{TemplateBinding Padding}' HorizontalAlignment='{TemplateBinding HorizontalContentAlignment}' VerticalAlignment='{TemplateBinding VerticalContentAlignment}' RecognizesAccessKey='False'/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='bd' Property='Background' Value='$accentHover'/><Setter TargetName='bd' Property='BorderBrush' Value='$accentHover'/></Trigger>
          <Trigger Property='IsPressed' Value='True'><Setter TargetName='bd' Property='Background' Value='$accentPressed'/><Setter TargetName='bd' Property='BorderBrush' Value='$accentPressed'/><Setter TargetName='cp' Property='Opacity' Value='0.85'/></Trigger>
          <Trigger Property='IsEnabled' Value='False'><Setter TargetName='bd' Property='Opacity' Value='0.45'/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value></Setter>
  </Style>
  <Style x:Key='Link' TargetType='Button'>
    <Setter Property='FocusVisualStyle' Value='{StaticResource FocusRing}'/>
    <Setter Property='Foreground' Value='$accent'/>
    <Setter Property='Background' Value='Transparent'/>
    <Setter Property='Padding' Value='0,3'/>
    <Setter Property='Margin' Value='0'/>
    <Setter Property='FontSize' Value='14'/>
    <Setter Property='Cursor' Value='Hand'/>
    <Setter Property='HorizontalAlignment' Value='Left'/>
    <Setter Property='VerticalAlignment' Value='Center'/>
    <Setter Property='Template'><Setter.Value>
      <ControlTemplate TargetType='Button'>
        <Border x:Name='bd' Background='Transparent' Padding='{TemplateBinding Padding}' CornerRadius='4'>
          <ContentPresenter x:Name='cp' VerticalAlignment='Center' HorizontalAlignment='Left' RecognizesAccessKey='False'/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property='IsMouseOver' Value='True'><Setter Property='Foreground' Value='$accentPressed'/></Trigger>
          <Trigger Property='IsPressed' Value='True'><Setter TargetName='cp' Property='Opacity' Value='0.7'/></Trigger>
          <Trigger Property='IsEnabled' Value='False'><Setter TargetName='cp' Property='Opacity' Value='0.45'/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value></Setter>
  </Style>
  <ControlTemplate x:Key='RowTemplate' TargetType='Button'>
    <Border x:Name='bd' Background='Transparent' CornerRadius='6' Padding='{TemplateBinding Padding}' SnapsToDevicePixels='True'>
      <ContentPresenter HorizontalAlignment='Stretch' VerticalAlignment='Center' RecognizesAccessKey='False'/>
    </Border>
    <ControlTemplate.Triggers>
      <Trigger Property='Tag' Value='Selected'><Setter TargetName='bd' Property='Background' Value='$selected'/></Trigger>
      <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='bd' Property='Background' Value='$hover'/></Trigger>
      <Trigger Property='IsPressed' Value='True'><Setter TargetName='bd' Property='Background' Value='$pressed'/></Trigger>
      <Trigger Property='IsEnabled' Value='False'><Setter TargetName='bd' Property='Opacity' Value='0.5'/></Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate>
  <Style x:Key='Row' TargetType='Button'>
    <Setter Property='FocusVisualStyle' Value='{StaticResource FocusRing}'/>
    <Setter Property='Foreground' Value='$ink'/>
    <Setter Property='Background' Value='Transparent'/>
    <Setter Property='Padding' Value='12,0'/>
    <Setter Property='Margin' Value='-12,0'/>
    <Setter Property='FontSize' Value='14'/>
    <Setter Property='HorizontalAlignment' Value='Stretch'/>
    <Setter Property='HorizontalContentAlignment' Value='Stretch'/>
    <Setter Property='Template' Value='{StaticResource RowTemplate}'/>
  </Style>
  <Style x:Key='Nav' TargetType='Button' BasedOn='{StaticResource Row}'>
    <Setter Property='Padding' Value='0'/>
    <Setter Property='Margin' Value='0,1'/>
    <Setter Property='MinHeight' Value='36'/>
  </Style>

  <Style TargetType='TextBox'>
    <Setter Property='FocusVisualStyle' Value='{x:Null}'/>
    <Setter Property='Background' Value='$surface'/>
    <Setter Property='Foreground' Value='$ink'/>
    <Setter Property='BorderBrush' Value='$stroke'/>
    <Setter Property='CaretBrush' Value='$ink'/>
    <Setter Property='SelectionBrush' Value='$accent'/>
    <Setter Property='Padding' Value='10,0'/>
    <Setter Property='MinHeight' Value='34'/>
    <Setter Property='FontSize' Value='14'/>
    <Setter Property='VerticalContentAlignment' Value='Center'/>
    <Setter Property='Template'><Setter.Value>
      <ControlTemplate TargetType='TextBox'>
        <Grid SnapsToDevicePixels='True'>
          <Border x:Name='bd' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='1' CornerRadius='6'/>
          <Border x:Name='underline' Height='1' VerticalAlignment='Bottom' Margin='5,0' Background='$strokeStrong'/>
          <ScrollViewer x:Name='PART_ContentHost' VerticalAlignment='{TemplateBinding VerticalContentAlignment}' Focusable='False' HorizontalScrollBarVisibility='Hidden' VerticalScrollBarVisibility='Hidden'/>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='bd' Property='Background' Value='#FFFFFFFF'/></Trigger>
          <Trigger Property='IsReadOnly' Value='True'><Setter TargetName='bd' Property='Background' Value='$controlPressed'/><Setter TargetName='underline' Property='Visibility' Value='Collapsed'/></Trigger>
          <Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='bd' Property='Background' Value='#FFFFFFFF'/><Setter TargetName='underline' Property='Height' Value='2'/><Setter TargetName='underline' Property='Margin' Value='3,0'/><Setter TargetName='underline' Property='Background' Value='$accent'/></Trigger>
          <Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.5'/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value></Setter>
  </Style>
  <Style TargetType='PasswordBox'>
    <Setter Property='FocusVisualStyle' Value='{x:Null}'/>
    <Setter Property='Background' Value='$surface'/>
    <Setter Property='Foreground' Value='$ink'/>
    <Setter Property='BorderBrush' Value='$stroke'/>
    <Setter Property='CaretBrush' Value='$ink'/>
    <Setter Property='SelectionBrush' Value='$accent'/>
    <Setter Property='Padding' Value='10,0'/>
    <Setter Property='MinHeight' Value='34'/>
    <Setter Property='FontSize' Value='14'/>
    <Setter Property='VerticalContentAlignment' Value='Center'/>
    <Setter Property='Template'><Setter.Value>
      <ControlTemplate TargetType='PasswordBox'>
        <Grid SnapsToDevicePixels='True'>
          <Border x:Name='bd' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='1' CornerRadius='6'/>
          <Border x:Name='underline' Height='1' VerticalAlignment='Bottom' Margin='5,0' Background='$strokeStrong'/>
          <ScrollViewer x:Name='PART_ContentHost' VerticalAlignment='{TemplateBinding VerticalContentAlignment}' Focusable='False' HorizontalScrollBarVisibility='Hidden' VerticalScrollBarVisibility='Hidden'/>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='bd' Property='Background' Value='#FFFFFFFF'/></Trigger>
          <Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='bd' Property='Background' Value='#FFFFFFFF'/><Setter TargetName='underline' Property='Height' Value='2'/><Setter TargetName='underline' Property='Margin' Value='3,0'/><Setter TargetName='underline' Property='Background' Value='$accent'/></Trigger>
          <Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.5'/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value></Setter>
  </Style>

  <Style TargetType='CheckBox'>
    <Setter Property='FocusVisualStyle' Value='{StaticResource FocusRing}'/>
    <Setter Property='Foreground' Value='$ink'/>
    <Setter Property='FontSize' Value='14'/>
    <Setter Property='Template'><Setter.Value>
      <ControlTemplate TargetType='CheckBox'>
        <Grid Background='Transparent'>
          <Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>
          <Border x:Name='box' Width='18' Height='18' CornerRadius='4' BorderThickness='1' BorderBrush='$strokeStrong' Background='$surface' VerticalAlignment='{TemplateBinding VerticalContentAlignment}' Margin='0,1,0,1' SnapsToDevicePixels='True'>
            <Path x:Name='mark' Data='M3.4,8.2 L6.6,11.4 L12.8,5' Stroke='#FFFFFFFF' StrokeThickness='1.8' StrokeStartLineCap='Round' StrokeEndLineCap='Round' StrokeLineJoin='Round' Visibility='Collapsed'/>
          </Border>
          <ContentPresenter Grid.Column='1' Margin='10,0,0,0' VerticalAlignment='{TemplateBinding VerticalContentAlignment}' RecognizesAccessKey='False'/>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='box' Property='BorderBrush' Value='$ink2'/></Trigger>
          <Trigger Property='IsChecked' Value='True'><Setter TargetName='box' Property='Background' Value='$accent'/><Setter TargetName='box' Property='BorderBrush' Value='$accent'/><Setter TargetName='mark' Property='Visibility' Value='Visible'/></Trigger>
          <Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.45'/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value></Setter>
  </Style>
  <Style x:Key='Switch' TargetType='CheckBox'>
    <Setter Property='FocusVisualStyle' Value='{StaticResource FocusRing}'/>
    <Setter Property='Foreground' Value='$ink'/>
    <Setter Property='FontSize' Value='14'/>
    <Setter Property='Template'><Setter.Value>
      <ControlTemplate TargetType='CheckBox'>
        <StackPanel Orientation='Horizontal' Background='Transparent'>
          <TextBlock x:Name='state' Text='Desactivado' VerticalAlignment='Center' Margin='0,0,12,0' Foreground='$ink2'/>
          <Border x:Name='track' Width='40' Height='20' CornerRadius='10' BorderThickness='1' BorderBrush='$ink3' Background='Transparent' SnapsToDevicePixels='True'>
            <Ellipse x:Name='thumb' Width='12' Height='12' Fill='$ink2' HorizontalAlignment='Left' VerticalAlignment='Center' Margin='4,0,0,0'/>
          </Border>
        </StackPanel>
        <ControlTemplate.Triggers>
          <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='track' Property='Background' Value='$hover'/></Trigger>
          <Trigger Property='IsChecked' Value='True'>
            <Setter TargetName='state' Property='Text' Value='Activado'/>
            <Setter TargetName='track' Property='Background' Value='$accent'/>
            <Setter TargetName='track' Property='BorderBrush' Value='$accent'/>
            <Setter TargetName='thumb' Property='Fill' Value='#FFFFFFFF'/>
            <Setter TargetName='thumb' Property='HorizontalAlignment' Value='Right'/>
            <Setter TargetName='thumb' Property='Width' Value='14'/>
            <Setter TargetName='thumb' Property='Height' Value='14'/>
            <Setter TargetName='thumb' Property='Margin' Value='0,0,2,0'/>
          </Trigger>
          <Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.45'/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value></Setter>
  </Style>
  <Style TargetType='RadioButton'>
    <Setter Property='FocusVisualStyle' Value='{StaticResource FocusRing}'/>
    <Setter Property='Foreground' Value='$ink'/>
    <Setter Property='FontSize' Value='14'/>
    <Setter Property='Template'><Setter.Value>
      <ControlTemplate TargetType='RadioButton'>
        <Grid Background='Transparent'>
          <Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>
          <Grid Width='20' Height='20' VerticalAlignment='Center'>
            <Ellipse x:Name='outer' Stroke='$strokeStrong' StrokeThickness='1' Fill='$surface'/>
            <Ellipse x:Name='dot' Width='8' Height='8' Fill='#FFFFFFFF' Visibility='Collapsed'/>
          </Grid>
          <ContentPresenter Grid.Column='1' Margin='10,0,0,0' VerticalAlignment='Center' RecognizesAccessKey='False'/>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='outer' Property='Stroke' Value='$ink2'/></Trigger>
          <Trigger Property='IsChecked' Value='True'><Setter TargetName='outer' Property='Fill' Value='$accent'/><Setter TargetName='outer' Property='Stroke' Value='$accent'/><Setter TargetName='dot' Property='Visibility' Value='Visible'/></Trigger>
          <Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.45'/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value></Setter>
  </Style>

  <Style TargetType='ComboBoxItem'>
    <Setter Property='FocusVisualStyle' Value='{x:Null}'/>
    <Setter Property='Foreground' Value='$ink'/>
    <Setter Property='Padding' Value='10,7'/>
    <Setter Property='Template'><Setter.Value>
      <ControlTemplate TargetType='ComboBoxItem'>
        <Border x:Name='bd' Background='Transparent' CornerRadius='4' Padding='{TemplateBinding Padding}' Margin='0,1'>
          <ContentPresenter/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property='IsSelected' Value='True'><Setter TargetName='bd' Property='Background' Value='$selected'/></Trigger>
          <Trigger Property='IsHighlighted' Value='True'><Setter TargetName='bd' Property='Background' Value='$hover'/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value></Setter>
  </Style>
  <Style TargetType='ComboBox'>
    <Setter Property='FocusVisualStyle' Value='{StaticResource FocusRing}'/>
    <Setter Property='Foreground' Value='$ink'/>
    <Setter Property='MinHeight' Value='34'/>
    <Setter Property='FontSize' Value='14'/>
    <Setter Property='Template'><Setter.Value>
      <ControlTemplate TargetType='ComboBox'>
        <Grid>
          <ToggleButton Focusable='False' ClickMode='Press' IsChecked='{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}'>
            <ToggleButton.Template><ControlTemplate TargetType='ToggleButton'>
              <Border x:Name='bd' Background='$surface' BorderBrush='$stroke' BorderThickness='1' CornerRadius='6' SnapsToDevicePixels='True'>
                <Path HorizontalAlignment='Right' VerticalAlignment='Center' Margin='0,0,12,0' Data='M0,0 L5,5 L10,0' Stroke='$ink2' StrokeThickness='1.5' StrokeStartLineCap='Round' StrokeEndLineCap='Round' StrokeLineJoin='Round'/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='bd' Property='Background' Value='#FFFFFFFF'/></Trigger>
                <Trigger Property='IsChecked' Value='True'><Setter TargetName='bd' Property='BorderBrush' Value='$strokeStrong'/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate></ToggleButton.Template>
          </ToggleButton>
          <ContentPresenter IsHitTestVisible='False' Margin='12,0,36,0' VerticalAlignment='Center' Content='{TemplateBinding SelectionBoxItem}' ContentTemplate='{TemplateBinding SelectionBoxItemTemplate}'/>
          <Popup x:Name='PART_Popup' IsOpen='{TemplateBinding IsDropDownOpen}' Placement='Bottom' AllowsTransparency='True' Focusable='False' PopupAnimation='None'>
            <Border Background='$surface' BorderBrush='$stroke' BorderThickness='1' CornerRadius='8' Padding='4' Margin='0,4,0,0' MinWidth='{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}' MaxHeight='{TemplateBinding MaxDropDownHeight}'>
              <ScrollViewer><ItemsPresenter KeyboardNavigation.DirectionalNavigation='Contained'/></ScrollViewer>
            </Border>
          </Popup>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.5'/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value></Setter>
  </Style>

  <Style TargetType='Expander'>
    <Setter Property='Foreground' Value='$ink'/>
    <Setter Property='FontSize' Value='14'/>
    <Setter Property='Template'><Setter.Value>
      <ControlTemplate TargetType='Expander'>
        <StackPanel>
          <ToggleButton x:Name='header' FocusVisualStyle='{StaticResource FocusRing}' IsChecked='{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}' Content='{TemplateBinding Header}' Foreground='{TemplateBinding Foreground}'>
            <ToggleButton.Template><ControlTemplate TargetType='ToggleButton'>
              <Border x:Name='bd' Background='Transparent' Padding='0,13' BorderBrush='$hairline' BorderThickness='0,1,0,0' SnapsToDevicePixels='True'>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
                  <ContentPresenter VerticalAlignment='Center' TextElement.FontWeight='SemiBold' RecognizesAccessKey='False'/>
                  <Path x:Name='chevron' Grid.Column='1' Margin='12,0,2,0' VerticalAlignment='Center' Data='M0,0 L5,5 L10,0' Stroke='$ink2' StrokeThickness='1.5' StrokeStartLineCap='Round' StrokeEndLineCap='Round' StrokeLineJoin='Round'/>
                </Grid>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property='IsChecked' Value='True'><Setter TargetName='chevron' Property='Data' Value='M0,5 L5,0 L10,5'/></Trigger>
                <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='chevron' Property='Stroke' Value='$ink'/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate></ToggleButton.Template>
          </ToggleButton>
          <ContentPresenter x:Name='body' Visibility='Collapsed' Margin='0,0,0,12'/>
        </StackPanel>
        <ControlTemplate.Triggers>
          <Trigger Property='IsExpanded' Value='True'><Setter TargetName='body' Property='Visibility' Value='Visible'/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value></Setter>
  </Style>

  <ControlTemplate x:Key='ThumbTemplate' TargetType='Thumb'>
    <Border x:Name='t' Background='$strokeStrong' Opacity='0.55' CornerRadius='3'/>
    <ControlTemplate.Triggers>
      <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='t' Property='Opacity' Value='0.85'/></Trigger>
      <Trigger Property='IsDragging' Value='True'><Setter TargetName='t' Property='Opacity' Value='1'/></Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate>
  <ControlTemplate x:Key='PageButton' TargetType='RepeatButton'><Border Background='Transparent'/></ControlTemplate>
  <Style TargetType='ScrollBar'>
    <Setter Property='Width' Value='12'/>
    <Setter Property='MinWidth' Value='12'/>
    <Setter Property='Template'><Setter.Value>
      <ControlTemplate TargetType='ScrollBar'>
        <Grid Background='Transparent'>
          <Track x:Name='PART_Track' IsDirectionReversed='True' Margin='3,2'>
            <Track.DecreaseRepeatButton><RepeatButton Command='ScrollBar.PageUpCommand' Focusable='False' Template='{StaticResource PageButton}'/></Track.DecreaseRepeatButton>
            <Track.IncreaseRepeatButton><RepeatButton Command='ScrollBar.PageDownCommand' Focusable='False' Template='{StaticResource PageButton}'/></Track.IncreaseRepeatButton>
            <Track.Thumb><Thumb Template='{StaticResource ThumbTemplate}'/></Track.Thumb>
          </Track>
        </Grid>
      </ControlTemplate>
    </Setter.Value></Setter>
    <Style.Triggers>
      <Trigger Property='Orientation' Value='Horizontal'>
        <Setter Property='Width' Value='Auto'/>
        <Setter Property='MinWidth' Value='0'/>
        <Setter Property='Height' Value='12'/>
        <Setter Property='Template'><Setter.Value>
          <ControlTemplate TargetType='ScrollBar'>
            <Grid Background='Transparent'>
              <Track x:Name='PART_Track' Margin='2,3'>
                <Track.DecreaseRepeatButton><RepeatButton Command='ScrollBar.PageLeftCommand' Focusable='False' Template='{StaticResource PageButton}'/></Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton><RepeatButton Command='ScrollBar.PageRightCommand' Focusable='False' Template='{StaticResource PageButton}'/></Track.IncreaseRepeatButton>
                <Track.Thumb><Thumb Template='{StaticResource ThumbTemplate}'/></Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value></Setter>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style TargetType='ProgressBar'>
    <Setter Property='Height' Value='4'/>
    <Setter Property='Foreground' Value='$accent'/>
    <Setter Property='Background' Value='$hairline'/>
    <Setter Property='BorderThickness' Value='0'/>
    <Setter Property='Template'><Setter.Value>
      <ControlTemplate TargetType='ProgressBar'>
        <Grid SnapsToDevicePixels='True'>
          <Border x:Name='PART_Track' Background='{TemplateBinding Background}' CornerRadius='2'/>
          <Border x:Name='PART_Indicator' Background='{TemplateBinding Foreground}' CornerRadius='2' HorizontalAlignment='Left'/>
        </Grid>
      </ControlTemplate>
    </Setter.Value></Setter>
  </Style>

  <Style TargetType='ToolTip'>
    <Setter Property='Foreground' Value='$ink'/>
    <Setter Property='FontSize' Value='12'/>
    <Setter Property='Template'><Setter.Value>
      <ControlTemplate TargetType='ToolTip'>
        <Border Background='$surface' BorderBrush='$stroke' BorderThickness='1' CornerRadius='6' Padding='8,5'>
          <ContentPresenter/>
        </Border>
      </ControlTemplate>
    </Setter.Value></Setter>
  </Style>
</ResourceDictionary>";
  }
}
