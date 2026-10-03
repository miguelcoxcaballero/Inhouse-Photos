[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version,
  [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit,
  [string]$BuildDirectory = (Join-Path $PSScriptRoot 'dist'),
  [string]$ReportPath = (Join-Path $PSScriptRoot 'dist\windows-release-verification.json'),
  [string]$ManifestPath = (Join-Path $PSScriptRoot '..\windows-server-update.json'),
  [string]$PreviousInstallerPath
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
foreach ($binary in @($manager, $installer)) {
  if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw "Built executable is missing: $binary" }
  $info = [Reflection.AssemblyName]::GetAssemblyName($binary)
  if ($info.Version.ToString() -ne "$Version.0") { throw "Unexpected assembly version: $($info.Version)" }
  if ($info.ProcessorArchitecture -ne [Reflection.ProcessorArchitecture]::Amd64) { throw 'Executable must target x64' }
  if ((Get-Item -LiteralPath $binary).Length -gt 20MB) { throw 'Executable exceeds the installed updater download limit' }
  $assembly = [Reflection.Assembly]::LoadFile($binary)
  foreach ($name in @('storage.ps1', 'server-runtime-update.ps1', 'server-runtime-queue-handoff.cjs')) {
    if ((Get-EmbeddedResourceHash $assembly "InhousePhotos.$name") -ne (Get-LowerSha256 (Join-Path $PSScriptRoot $name))) {
      throw "Embedded $name does not match the verified source"
    }
  }
}
$managerHash = Get-LowerSha256 $manager
$installerHash = Get-LowerSha256 $installer
$setupAssembly = [Reflection.Assembly]::LoadFile($installer)
if ((Get-EmbeddedResourceHash $setupAssembly 'InhousePhotos.payload.exe') -ne $managerHash) {
  throw 'Installer does not contain the exact built manager'
}
Invoke-CheckedExecutable $installer @('--verify-payload') | Out-Null
Invoke-CheckedExecutable $manager @('--self-test') | Out-Null
Invoke-CheckedExecutable $manager @('--verify-runtime-handoff') | Out-Null

$previousVersion = $null
if ($PreviousInstallerPath) {
  $PreviousInstallerPath = [IO.Path]::GetFullPath($PreviousInstallerPath)
  Invoke-CheckedExecutable $PreviousInstallerPath @('--verify-payload') | Out-Null
  Invoke-CheckedExecutable $PreviousInstallerPath @('--install-current') | Out-Null
  $previousVersion = Invoke-CheckedExecutable $PreviousInstallerPath @('--verify-installed')
  if (-not $previousVersion.StartsWith('1.2.16 ')) { throw 'The bootstrap fixture did not install manager 1.2.16' }
}
Invoke-CheckedExecutable $installer @('--install-current') | Out-Null
$installed = Invoke-CheckedExecutable $installer @('--verify-installed')
if ($installed -ne "$Version $managerHash") { throw 'Installed manager does not match the built payload' }
if ($PreviousInstallerPath) {
  # Use the actual stable launcher location rather than relying on a duplicated path.
  $backend = $setupAssembly.GetType('InhousePhotos.Backend')
  $launcher = $backend.GetProperty('Launcher').GetValue($null, $null)
  if ((Get-LowerSha256 $launcher) -ne (Get-LowerSha256 $PreviousInstallerPath)) {
    throw 'The existing stable launcher was unexpectedly replaced'
  }
  if ((Invoke-CheckedExecutable $launcher @('--verify-installed')) -ne "$Version $managerHash") {
    throw 'The 1.2.16 launcher cannot resolve the verified 1.2.17 installation'
  }
}

$notes = 'Permite actualizar desde el m\u00f3vil el motor del servidor y muestra su versi\u00f3n y progreso. Descarga y verifica el paquete publicado y conserva la biblioteca y la base de datos.'
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
$report = [ordered]@{
  version = $Version
  sourceCommit = $SourceCommit
  verifiedAt = [DateTime]::UtcNow.ToString('o')
  installerSha256 = $installerHash
  managerSha256 = $managerHash
  embeddedRuntimeHelpersMatchSource = $true
  managerSelfTest = $true
  runtimeHelperProcessVerified = $true
  installerPayloadVerified = $true
  installationVerified = $true
  bootstrapFromManager1216Verified = [bool]$PreviousInstallerPath
  authenticodeSigned = $false
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath), ($report | ConvertTo-Json).Replace("`r`n", "`n") + "`n", $utf8)
[IO.File]::AppendAllText((Join-Path $BuildDirectory 'SHA256SUMS.txt'), "$(Get-LowerSha256 $ReportPath)  windows-release-verification.json`n", $utf8)
Write-Output ($report | ConvertTo-Json)
