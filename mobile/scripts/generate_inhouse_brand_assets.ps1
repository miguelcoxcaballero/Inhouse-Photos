Add-Type -AssemblyName System.Drawing

$mobileRoot = Split-Path -Parent $PSScriptRoot
$gradientTop = [System.Drawing.ColorTranslator]::FromHtml('#F5843F')
$gradientBottom = [System.Drawing.ColorTranslator]::FromHtml('#DA5520')
$white = [System.Drawing.Color]::White
$amber = [System.Drawing.ColorTranslator]::FromHtml('#FFC447')

# The app icon is designed on the 108dp adaptive canvas. Launchers show the
# central 72 units (18..90), which is the "tile" drawn below.
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

# Viewfinder corners, mountain roof, small peak and sun in canvas units.
function Draw-InhouseForeground {
  param(
    [System.Drawing.Graphics]$Graphics,
    [scriptblock]$P,
    [float]$Scale,
    [System.Drawing.Color]$Ink,
    [System.Drawing.Color]$Sun
  )

  $cornerPen = New-RoundPen $Ink (4.2 * $Scale)
  $peakPen = New-RoundPen $Ink (3.8 * $Scale)
  $mountainPen = New-RoundPen $Ink (5.2 * $Scale)
  $sunBrush = [System.Drawing.SolidBrush]::new($Sun)
  try {
    # Corners: box 31..77, arm 11, radius 6.
    foreach ($corner in @(
        @(31, 42, 31, 37, 180, 37, 31, 42, 31),
        @(66, 31, 71, 31, 270, 77, 37, 77, 42),
        @(77, 66, 77, 71, 0, 71, 77, 66, 77),
        @(42, 77, 37, 77, 90, 31, 71, 31, 66))) {
      $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
      try {
        $a = & $P $corner[0] $corner[1]
        $b = & $P $corner[2] $corner[3]
        $path.AddLine($a, $b)
        $arcOrigin = switch ($corner[4]) {
          180 { & $P 31 31 }
          270 { & $P 65 31 }
          0 { & $P 65 65 }
          90 { & $P 31 65 }
        }
        $path.AddArc($arcOrigin.X, $arcOrigin.Y, 12 * $Scale, 12 * $Scale, $corner[4], 90)
        $c = & $P $corner[5] $corner[6]
        $d = & $P $corner[7] $corner[8]
        $path.AddLine($c, $d)
        $Graphics.DrawPath($cornerPen, $path)
      } finally {
        $path.Dispose()
      }
    }

    $Graphics.DrawLines($peakPen, [System.Drawing.PointF[]]@((& $P 58.4 55.3), (& $P 61.9 51.8), (& $P 68.4 58.3)))
    $Graphics.DrawLines($mountainPen, [System.Drawing.PointF[]]@((& $P 41.4 64.8), (& $P 50.4 55.8), (& $P 59.4 64.8)))
    $sunCentre = & $P 41.9 44.8
    $Graphics.FillEllipse($sunBrush, $sunCentre.X - 3.9 * $Scale, $sunCentre.Y - 3.9 * $Scale, 7.8 * $Scale, 7.8 * $Scale)
  } finally {
    $cornerPen.Dispose()
    $peakPen.Dispose()
    $mountainPen.Dispose()
    $sunBrush.Dispose()
  }
}

# Mode: tile (rounded icon on transparency, $Fraction of the image), square
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

    if ($Mode -ne 'foreground' -and $Mode -ne 'monochrome') {
      # The launcher background spans the whole 108-unit canvas; the rounded
      # tile carries the full gradient on its own 72 units.
      if ($Mode -eq 'tile') {
        $top = & $P 0 18
        $bottom = & $P 0 90
      } else {
        $top = & $P 0 0
        $bottom = & $P 0 108
      }
      $brush = [System.Drawing.Drawing2D.LinearGradientBrush]::new($top, $bottom, $gradientTop, $gradientBottom)
      try {
        if ($Mode -eq 'tile') {
          $tile = & $P 18 18
          $tilePath = New-RoundedRectanglePath -X $tile.X -Y $tile.Y -Width (72 * $scale) -Height (72 * $scale) -Radius (17 * $scale)
          try { $graphics.FillPath($brush, $tilePath) } finally { $tilePath.Dispose() }
        } else {
          $graphics.FillRectangle($brush, 0, 0, $Size, $Size)
        }
      } finally {
        $brush.Dispose()
      }
    }

    if ($Mode -eq 'monochrome') {
      Draw-InhouseForeground $graphics $P $scale $white $white
    } elseif ($Mode -ne 'background') {
      Draw-InhouseForeground $graphics $P $scale $white $amber
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

# Runtime splash marks are transparent and identical in light/dark mode.
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
