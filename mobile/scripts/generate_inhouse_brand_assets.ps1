Add-Type -AssemblyName System.Drawing

$mobileRoot = Split-Path -Parent $PSScriptRoot
$gradientTop = [System.Drawing.ColorTranslator]::FromHtml('#F5843F')
$gradientBottom = [System.Drawing.ColorTranslator]::FromHtml('#DA5520')
$white = [System.Drawing.Color]::White
$amber = [System.Drawing.ColorTranslator]::FromHtml('#FFC447')
$edge = [System.Drawing.ColorTranslator]::FromHtml('#EBDDD2')

# The app icon is designed on the 108dp adaptive canvas. Launchers show the
# central 72 units (18..90), which is the "tile" drawn below. The icon is a white
# tile with an instant-camera print tilted -8 degrees: a copper photo window with
# the family roof as the white mountain, the small peak and the amber sun.
function New-RoundedRectanglePath {
  param(
    [float]$X,
    [float]$Y,
    [float]$Width,
    [float]$Height,
    [float]$Radius
  )

  $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
  $diameter = $Radius * 2
  $path.AddArc($X, $Y, $diameter, $diameter, 180, 90)
  $path.AddArc($X + $Width - $diameter, $Y, $diameter, $diameter, 270, 90)
  $path.AddArc($X + $Width - $diameter, $Y + $Height - $diameter, $diameter, $diameter, 0, 90)
  $path.AddArc($X, $Y + $Height - $diameter, $diameter, $diameter, 90, 90)
  $path.CloseFigure()
  return $path
}

function New-RoundPen {
  param([System.Drawing.Color]$Color, [float]$Width)

  $pen = [System.Drawing.Pen]::new($Color, $Width)
  $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  return $pen
}

# Rounded rectangle in canvas units.
function New-CanvasRect {
  param([scriptblock]$P, [float]$Scale, [float]$X, [float]$Y, [float]$Width, [float]$Height, [float]$Radius)

  $origin = & $P $X $Y
  return New-RoundedRectanglePath -X $origin.X -Y $origin.Y -Width ($Width * $Scale) -Height ($Height * $Scale) -Radius ($Radius * $Scale)
}

# The print: 46 x 52 frame (4 at the sides and top, 11 at the bottom), a 38 x 37
# photo window and the scene, tilted -8 degrees around (54, 52). Monochrome draws
# the frame with its window cut out and the scene in one colour.
function Draw-InhousePrint {
  param(
    [System.Drawing.Graphics]$Graphics,
    [scriptblock]$P,
    [float]$Scale,
    [bool]$Monochrome
  )

  $state = $Graphics.Save()
  $pivot = & $P 54 52
  $Graphics.TranslateTransform($pivot.X, $pivot.Y)
  $Graphics.RotateTransform(-8)
  $Graphics.TranslateTransform(-$pivot.X, -$pivot.Y)
  $peakPen = New-RoundPen $white (3.8 * $Scale)
  $mountainPen = New-RoundPen $white (5.2 * $Scale)
  $sunBrush = [System.Drawing.SolidBrush]::new($(if ($Monochrome) { $white } else { $amber }))
  try {
    if ($Monochrome) {
      $ring = New-CanvasRect $P $Scale 31 26 46 52 0
      $ring.AddPath((New-CanvasRect $P $Scale 35 30 38 37 0), $false)
      $ring.FillMode = [System.Drawing.Drawing2D.FillMode]::Alternate
      $whiteBrush = [System.Drawing.SolidBrush]::new($white)
      try { $Graphics.FillPath($whiteBrush, $ring) } finally { $whiteBrush.Dispose(); $ring.Dispose() }
    } else {
      # Two soft offset copies stand in for the print's drop shadow.
      foreach ($layer in @(@(1.4, 2.2, 18), @(0.6, 1.0, 31))) {
        $grow = $layer[0]
        $shadow = New-CanvasRect $P $Scale (31 - $grow) (26 - $grow + $layer[1]) (46 + 2 * $grow) (52 + 2 * $grow) (2.8 + $grow)
        $shadowBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb($layer[2], 90, 58, 40))
        try { $Graphics.FillPath($shadowBrush, $shadow) } finally { $shadowBrush.Dispose(); $shadow.Dispose() }
      }
      $frame = New-CanvasRect $P $Scale 31 26 46 52 2.8
      $whiteBrush = [System.Drawing.SolidBrush]::new($white)
      $edgePen = [System.Drawing.Pen]::new($edge, 0.6 * $Scale)
      try { $Graphics.FillPath($whiteBrush, $frame); $Graphics.DrawPath($edgePen, $frame) }
      finally { $whiteBrush.Dispose(); $edgePen.Dispose(); $frame.Dispose() }
      $window = New-CanvasRect $P $Scale 35 30 38 37 1.2
      $windowBrush = [System.Drawing.Drawing2D.LinearGradientBrush]::new((& $P 0 30), (& $P 0 67), $gradientTop, $gradientBottom)
      try { $Graphics.FillPath($windowBrush, $window) } finally { $windowBrush.Dispose(); $window.Dispose() }
    }
    $Graphics.DrawLines($peakPen, [System.Drawing.PointF[]]@((& $P 57.85 50.15), (& $P 61.35 46.65), (& $P 67.85 53.15)))
    $Graphics.DrawLines($mountainPen, [System.Drawing.PointF[]]@((& $P 40.85 59.65), (& $P 49.85 50.65), (& $P 58.85 59.65)))
    $sunCentre = & $P 41.35 39.65
    $Graphics.FillEllipse($sunBrush, $sunCentre.X - 3.9 * $Scale, $sunCentre.Y - 3.9 * $Scale, 7.8 * $Scale, 7.8 * $Scale)
  } finally {
    $peakPen.Dispose()
    $mountainPen.Dispose()
    $sunBrush.Dispose()
    $Graphics.Restore($state)
  }
}

