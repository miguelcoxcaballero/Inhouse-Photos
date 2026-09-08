$ErrorActionPreference = 'Stop'
$desktopRoot = $PSScriptRoot
$outDir = Join-Path $desktopRoot 'dist'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$wpf = Join-Path $framework 'WPF'
# Render the repository's vector mark into the executable's Windows icon.
Add-Type -AssemblyName PresentationCore,PresentationFramework,WindowsBase
$brandPath = Join-Path $desktopRoot 'brand.xaml'
$drawing = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText($brandPath))
$visual = [Windows.Media.DrawingVisual]::new()
$context = $visual.RenderOpen()
$context.DrawImage($drawing, [Windows.Rect]::new(0,0,256,256))
$context.Close()
$bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(256,256,96,96,[Windows.Media.PixelFormats]::Pbgra32)
$bitmap.Render($visual)
$encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
$png = [IO.MemoryStream]::new()
$encoder.Save($png)
$iconPath = Join-Path $outDir 'inhouse.ico'
$writer = [IO.BinaryWriter]::new([IO.File]::Create($iconPath))
try {
  $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]1)
  $writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([byte]0)
  $writer.Write([uint16]1); $writer.Write([uint16]32)
  $writer.Write([uint32]$png.Length); $writer.Write([uint32]22)
  $writer.Write($png.ToArray())
} finally { $writer.Dispose(); $png.Dispose() }
& (Join-Path $framework 'csc.exe') /nologo /target:winexe /platform:x64 /optimize+ /utf8output `
  "/out:$outDir\Inhouse-Photos-Server.exe" `
  "/win32icon:$iconPath" "/resource:$brandPath,InhousePhotos.brand.xaml" `
  /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll `
  /reference:System.Management.dll /reference:System.Security.dll /reference:System.Xaml.dll `
  /reference:System.Windows.Forms.dll /reference:Microsoft.CSharp.dll `
  "/reference:$wpf\PresentationFramework.dll" "/reference:$wpf\PresentationCore.dll" "/reference:$wpf\WindowsBase.dll" `
  (Join-Path $desktopRoot 'ServerApp.cs')
if ($LASTEXITCODE -ne 0) { throw 'Windows compilation failed' }
Write-Output "$outDir\Inhouse-Photos-Server.exe"
