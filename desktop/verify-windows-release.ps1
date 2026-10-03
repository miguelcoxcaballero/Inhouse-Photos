[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version,
  [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit,
  [string]$BuildDirectory = (Join-Path $PSScriptRoot 'dist'),
  [string]$ReportPath = (Join-Path $PSScriptRoot 'dist\windows-release-verification.json'),
  [string]$ManifestPath = (Join-Path $PSScriptRoot '..\windows-server-update.json'),
  [string]$PreviousInstallerPath,
  [string]$BootstrapInstallerPath,
  [string]$PreviousProductInstallerPath
)
$ErrorActionPreference = 'Stop'

function Get-LowerSha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-CheckedExecutable([string]$Path, [string[]]$Arguments, [int]$TimeoutSeconds = 60) {
  $start = New-Object Diagnostics.ProcessStartInfo
  $start.FileName = $Path
  $start.Arguments = $Arguments -join ' '
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $process = New-Object Diagnostics.Process
  $process.StartInfo = $start
  try {
    if (-not $process.Start()) { throw "Could not start verification: $Path" }
    $output = $process.StandardOutput.ReadToEndAsync()
    $errors = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      try { $process.Kill() } catch {}
      throw "Verification timed out: $Path $($Arguments -join ' ')"
    }
    $text = $output.GetAwaiter().GetResult()
    $details = $errors.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
      throw "Verification exited $($process.ExitCode): $Path $($Arguments -join ' '): $details $text"
    }
    return $text.Trim()
  } finally { $process.Dispose() }
}

function Get-EmbeddedResourceHash([Reflection.Assembly]$Assembly, [string]$Name) {
  $stream = $Assembly.GetManifestResourceStream($Name)
  if ($null -eq $stream) { throw "Required embedded resource is missing: $Name" }
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose(); $stream.Dispose() }
}

if ($env:OS -ne 'Windows_NT') { throw 'Windows release verification requires Windows' }
$BuildDirectory = [IO.Path]::GetFullPath($BuildDirectory)
$manager = Join-Path $BuildDirectory 'Inhouse-Photos-Server.exe'
$installer = Join-Path $BuildDirectory 'Inhouse-Photos-Server-Setup.exe'
$publicDownloads = Join-Path $BuildDirectory 'public-downloads.zip'
if (-not (Test-Path -LiteralPath $publicDownloads -PathType Leaf)) { throw 'Built public download archive is missing' }
$publicDownloadsHash = Get-LowerSha256 $publicDownloads
foreach ($binary in @($manager, $installer)) {
  if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw "Built executable is missing: $binary" }
  $info = [Reflection.AssemblyName]::GetAssemblyName($binary)
  if ($info.Version.ToString() -ne "$Version.0") { throw "Unexpected assembly version: $($info.Version)" }
  if ($info.ProcessorArchitecture -ne [Reflection.ProcessorArchitecture]::Amd64) { throw 'Executable must target x64' }
  if ((Get-Item -LiteralPath $binary).Length -gt 20MB) { throw 'Executable exceeds the installed updater download limit' }
  $assembly = [Reflection.Assembly]::LoadFile($binary)
  $backendVersion = $assembly.GetType('InhousePhotos.Backend').GetField('Version').GetRawConstantValue()
  $runtimeVersion = $assembly.GetType('InhousePhotos.RuntimeUpdates').GetField('LatestVersion').GetRawConstantValue()
  if ($backendVersion -ne $Version -or $runtimeVersion -ne $Version) {
    throw 'The Windows program and pinned server must use the same public product version'
  }
  foreach ($name in @('storage.ps1', 'server-runtime-update.ps1', 'server-runtime-queue-handoff.cjs')) {
    if ((Get-EmbeddedResourceHash $assembly "InhousePhotos.$name") -ne (Get-LowerSha256 (Join-Path $PSScriptRoot $name))) {
      throw "Embedded $name does not match the verified source"
    }
  }
  if ((Get-EmbeddedResourceHash $assembly 'InhousePhotos.public-downloads.zip') -ne $publicDownloadsHash) {
    throw 'Embedded public downloads do not match the verified build archive'
  }
}
$managerHash = Get-LowerSha256 $manager
$installerHash = Get-LowerSha256 $installer
$setupAssembly = [Reflection.Assembly]::LoadFile($installer)
$runtimeType = $setupAssembly.GetType('InhousePhotos.RuntimeUpdates')
$runtimePins = [ordered]@{}
foreach ($field in @('LatestVersion', 'LatestImage', 'LatestImageId', 'SourceCommit', 'SchemaSha256', 'ArchiveSha256', 'ManifestSha256', 'PackageSha256', 'PackageUrl')) {
  $runtimePins[$field] = $runtimeType.GetField($field).GetRawConstantValue()
}
if ($runtimePins.LatestImage -ne "inhouse-photos-server:v$Version" -or
    -not [Regex]::IsMatch($runtimePins.PackageUrl,
      '^https://github\.com/miguelcoxcaballero/Inhouse-Photos/releases/download/server-runtime-v' +
      [Regex]::Escape($Version) + '(?:-r[1-9][0-9]*)?/Inhouse-Photos-Server-Runtime-' + [Regex]::Escape($Version) + '\.zip$')) {
  throw 'The installer must pin the verified runtime release for this product version'
}
$serverVersion = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\server\package.json') -Raw | ConvertFrom-Json).version
if ($serverVersion -ne $Version) { throw 'Server package version does not match the unified Windows release' }
if ((Get-EmbeddedResourceHash $setupAssembly 'InhousePhotos.payload.exe') -ne $managerHash) {
  throw 'Installer does not contain the exact built manager'
}
Invoke-CheckedExecutable $installer @('--verify-payload') | Out-Null
Invoke-CheckedExecutable $manager @('--self-test') | Out-Null
Invoke-CheckedExecutable $manager @('--verify-runtime-handoff') | Out-Null
Invoke-CheckedExecutable $manager @('--verify-system-update-intent') | Out-Null

