#Requires -Version 5.1
param([string]$OutFile=(Join-Path $PSScriptRoot 'dist/public-downloads.zip'))
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$portalRoot=Join-Path $repositoryRoot 'portal'
$windows=Get-Content -LiteralPath (Join-Path $repositoryRoot 'windows-server-update.json') -Raw|ConvertFrom-Json
$android=Get-Content -LiteralPath (Join-Path $repositoryRoot 'android-update.json') -Raw|ConvertFrom-Json
$releaseRoot='https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/'
$versionPattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if($windows.Version -notmatch $versionPattern -or $windows.Sha256 -cnotmatch '^[a-f0-9]{64}$' -or
   $windows.InstallerUrl -cne ($releaseRoot+'server-v'+$windows.Version+'/Inhouse-Photos-Server-Setup.exe')) {
  throw 'Windows public download manifest is not valid.'
}
$hasFullInstaller=$null -ne $windows.FullInstallerUrl -or $null -ne $windows.FullInstallerSha256
if($hasFullInstaller -and ($windows.FullInstallerUrl -cne ($releaseRoot+'server-v'+$windows.Version+'/Inhouse-Photos-Server-Full-Setup.exe') -or
   $windows.FullInstallerSha256 -cnotmatch '\A[a-f0-9]{64}\z')) {
  throw 'Full Windows installer metadata must contain the verified URL and SHA-256 together.'
}
$windowsDownloadUrl=if($hasFullInstaller){$windows.FullInstallerUrl}else{$windows.InstallerUrl}
$androidUrlPattern='^'+[Regex]::Escape($releaseRoot+'v'+$android.version)+'(?:-[A-Za-z0-9._-]+)?/Inhouse-Photos\.apk$'
if($android.version -notmatch $versionPattern -or $android.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
   $android.apkUrl -cnotmatch $androidUrlPattern) {throw 'Android public download manifest is not valid.'}
$catalogue=[ordered]@{
  windows=[ordered]@{Version=$windows.Version;InstallerUrl=$windows.InstallerUrl;Sha256=$windows.Sha256}
  android=[ordered]@{version=$android.version;apkUrl=$android.apkUrl;sha256=$android.sha256}
}
if($hasFullInstaller) {
  $catalogue.windows.FullInstallerUrl=$windows.FullInstallerUrl
  $catalogue.windows.FullInstallerSha256=$windows.FullInstallerSha256
}
$catalogueText='window.InhousePhotosDownloads.applyLatest('+($catalogue|ConvertTo-Json -Depth 4 -Compress)+");`n"
$files=@('index.html','style.css','mark.svg','downloads.js','download-catalogue.js','privacidad/index.html','servidor/index.html','servidor/usb.css','servidor/usb.js')
$utf8=New-Object Text.UTF8Encoding($false)
function Update-DownloadHtml([string]$Html,[bool]$Landing) {
  foreach($platform in @('windows','android')) {
    if(-not $Landing -and $platform -eq 'android'){continue}
    if($platform -eq 'windows'){$downloadUrl=$windowsDownloadUrl;$version=$windows.Version;$label='Windows 10 y 11 · Versión '}
    else{$downloadUrl=$android.apkUrl;$version=$android.version;$label='Android 8 o posterior · ARM64 · Versión '}
    $pattern='(<a\b[^>]*\bdata-download="'+$platform+'"[^>]*\bhref=")[^"]*(")'
    if([Regex]::Matches($Html,$pattern).Count -ne 1){throw "Missing unique $platform download link."}
    $Html=[Regex]::Replace($Html,$pattern,[Text.RegularExpressions.MatchEvaluator]{param($match)$match.Groups[1].Value+$downloadUrl+$match.Groups[2].Value})
    $pattern='(<a\b[^>]*\bdata-download="'+$platform+'"[^>]*\bdata-version=")[^"]*(")'
    $Html=[Regex]::Replace($Html,$pattern,[Text.RegularExpressions.MatchEvaluator]{param($match)$match.Groups[1].Value+$version+$match.Groups[2].Value})
    if(-not $Landing){continue}
    $pattern='(<small\b[^>]*\bdata-download-version="'+$platform+'"[^>]*>)[^<]*(</small>)'
    $suffix=if($platform -eq 'windows' -and $hasFullInstaller){' · Instalación completa'}else{''}
    $Html=[Regex]::Replace($Html,$pattern,[Text.RegularExpressions.MatchEvaluator]{param($match)$match.Groups[1].Value+$label+$version+$suffix+$match.Groups[2].Value})
    $checksums=$downloadUrl.Substring(0,$downloadUrl.LastIndexOf('/')+1)+'SHA256SUMS.txt'
    $pattern='(<a\b[^>]*\bdata-download-checksum="'+$platform+'"[^>]*\bhref=")[^"]*(")'
    $Html=[Regex]::Replace($Html,$pattern,[Text.RegularExpressions.MatchEvaluator]{param($match)$match.Groups[1].Value+$checksums+$match.Groups[2].Value})
  }
  return $Html
}
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$OutFile=[IO.Path]::GetFullPath($OutFile)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutFile))|Out-Null
$temporary=$OutFile+'.'+[Guid]::NewGuid().ToString('N')+'.new'
try {
  $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew)
  $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
  try {
    foreach($name in $files) {
      if($name -eq 'download-catalogue.js'){$bytes=$utf8.GetBytes($catalogueText)}
      else {
        $source=Join-Path $portalRoot $name
        if(-not [IO.File]::Exists($source) -or ((Get-Item -LiteralPath $source).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Missing regular public resource: $name"}
        $bytes=[IO.File]::ReadAllBytes($source)
        if($name -eq 'index.html' -or $name -eq 'servidor/index.html') {
          $bytes=$utf8.GetBytes((Update-DownloadHtml ($utf8.GetString($bytes)) ($name -eq 'index.html')))
        }
      }
      if($bytes.Length -eq 0 -or $bytes.Length -gt 131072){throw "Public resource size is not valid: $name"}
      $entry=$zip.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal)
      $entry.LastWriteTime=[DateTimeOffset]::new(2026,1,1,0,0,0,[TimeSpan]::Zero)
      $output=$entry.Open()
      try{$output.Write($bytes,0,$bytes.Length)}finally{$output.Dispose()}
    }
  }finally{$zip.Dispose();$stream.Dispose()}
  if([IO.File]::Exists($OutFile)){[IO.File]::Delete($OutFile)}
  [IO.File]::Move($temporary,$OutFile)
}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
Write-Output $OutFile