# Mode: tile (white rounded icon on transparency, $Fraction of the image), square
# (opaque visible area), foreground / background / monochrome (adaptive layers
# on the full 108-unit canvas).
function Write-InhousePhotosIcon {
  param(
    [string]$Path,
    [int]$Size,
    [double]$Fraction,
    [string]$Mode
  )

  $bitmap = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.Clear([System.Drawing.Color]::Transparent)

    if ($Mode -in @('foreground', 'background', 'monochrome')) {
      $scale = $Size / 108.0
      $originX = 0.0
      $originY = 0.0
    } else {
      $scale = ($Size * $Fraction) / 72.0
      $originX = ($Size / 2.0) - (54 * $scale)
      $originY = ($Size / 2.0) - (54 * $scale)
    }
    $P = { param($x, $y) [System.Drawing.PointF]::new($originX + $x * $scale, $originY + $y * $scale) }.GetNewClosure()

    $whiteBrush = [System.Drawing.SolidBrush]::new($white)
    try {
      if ($Mode -eq 'tile') {
        $tile = New-CanvasRect $P $scale 18 18 72 72 17
        try { $graphics.FillPath($whiteBrush, $tile) } finally { $tile.Dispose() }
      } elseif ($Mode -in @('square', 'background')) {
        $graphics.FillRectangle($whiteBrush, 0, 0, $Size, $Size)
      }
    } finally {
      $whiteBrush.Dispose()
    }

    if ($Mode -ne 'background') {
      Draw-InhousePrint $graphics $P $scale ($Mode -eq 'monochrome')
    }

    $absolutePath = Join-Path $mobileRoot $Path
    $parent = Split-Path -Parent $absolutePath
    if (-not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Path $parent | Out-Null
    }
    $bitmap.Save($absolutePath, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    $graphics.Dispose()
    $bitmap.Dispose()
  }
}

# Runtime splash marks: the white tile on transparency, identical in light/dark mode.
Write-InhousePhotosIcon 'assets\inhouse-photos-splash.png' 768 0.52 'tile'
Write-InhousePhotosIcon 'assets\inhouse-photos-splash-light.png' 768 0.52 'tile'
Write-InhousePhotosIcon 'assets\inhouse-photos-icon.png' 1024 0.64 'tile'
Write-InhousePhotosIcon 'assets\inhouse-photos-icon-light.png' 1024 1 'square'
Write-InhousePhotosIcon 'assets\inhouse-photos-icon-foreground.png' 1024 1 'foreground'
Write-InhousePhotosIcon 'assets\inhouse-photos-icon-foreground-light.png' 1024 1 'foreground'
Write-InhousePhotosIcon 'assets\inhouse-photos-icon-background.png' 1024 1 'background'
Write-InhousePhotosIcon 'assets\inhouse-photos-icon-monochrome.png' 1024 1 'monochrome'
Copy-Item `
  (Join-Path $mobileRoot 'assets\inhouse-photos-icon-light.png') `
  (Join-Path $mobileRoot 'assets\inhouse-photos-logo.png') `
  -Force

# Android 12 masks splash artwork to a circle. These bounds stay entirely inside its safe circle.
Write-InhousePhotosIcon 'assets\inhouse-photos-splash-android12.png' 1152 0.43 'tile'

# Store metadata and iOS app icons are opaque squares of the visible icon area.
Write-InhousePhotosIcon 'android\metadata\en-US\images\icon.png' 512 1 'square'
Write-InhousePhotosIcon 'android\fastlane\metadata\android\en-US\images\icon.png' 512 1 'square'

$iosIconRoot = Join-Path $mobileRoot 'ios\Runner\Assets.xcassets\AppIcon.appiconset'
Get-ChildItem -LiteralPath $iosIconRoot -Filter '*.png' | ForEach-Object {
  $existing = [System.Drawing.Image]::FromFile($_.FullName)
  try {
    $iconSize = $existing.Width
  } finally {
    $existing.Dispose()
  }
  Write-InhousePhotosIcon ("ios\Runner\Assets.xcassets\AppIcon.appiconset\{0}" -f $_.Name) $iconSize 1 'square'
}
