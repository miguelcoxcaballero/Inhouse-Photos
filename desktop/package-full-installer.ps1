#Requires -Version 5.1
param(
  [Parameter(Mandatory=$true)][string]$RuntimePackage,
  [string]$CompactInstaller,
  [string]$OutFile
)
$ErrorActionPreference='Stop'
if(-not $CompactInstaller){$CompactInstaller=Join-Path $PSScriptRoot 'dist\Inhouse-Photos-Server-Setup.exe'}
if(-not $OutFile){$OutFile=Join-Path $PSScriptRoot 'dist\Inhouse-Photos-Server-Full-Setup.exe'}
$compact=[IO.Path]::GetFullPath($CompactInstaller)
$runtime=[IO.Path]::GetFullPath($RuntimePackage)
$target=[IO.Path]::GetFullPath($OutFile)
if($target -eq $compact -or $target -eq $runtime){throw 'The full installer cannot replace its inputs.'}
foreach($file in @($compact,$runtime)) {
  if(-not [IO.File]::Exists($file) -or ((Get-Item -LiteralPath $file).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'A regular local package is required.'}
}
$assembly=[Reflection.Assembly]::LoadFile($compact)
$expected=$assembly.GetType('InhousePhotos.RuntimeUpdates').GetField('PackageSha256').GetRawConstantValue()
if((Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected){throw 'Runtime ZIP does not match the installer pin.'}
$prefix=(Get-Item -LiteralPath $compact).Length
$package=(Get-Item -LiteralPath $runtime).Length
if($prefix -gt 20MB -or $prefix -lt 65536 -or $package -gt 2GB){throw 'Installer payload size is invalid.'}
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))|Out-Null
$partial=$target+'.'+[Guid]::NewGuid().ToString('N')+'.new'
try {
  $output=[IO.File]::Open($partial,[IO.FileMode]::CreateNew)
  try {
    foreach($file in @($compact,$runtime)) {
      $input=[IO.File]::OpenRead($file)
      try{$input.CopyTo($output,1048576)}finally{$input.Dispose()}
    }
    $writer=New-Object IO.BinaryWriter($output,[Text.Encoding]::ASCII,$true)
    try{$writer.Write([Text.Encoding]::ASCII.GetBytes('INHOUSE_FULL_V1!'));$writer.Write([long]$prefix);$writer.Write([long]$package);$writer.Flush()}
    finally{$writer.Dispose()}
    $output.Flush($true)
  }finally{$output.Dispose()}
  if([IO.File]::Exists($target)){[IO.File]::Replace($partial,$target,[NullString]::Value)}else{[IO.File]::Move($partial,$target)}
}finally{if([IO.File]::Exists($partial)){[IO.File]::Delete($partial)}}
$start=New-Object Diagnostics.ProcessStartInfo($target,'--verify-full-package')
$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle='Hidden'
$child=[Diagnostics.Process]::Start($start)
try{if(-not $child.WaitForExit(90000)){throw 'Full installer verification timed out.'};if($child.ExitCode -ne 0){throw 'Full installer payload verification failed.'}}
finally{$child.Dispose()}
Get-Item -LiteralPath $target|Select-Object Name,Length
Get-FileHash -LiteralPath $target -Algorithm SHA256
