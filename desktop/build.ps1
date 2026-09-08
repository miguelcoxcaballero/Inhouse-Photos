$ErrorActionPreference = 'Stop'
$desktopRoot = $PSScriptRoot
$outDir = Join-Path $desktopRoot 'dist'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$wpf = Join-Path $framework 'WPF'
$compilerVersion = '4.14.0'
$compilerRoot = Join-Path $outDir "compiler-$compilerVersion"
$compilerExe = Join-Path $compilerRoot 'tasks\net472\csc.exe'
if (-not (Test-Path -LiteralPath $compilerExe)) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $packageUrl = "https://api.nuget.org/v3-flatcontainer/microsoft.net.compilers.toolset/$compilerVersion/microsoft.net.compilers.toolset.$compilerVersion.nupkg"
  $package = Join-Path $outDir "compiler-$compilerVersion.nupkg"
  if (-not (Test-Path -LiteralPath $package)) { Invoke-WebRequest -Uri $packageUrl -OutFile $package -UseBasicParsing }
  # SHA-512 published in NuGet's immutable catalog entry for 4.14.0.
  $expected = 'h5GExC3fx0fm0qHw8rQ6y5c0uk6cCiAsorLl9Hq/9VlotEvsv/oW60RNo8HOYApv66kNqJq4Bg/TkSAsgQAwbQ=='
  $algorithm = [Security.Cryptography.SHA512]::Create()
  $stream = [IO.File]::OpenRead($package)
  try { $actual = [Convert]::ToBase64String($algorithm.ComputeHash($stream)) } finally { $stream.Dispose(); $algorithm.Dispose() }
  if ($expected -ne $actual) { throw 'Compiler package checksum mismatch' }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::ExtractToDirectory($package,$compilerRoot)
}
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
$sources = (Get-ChildItem -LiteralPath $desktopRoot -Filter '*.cs' -File).FullName
& $compilerExe /nologo /target:winexe /platform:x64 /optimize+ /utf8output /langversion:latest /deterministic /main:InhousePhotos.Program `
  "/out:$outDir\Inhouse-Photos-Server.exe" `
  "/win32icon:$iconPath" "/resource:$brandPath,InhousePhotos.brand.xaml" `
  "/resource:$desktopRoot\storage.ps1,InhousePhotos.storage.ps1" `
  /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll `
  /reference:System.Management.dll /reference:System.Security.dll /reference:System.Xaml.dll `
  /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:Microsoft.CSharp.dll `
  "/reference:$wpf\PresentationFramework.dll" "/reference:$wpf\PresentationCore.dll" "/reference:$wpf\WindowsBase.dll" `
  $sources
if ($LASTEXITCODE -ne 0) { throw 'Windows compilation failed' }
$payloadHash = Join-Path $outDir 'payload.sha256'
[IO.File]::WriteAllText($payloadHash,(Get-FileHash (Join-Path $outDir 'Inhouse-Photos-Server.exe') -Algorithm SHA256).Hash.ToLowerInvariant())
& $compilerExe /nologo /target:winexe /platform:x64 /optimize+ /utf8output /langversion:latest /deterministic /main:InhousePhotos.SetupProgram `
  "/out:$outDir\Inhouse-Photos-Server-Setup.exe" "/win32icon:$iconPath" `
  "/resource:$brandPath,InhousePhotos.brand.xaml" "/resource:$outDir\Inhouse-Photos-Server.exe,InhousePhotos.payload.exe" "/resource:$payloadHash,InhousePhotos.payload.sha256" `
  "/resource:$desktopRoot\storage.ps1,InhousePhotos.storage.ps1" `
  /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll /reference:System.Management.dll /reference:System.Security.dll /reference:System.Xaml.dll `
  /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:Microsoft.CSharp.dll `
  "/reference:$wpf\PresentationFramework.dll" "/reference:$wpf\PresentationCore.dll" "/reference:$wpf\WindowsBase.dll" $sources
if ($LASTEXITCODE -ne 0) { throw 'Windows installer compilation failed' }
Write-Output "$outDir\Inhouse-Photos-Server.exe"
Write-Output "$outDir\Inhouse-Photos-Server-Setup.exe"
