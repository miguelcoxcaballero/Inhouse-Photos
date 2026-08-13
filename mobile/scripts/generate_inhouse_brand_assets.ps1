Add-Type -AssemblyName System.Drawing

function New-InhouseIcon([string]$Path, [bool]$Transparent, [int]$Size = 1024) {
  $bitmap = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.Clear($(if ($Transparent) { [System.Drawing.Color]::Transparent } else { [System.Drawing.Color]::Black }))

  $copper = [System.Drawing.ColorTranslator]::FromHtml('#D97736')
  $cream = [System.Drawing.ColorTranslator]::FromHtml('#F5F5F0')
  $black = [System.Drawing.Color]::Black
  $scale = $Size / 100.0
  $pen = [System.Drawing.Pen]::new($copper, 8 * $scale)
  $pen.StartCap = $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  $graphics.DrawLines($pen, @(
    [System.Drawing.PointF]::new(17 * $scale, 48 * $scale),
    [System.Drawing.PointF]::new(50 * $scale, 18 * $scale),
    [System.Drawing.PointF]::new(83 * $scale, 48 * $scale)
  ))
  $house = @(
    [System.Drawing.PointF]::new(26 * $scale, 46 * $scale),
    [System.Drawing.PointF]::new(26 * $scale, 80 * $scale),
    [System.Drawing.PointF]::new(74 * $scale, 80 * $scale),
    [System.Drawing.PointF]::new(74 * $scale, 46 * $scale)
  )
  $graphics.FillPolygon([System.Drawing.SolidBrush]::new($cream), $house)
  $housePen = [System.Drawing.Pen]::new($copper, 5 * $scale)
  $housePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  $graphics.DrawLines($housePen, $house)
  $graphics.FillEllipse([System.Drawing.SolidBrush]::new($copper), 35 * $scale, 52 * $scale, 14 * $scale, 14 * $scale)
  $mountains = @(
    [System.Drawing.PointF]::new(30 * $scale, 76 * $scale),
    [System.Drawing.PointF]::new(47 * $scale, 63 * $scale),
    [System.Drawing.PointF]::new(57 * $scale, 70 * $scale),
    [System.Drawing.PointF]::new(67 * $scale, 60 * $scale),
    [System.Drawing.PointF]::new(74 * $scale, 67 * $scale),
    [System.Drawing.PointF]::new(74 * $scale, 80 * $scale),
    [System.Drawing.PointF]::new(26 * $scale, 80 * $scale)
  )
  $graphics.FillPolygon([System.Drawing.SolidBrush]::new($black), $mountains)
  $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $graphics.Dispose()
  $bitmap.Dispose()
}

$assets = Join-Path $PSScriptRoot '..\assets'
New-InhouseIcon (Join-Path $assets 'inhouse-photos-icon.png') $false
New-InhouseIcon (Join-Path $assets 'inhouse-photos-icon-foreground.png') $true
New-InhouseIcon (Join-Path $assets 'inhouse-photos-splash.png') $true 768
Copy-Item (Join-Path $assets 'inhouse-photos-icon.png') (Join-Path $assets 'immich-logo.png') -Force
