Add-Type -AssemblyName System.Drawing

$mobileRoot = Split-Path -Parent $PSScriptRoot
$orange = [System.Drawing.ColorTranslator]::FromHtml('#D97736')
$cream = [System.Drawing.ColorTranslator]::FromHtml('#F5F5F0')

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

function Write-InhouseLogoPng {
  param(
    [string]$Path,
    [int]$Size,
    [double]$PaintedFraction,
    [string]$BackgroundHex
  )

  $bitmap = [System.Drawing.Bitmap]::new(
    $Size,
    $Size,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
  )
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

  try {
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.Clear(
      $(if ($BackgroundHex) {
        [System.Drawing.ColorTranslator]::FromHtml($BackgroundHex)
      } else {
        [System.Drawing.Color]::Transparent
      })
    )

    # The SVG's painted bounds span 67 view-box units once stroke width is included.
    $scale = ($Size * $PaintedFraction) / 67.0
    $originX = ($Size / 2.0) - (50 * $scale)
    $originY = ($Size / 2.0) - (50 * $scale)

    $outerPen = [System.Drawing.Pen]::new($orange, 7 * $scale)
    $backMountainPen = [System.Drawing.Pen]::new($orange, 5 * $scale)
    $frontMountainPen = [System.Drawing.Pen]::new($orange, 7 * $scale)
    $orangeBrush = [System.Drawing.SolidBrush]::new($orange)

    try {
      foreach ($pen in @($outerPen, $backMountainPen, $frontMountainPen)) {
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
      }

      $outerPath = New-RoundedRectanglePath `
        -X ($originX + (20 * $scale)) `
        -Y ($originY + (20 * $scale)) `
        -Width (60 * $scale) `
        -Height (60 * $scale) `
        -Radius (6 * $scale)
      try {
        $graphics.DrawPath($outerPen, $outerPath)
      } finally {
        $outerPath.Dispose()
      }

      $graphics.FillEllipse(
        $orangeBrush,
        $originX + (32 * $scale),
        $originY + (32 * $scale),
        12 * $scale,
        12 * $scale
      )
      $graphics.DrawLines(
        $backMountainPen,
        [System.Drawing.PointF[]]@(
          [System.Drawing.PointF]::new($originX + (57 * $scale), $originY + (52 * $scale)),
          [System.Drawing.PointF]::new($originX + (63 * $scale), $originY + (46 * $scale)),
          [System.Drawing.PointF]::new($originX + (72 * $scale), $originY + (55 * $scale))
        )
      )
      $graphics.DrawLines(
        $frontMountainPen,
        [System.Drawing.PointF[]]@(
          [System.Drawing.PointF]::new($originX + (31 * $scale), $originY + (68 * $scale)),
          [System.Drawing.PointF]::new($originX + (50 * $scale), $originY + (49 * $scale)),
          [System.Drawing.PointF]::new($originX + (69 * $scale), $originY + (68 * $scale))
        )
      )
    } finally {
      $outerPen.Dispose()
      $backMountainPen.Dispose()
      $frontMountainPen.Dispose()
      $orangeBrush.Dispose()
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

# Runtime marks are transparent and identical in light/dark mode.
Write-InhouseLogoPng 'assets\inhouse-photos-splash.png' 768 0.52 $null
Write-InhouseLogoPng 'assets\inhouse-photos-splash-light.png' 768 0.52 $null
Write-InhouseLogoPng 'assets\inhouse-photos-icon.png' 1024 0.64 $null
Write-InhouseLogoPng 'assets\inhouse-photos-icon-light.png' 1024 0.64 '#F5F5F0'
Write-InhouseLogoPng 'assets\inhouse-photos-icon-foreground.png' 1024 0.60 $null
Write-InhouseLogoPng 'assets\inhouse-photos-icon-foreground-light.png' 1024 0.60 $null
Copy-Item `
  (Join-Path $mobileRoot 'assets\inhouse-photos-icon-light.png') `
  (Join-Path $mobileRoot 'assets\immich-logo.png') `
  -Force

# Android 12 masks splash artwork to a circle. These bounds stay entirely inside its safe circle.
Write-InhouseLogoPng 'assets\inhouse-photos-splash-android12.png' 1152 0.43 $null

# Store metadata and iOS source icons use the same orange mark on the light brand surface.
Write-InhouseLogoPng 'android\metadata\en-US\images\icon.png' 512 0.64 '#F5F5F0'
Write-InhouseLogoPng 'android\fastlane\metadata\android\en-US\images\icon.png' 512 0.64 '#F5F5F0'

$iosIconRoot = Join-Path $mobileRoot 'ios\Runner\Assets.xcassets\AppIcon.appiconset'
Get-ChildItem -LiteralPath $iosIconRoot -Filter '*.png' | ForEach-Object {
  $existing = [System.Drawing.Image]::FromFile($_.FullName)
  try {
    $iconSize = $existing.Width
  } finally {
    $existing.Dispose()
  }
  Write-InhouseLogoPng ("ios\Runner\Assets.xcassets\AppIcon.appiconset\{0}" -f $_.Name) $iconSize 0.64 '#F5F5F0'
}
