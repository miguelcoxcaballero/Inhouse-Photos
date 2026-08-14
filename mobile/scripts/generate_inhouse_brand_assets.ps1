Add-Type -AssemblyName System.Drawing

function New-RoundedRectanglePath([float]$X, [float]$Y, [float]$Width, [float]$Height, [float]$Radius) {
  $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
  $diameter = $Radius * 2
  $path.AddArc($X, $Y, $diameter, $diameter, 180, 90)
  $path.AddArc($X + $Width - $diameter, $Y, $diameter, $diameter, 270, 90)
  $path.AddArc($X + $Width - $diameter, $Y + $Height - $diameter, $diameter, $diameter, 0, 90)
  $path.AddArc($X, $Y + $Height - $diameter, $diameter, $diameter, 90, 90)
  $path.CloseFigure()
  return $path
}

function New-InhouseIcon([string]$Path, [bool]$Transparent, [bool]$Light, [int]$Size = 1024) {
  $bitmap = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

  $copper = [System.Drawing.ColorTranslator]::FromHtml('#D97736')
  $cream = [System.Drawing.ColorTranslator]::FromHtml('#F5F5F0')
  $black = [System.Drawing.Color]::Black
  $background = if ($Light) { $cream } else { $black }
  $foreground = if ($Light) { $black } else { $cream }
  $graphics.Clear($(if ($Transparent) { [System.Drawing.Color]::Transparent } else { $background }))

  $scale = $Size / 100.0
  $framePath = New-RoundedRectanglePath (20 * $scale) (20 * $scale) (60 * $scale) (60 * $scale) (6 * $scale)
  $framePen = [System.Drawing.Pen]::new($foreground, 7 * $scale)
  $framePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  $graphics.DrawPath($framePen, $framePath)

  $sunBrush = [System.Drawing.SolidBrush]::new($foreground)
  $graphics.FillEllipse($sunBrush, 32 * $scale, 32 * $scale, 12 * $scale, 12 * $scale)

  $backPen = [System.Drawing.Pen]::new($foreground, 5 * $scale)
  $backPen.StartCap = $backPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $backPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  $graphics.DrawLines($backPen, @(
    [System.Drawing.PointF]::new(57 * $scale, 52 * $scale),
    [System.Drawing.PointF]::new(63 * $scale, 46 * $scale),
    [System.Drawing.PointF]::new(72 * $scale, 55 * $scale)
  ))

  $frontPen = [System.Drawing.Pen]::new($copper, 7 * $scale)
  $frontPen.StartCap = $frontPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $frontPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  $graphics.DrawLines($frontPen, @(
    [System.Drawing.PointF]::new(31 * $scale, 68 * $scale),
    [System.Drawing.PointF]::new(50 * $scale, 49 * $scale),
    [System.Drawing.PointF]::new(69 * $scale, 68 * $scale)
  ))

  $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $frontPen.Dispose()
  $backPen.Dispose()
  $sunBrush.Dispose()
  $framePen.Dispose()
  $framePath.Dispose()
  $graphics.Dispose()
  $bitmap.Dispose()
}

$assets = Join-Path $PSScriptRoot '..\assets'
New-InhouseIcon (Join-Path $assets 'inhouse-photos-icon.png') $false $false
New-InhouseIcon (Join-Path $assets 'inhouse-photos-icon-light.png') $false $true
New-InhouseIcon (Join-Path $assets 'inhouse-photos-icon-foreground.png') $true $false
New-InhouseIcon (Join-Path $assets 'inhouse-photos-icon-foreground-light.png') $true $true
New-InhouseIcon (Join-Path $assets 'inhouse-photos-splash.png') $true $false 768
New-InhouseIcon (Join-Path $assets 'inhouse-photos-splash-light.png') $true $true 768
Copy-Item (Join-Path $assets 'inhouse-photos-icon.png') (Join-Path $assets 'immich-logo.png') -Force
