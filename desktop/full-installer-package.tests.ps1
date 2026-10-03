#Requires -Version 7.4
param(
  [string]$ManagerExecutable=(Join-Path $PSScriptRoot 'dist\Inhouse-Photos-Server.exe'),
  [string]$FullInstaller,
  [string]$CompactInstaller
)
# Load the actual compiled implementation. All fixtures live in a fresh temp
# directory. No installed manager, runtime cache, settings or Docker is touched.
$ErrorActionPreference='Stop'
$manager=[IO.Path]::GetFullPath($ManagerExecutable)
if(-not [IO.File]::Exists($manager)){throw 'Build the manager before running package checks.'}
$assembly=[Reflection.Assembly]::LoadFile($manager)
$packageType=$assembly.GetType('InhousePhotos.FullInstallerPackage',$true)
$verify=$packageType.GetMethod('Verify',[Reflection.BindingFlags]'Public,Static')
$copy=$packageType.GetMethod('CopyLauncher',[Reflection.BindingFlags]'Public,Static')
$offset=$packageType.GetMethod('PayloadOffset',[Reflection.BindingFlags]'NonPublic,Static')
$directory=Join-Path ([IO.Path]::GetTempPath()) ('inhouse-full-package-tests-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory)|Out-Null
$script:checks=0
function Check([bool]$Condition,[string]$Name) {
  if(-not $Condition){throw $Name}
  $script:checks++
}
function Invoke-Verify([string]$Path) {
  try{$verify.Invoke($null,[object[]]@([string]$Path))|Out-Null}
  catch [Reflection.TargetInvocationException]{throw $_.Exception.InnerException}
}
function Reject([scriptblock]$Action,[string]$Name) {
  $rejected=$false
  try{& $Action}catch [IO.IOException]{$rejected=$true}
  Check $rejected $Name
}
function Package([string]$Name,[long]$CompactLength,[long]$PackageLength,[string]$Marker='INHOUSE_FULL_V1!',[int]$TrailingBytes=0) {
  $path=Join-Path $directory $Name
  $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew)
  $writer=New-Object IO.BinaryWriter($stream,[Text.Encoding]::ASCII,$true)
  try {
    # Only 64 KiB of zeroes plus four dummy runtime bytes are materialised.
    # Oversize/negative tests change footer claims, never allocate huge files.
    $writer.Write([byte[]]::new(65536))
    $writer.Write([byte[]]@(1,2,3,4))
    $writer.Write([Text.Encoding]::ASCII.GetBytes($Marker))
    $writer.Write($CompactLength);$writer.Write($PackageLength)
    if($TrailingBytes -gt 0){$writer.Write([byte[]]::new($TrailingBytes))}
    $writer.Flush();$stream.Flush($true)
  }finally{$writer.Dispose();$stream.Dispose()}
  return $path
}
try {
  $tiny=Join-Path $directory 'tiny.exe';[IO.File]::WriteAllBytes($tiny,[byte[]]@(1,2,3))
  Reject {Invoke-Verify $tiny} 'truncated footer is not accepted as a complete installer'
  $badMarker=Package 'bad-marker.exe' 65536 4 'NOT_INHOUSE_V1!!'
  Reject {Invoke-Verify $badMarker} 'unrecognised footer cannot pass full-package verification'
  $validLayout=Package 'valid-layout.exe' 65536 4
  $arguments=[object[]]@([string]$validLayout,[long]0)
  $found=$offset.Invoke($null,$arguments)
  Check ($found -eq 65536 -and $arguments[1] -eq 4) 'the actual parser reads 16-byte magic and two Int64 lengths at the correct offset'
  Reject {Invoke-Verify $validLayout} 'a structurally complete installer still rejects a wrong pinned runtime SHA-256'
  foreach($case in @(
    @{Name='compact-too-short.exe';Prefix=[long]65535;Package=[long]4},
    @{Name='compact-too-large.exe';Prefix=[long](20MB+1);Package=[long]4},
    @{Name='compact-negative.exe';Prefix=[long]-1;Package=[long]4},
    @{Name='package-empty.exe';Prefix=[long]65536;Package=[long]0},
    @{Name='package-negative.exe';Prefix=[long]65536;Package=[long]-1},
    @{Name='package-too-large.exe';Prefix=[long]65536;Package=[long](2GB+1)},
    @{Name='truncated-payload.exe';Prefix=[long]65536;Package=[long]5},
    @{Name='wrong-prefix-size.exe';Prefix=[long]65537;Package=[long]4}
  )) {
    $invalid=Package $case.Name $case.Prefix $case.Package
    Reject {Invoke-Verify $invalid} ('reject malformed footer '+$case.Name)
  }
  $extra=Package 'trailing-garbage.exe' 65536 4 'INHOUSE_FULL_V1!' 1
  Reject {Invoke-Verify $extra} 'unexpected bytes after the footer cannot pass complete-package verification'
  $launcher=Join-Path $directory 'launcher.exe'
  $copy.Invoke($null,[object[]]@([string]$validLayout,[string]$launcher))|Out-Null
  Check ((Get-Item -LiteralPath $launcher).Length -eq 65536) 'launcher copies only the compact PE prefix, not the large runtime ZIP'
  Check (([IO.File]::ReadAllBytes($launcher)|Where-Object{$_ -ne 0}|Measure-Object).Count -eq 0) 'launcher prefix is byte-exact'
  Reject {
    try{$copy.Invoke($null,[object[]]@([string]$validLayout,[string]$launcher))|Out-Null}
    catch [Reflection.TargetInvocationException]{throw $_.Exception.InnerException}
  } 'copying a launcher never overwrites an existing executable'
  $smallLauncher=Join-Path $directory 'small-launcher.exe'
  $copy.Invoke($null,[object[]]@([string]$tiny,[string]$smallLauncher))|Out-Null
  Check ((Get-FileHash -LiteralPath $smallLauncher).Hash -eq (Get-FileHash -LiteralPath $tiny).Hash) 'compact installer fallback is copied unchanged'

  # The production lease is a FileStream, not a thread-affine Mutex. This
  # fixture exercises its real OS exclusivity and release on another thread
  # without invoking the installer or using its real settings directory.
  $leasePath=Join-Path $directory 'product-install.lock'
  $lease=[IO.FileStream]::new($leasePath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  try {
    Reject {
      $duplicate=[IO.FileStream]::new($leasePath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
      $duplicate.Dispose()
    } 'a duplicate product installation cannot acquire the same file lease'
    Add-Type -TypeDefinition @'
using System;using System.IO;using System.Threading;using System.Threading.Tasks;
public static class InhouseInstallerLeaseFixture {
 public static Task<int> DisposeOnWorker(FileStream lease) {
  return Task.Run(()=>{lease.Dispose();return Thread.CurrentThread.ManagedThreadId;});
 }
}
'@
    $caller=[Threading.Thread]::CurrentThread.ManagedThreadId
    $worker=[InhouseInstallerLeaseFixture]::DisposeOnWorker($lease).GetAwaiter().GetResult()
    Check ($worker -ne $caller) 'installer file lease safely releases across a CLI await continuation thread'
  }finally{$lease.Dispose()}
  $retry=[IO.FileStream]::new($leasePath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  $retry.Dispose();Check $true 'a retry acquires the released installer lease without a stale busy state'

  if($FullInstaller) {
    $full=[IO.Path]::GetFullPath($FullInstaller)
    Invoke-Verify $full;Check $true 'actual full EXE contains the exact SHA-256-pinned runtime'
    $actualArgs=[object[]]@([string]$full,[long]0);$actualPrefix=$offset.Invoke($null,$actualArgs)
    $actualLauncher=Join-Path $directory 'actual-launcher.exe'
    $copy.Invoke($null,[object[]]@([string]$full,[string]$actualLauncher))|Out-Null
    Check ((Get-Item -LiteralPath $actualLauncher).Length -eq $actualPrefix) 'actual full installer produces a small launcher, not an 800 MB copy'
    if($CompactInstaller) {
      Check ((Get-FileHash -LiteralPath $actualLauncher).Hash -eq (Get-FileHash -LiteralPath ([IO.Path]::GetFullPath($CompactInstaller))).Hash) 'actual launcher is identical to the published compact installer prefix'
    }
  }
  Write-Output "$script:checks full-installer package and isolated file-lease checks passed."
}finally {
  # Resolve the exact unique fixture target before recursive cleanup.
  $resolved=[IO.Path]::GetFullPath($directory)
  $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
  if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($resolved) -notmatch '^inhouse-full-package-tests-[a-f0-9]{32}$') {
    throw 'Refusing cleanup outside the isolated full-package test directory.'
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