# Use the installer's actual stable launcher location. Fixtures are installed
# only on a fresh Windows CI profile, never over an existing user's launcher.
$launcher = $setupAssembly.GetType('InhousePhotos.Backend').GetProperty('Launcher').GetValue($null, $null)
$fixtures = @()
if ($BootstrapInstallerPath) { $fixtures += @{ path = $BootstrapInstallerPath; version = '1.2.16'; sha256 = '9378c9b3cc1366699011b29d5a06c32451a417b6fd0ba2574981c329844be65d' } }
if ($PreviousInstallerPath) { $fixtures += @{ path = $PreviousInstallerPath; version = '1.2.17'; sha256 = 'd6eb4b2ce1331f32688f48ab87f649285a84fbe6996b6e8e1c96cb3af12e5981' } }
if ($PreviousProductInstallerPath) { $fixtures += @{ path = $PreviousProductInstallerPath; version = '3.1.96'; sha256 = '1857acdac75128fc79ab0b2628b704700beaf8dd8117936ba04ace90d8e2b016' } }
$verifiedPreviousVersions = @()
if ($fixtures.Count -gt 0 -and (Test-Path -LiteralPath $launcher)) {
  throw 'Legacy upgrade verification requires a fresh isolated Windows profile'
}
for ($index = 0; $index -lt $fixtures.Count; $index++) {
  $fixture = $fixtures[$index]
  $fixturePath = [IO.Path]::GetFullPath($fixture.path)
  if ([Reflection.AssemblyName]::GetAssemblyName($fixturePath).Version.ToString(3) -ne $fixture.version) {
    throw "Unexpected legacy fixture version: $($fixture.version)"
  }
  $fixtureHash = Get-LowerSha256 $fixturePath
  if ($fixtureHash -ne $fixture.sha256) { throw "Fixture $($fixture.version) does not match the immutable public installer" }
  Invoke-CheckedExecutable $fixturePath @('--verify-payload') | Out-Null
  Invoke-CheckedExecutable $fixturePath @('--install-current') | Out-Null
  if (-not (Invoke-CheckedExecutable $fixturePath @('--verify-installed')).StartsWith("$($fixture.version) ")) {
    throw "The fixture did not install manager $($fixture.version)"
  }
  Invoke-CheckedExecutable $installer @('--install-current') | Out-Null
  if ((Invoke-CheckedExecutable $installer @('--verify-installed')) -ne "$Version $managerHash") {
    throw "Upgrade from $($fixture.version) did not install the exact built payload"
  }
  if ((Get-LowerSha256 $launcher) -ne $fixtureHash) { throw 'The existing stable launcher was unexpectedly replaced' }
  if ((Invoke-CheckedExecutable $launcher @('--verify-installed')) -ne "$Version $managerHash") {
    throw "The $($fixture.version) launcher cannot resolve the verified $Version installation"
  }
  $verifiedPreviousVersions += $fixture.version
  if ($index -lt $fixtures.Count - 1) {
    # Remove only the exact launcher created by this fixture. Preserve all
    # version slots, configuration and library files for the next upgrade.
    if ((Get-LowerSha256 $launcher) -ne $fixtureHash) { throw 'Refusing to remove an unrecognized launcher' }
    Remove-Item -LiteralPath $launcher
  }
}
if ($fixtures.Count -eq 0) {
  Invoke-CheckedExecutable $installer @('--install-current') | Out-Null
  if ((Invoke-CheckedExecutable $installer @('--verify-installed')) -ne "$Version $managerHash") {
    throw 'Installed manager does not match the built payload'
  }
}

$notes = 'Corrige bloqueos al instalar, muestra la etapa que ejecuta el PC y permite reintentar de forma segura. Actualiza tambi\u00e9n las descargas de tu web. Conserva tus fotos, la base de datos y el trabajo pendiente.'
$notes = [Regex]::Unescape($notes)
$manifest = [ordered]@{
  Version = $Version
  InstallerUrl = "https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/server-v$Version/Inhouse-Photos-Server-Setup.exe"
  Sha256 = $installerHash
  Notes = $notes
}
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ManifestPath), ($manifest | ConvertTo-Json).Replace("`r`n", "`n") + "`n", $utf8)
$hashLines = @(
  "$installerHash  Inhouse-Photos-Server-Setup.exe",
  "$managerHash  Inhouse-Photos-Server.exe",
  "$(Get-LowerSha256 $ManifestPath)  windows-server-update.json"
)
[IO.File]::WriteAllText((Join-Path $BuildDirectory 'SHA256SUMS.txt'), ($hashLines -join "`n") + "`n", $utf8)
$sourceHashes = [ordered]@{}
$sourceFiles = @((Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.cs' -File).FullName)
$sourceFiles += @('build.ps1', 'brand.xaml', 'storage.ps1', 'server-runtime-update.ps1', 'server-runtime-queue-handoff.cjs', 'package-public-downloads.ps1') | ForEach-Object { Join-Path $PSScriptRoot $_ }
foreach ($source in ($sourceFiles | Sort-Object)) { $sourceHashes[[IO.Path]::GetFileName($source)] = Get-LowerSha256 $source }
$report = [ordered]@{
  version = $Version
  sourceCommit = $SourceCommit
  verifiedAt = [DateTime]::UtcNow.ToString('o')
  installerSha256 = $installerHash
  managerSha256 = $managerHash
  assemblyVersion = "$Version.0"
  serverPackageVersion = $serverVersion
  serverPackageSha256 = Get-LowerSha256 (Join-Path $PSScriptRoot '..\server\package.json')
  runtimePins = $runtimePins
  sourceSha256 = $sourceHashes
  embeddedRuntimeHelpersMatchSource = $true
  publicDownloadsZipSha256 = $publicDownloadsHash
  embeddedPublicDownloadsMatchArchive = $true
  managerSelfTest = $true
  runtimeHelperProcessVerified = $true
  systemUpdateIntentVerified = $true
  installerPayloadVerified = $true
  installationVerified = $true
  bootstrapFromManager1216Verified = $verifiedPreviousVersions -contains '1.2.16'
  upgradeFromManager1217Verified = $verifiedPreviousVersions -contains '1.2.17'
  verifiedFromManager3196 = $verifiedPreviousVersions -contains '3.1.96'
  verifiedPreviousManagerVersions = @($verifiedPreviousVersions)
  authenticodeSigned = $false
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath), ($report | ConvertTo-Json -Depth 5).Replace("`r`n", "`n") + "`n", $utf8)
[IO.File]::AppendAllText((Join-Path $BuildDirectory 'SHA256SUMS.txt'), "$(Get-LowerSha256 $ReportPath)  windows-release-verification.json`n", $utf8)
Write-Output ($report | ConvertTo-Json -Depth 5)
