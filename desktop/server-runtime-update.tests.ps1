#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'server-runtime-update.ps1') -FunctionsOnly -ManifestPath unused -ManifestSha256 ('a' * 64) -ArchivePath unused -SettingsDirectory $PSScriptRoot

$script:passed = 0
function Check([bool]$Value, [string]$Description) {
  if (-not $Value) { throw ('FAIL: ' + $Description) }
  $script:passed++
}
function Reject([scriptblock]$Action, [string]$Description) {
  try { & $Action; throw ('DID NOT REJECT: ' + $Description) }
  catch { if ($_.Exception.Message.StartsWith('DID NOT REJECT:')) { throw }; $script:passed++ }
}
function Clone($Value) { return $Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json }

Check ((Quote-RuntimeArgument '') -ceq '""') 'native argv quotes empty arguments'
Check ((Quote-RuntimeArgument 'simple') -ceq '"simple"') 'native argv quotes ordinary arguments'
Check ((Quote-RuntimeArgument 'C:\folder name\') -ceq '"C:\folder name\\"') 'native argv doubles the trailing slash before its closing quote'
Check ((Quote-RuntimeArgument 'a"b') -ceq '"a\"b"') 'native argv escapes embedded quotes'
Check ((Quote-RuntimeArgument 'a\"b') -ceq '"a\\\"b"') 'native argv preserves the slash before an embedded quote'
Check ((Get-RuntimeNativeReason 'private-user:private-token no space left on device') -ceq 'disk_space') 'native disk diagnosis never returns private stderr'
Check ((Get-RuntimeNativeReason 'error during connect to private-server') -ceq 'daemon_unavailable') 'native daemon diagnosis uses an allowlisted code'
Check ((Get-RuntimeNativeReason 'unexpected EOF secret-value') -ceq 'archive_invalid') 'native archive diagnosis hides raw archive error text'
Check ((Get-RuntimeNativeReason 'unrecognized private-user:private-token') -ceq 'native_failure') 'unknown diagnostics fail closed without leaking private text'
$savedCancellationPath = $script:CancellationPath
try {
  $script:CancellationPath = Join-Path ([IO.Path]::GetTempPath()) ('cancel-' + [Guid]::NewGuid().ToString('N') + '.signal')
  Reject { Assert-RuntimeCancellationPath } 'cancellation signal cannot use a path outside the verified helper directory'
  $script:CancellationPath = Join-Path $PSScriptRoot 'cancel-invalid.signal'
  Reject { Assert-RuntimeCancellationPath } 'cancellation signal must use a unique manager operation identity'
  $script:CancellationPath = Join-Path $PSScriptRoot ('cancel-' + [Guid]::NewGuid().ToString('N') + '.signal')
  Assert-RuntimeCancellationPath
  Check $true 'unique cancellation signal is accepted beside the verified helper'
} finally { $script:CancellationPath = $savedCancellationPath }

$compose = "services:`r`n  immich-server:`r`n    image: 'previous:tag' # current`r`n    env_file: .env`r`n    volumes:`r`n      - ./library:/data`r`n  database:`r`n    image: postgres`r`n    volumes:`r`n      - pgdata:/var/lib/postgresql/data`r`nvolumes:`r`n  pgdata:`r`n"
$changed = Set-ServerImage $compose 'inhouse-photos-server:release'
$expected = $compose.Replace("    image: 'previous:tag' # current", '    image: inhouse-photos-server:release')
Check ($changed -ceq $expected) 'replace only server image line, retain CRLF/mounts/database/config'
Reject { Set-ServerImage ($compose + "  immich-server:`r`n    image: second`r`n") 'inhouse-photos-server:release' } 'duplicate target service'
Reject { Set-ServerImage ($compose.Replace("    image: 'previous:tag' # current", '    <<: *common')) 'inhouse-photos-server:release' } 'implicit image alias'
Reject { Set-ServerImage ($compose.Replace("    env_file: .env", "    image: duplicate`r`n    env_file: .env")) 'inhouse-photos-server:release' } 'duplicate target image'
Reject { Set-ServerImage ($compose.Replace('  immich-server:', '  immich-server: {image: wrong}')) 'inhouse-photos-server:release' } 'inline YAML'

$manifest = [pscustomobject]@{format=1;version='3.1.0-storage-saver-20261002';sourceCommit=('a' * 40);
  image='inhouse-photos-server:release';imageId=('sha256:' + 'b' * 64);archiveFile='server.tar.gz';
  archiveSha256=('c' * 64);platform='linux/amd64';compatibleServerImageIds=@('sha256:' + 'd' * 64);
  databaseMigrations='unchanged';databaseSchemaSha256=('e' * 64)}
Assert-Manifest $manifest; Check $true 'valid immutable manifest'
$publicVersion = Clone $manifest; $publicVersion.version='3.1.96'
Assert-Manifest $publicVersion; Check $true 'accept verified numeric public server version'
$dualIdentity = Clone $publicVersion
$dualIdentity | Add-Member imageConfigId ('sha256:' + 'f' * 64)
Assert-Manifest $dualIdentity; Check $true 'accept exactly published manifest and config identities across Docker stores'
$bad = Clone $dualIdentity; $bad.imageConfigId='any-image'; Reject { Assert-Manifest $bad } 'alternate identity requires immutable SHA-256'
$bad = Clone $dualIdentity; $bad.imageConfigId=$bad.imageId; Reject { Assert-Manifest $bad } 'alternate identity cannot be an ambiguous duplicate'
$bad = Clone $publicVersion; $bad.version='03.1.96'; Reject { Assert-Manifest $bad } 'reject ambiguous numeric public version'
$bad = Clone $publicVersion; $bad.version='3.1.96/other'; Reject { Assert-Manifest $bad } 'reject unsafe public version characters'
$bad = Clone $manifest; $bad.databaseMigrations='changed'; Reject { Assert-Manifest $bad } 'schema-changing update'
$bad = Clone $manifest; $bad.platform='linux/arm64'; Reject { Assert-Manifest $bad } 'incorrect platform'
$bad = Clone $manifest; $bad.compatibleServerImageIds=@(); Reject { Assert-Manifest $bad } 'unknown baseline'
$bad = Clone $manifest; $bad.image='postgres:latest'; Reject { Assert-Manifest $bad } 'unrelated image'
$bad = Clone $manifest; $bad.PSObject.Properties.Remove('archiveSha256'); Reject { Assert-Manifest $bad } 'missing archive integrity'
$additive = Clone $manifest
$additive.databaseMigrations = 'additive-upload-outbox'
$additive | Add-Member baselineDatabaseSchemaSha256 'e4da4ec029df53f7657b2a81776bb48806c419ecfb509c95e5e84e128dbd4824'
$additive | Add-Member addedDatabaseMigrations @('1790985600000-DurableUploadProcessing')
Assert-Manifest $additive; Check $true 'exact additive durable outbox migration accepted'
$bad = Clone $additive; $bad.baselineDatabaseSchemaSha256='f'*64; Reject { Assert-Manifest $bad } 'unknown source schema'
$bad = Clone $additive; $bad.addedDatabaseMigrations=@('1790985600000-DurableUploadProcessing', 'OtherMigration'); Reject { Assert-Manifest $bad } 'unexpected additional migrations'
$bad = Clone $additive; $bad.addedDatabaseMigrations=@('OtherMigration'); Reject { Assert-Manifest $bad } 'unverified migration'
$bad = Clone $additive; $bad.PSObject.Properties.Remove('baselineDatabaseSchemaSha256'); Reject { Assert-Manifest $bad } 'missing migration baseline'
Reject { Write-RuntimePhase 'arbitrary' } 'reject unknown remote progress phase'
$script:ManagerProcessId=1
try {
  Check ((Write-RuntimePhase 'waiting') -ceq 'INHOUSE_RUNTIME_PHASE:waiting') 'remote progress reports waiting without paths or credentials'
  $script:ManagerOperationKey=''
  Reject { Assert-NoManager } 'running-manager bypass needs a verified operation event'
} finally { $script:ManagerProcessId=0; $script:ManagerOperationKey='' }
$manager = [pscustomobject]@{Id=100;ProcessName='Inhouse-Photos-Server';SessionId=2;Path='C:\manager\Inhouse-Photos-Server.exe'}
$helper = [pscustomobject]@{ParentProcessId=100;SessionId=2}
$managerInfo = [pscustomobject]@{ProcessId=100;ParentProcessId=99}
$launcher = [pscustomobject]@{Id=99;ProcessName='Inhouse Photos';SessionId=2;Path='C:\launcher\Inhouse Photos.exe'}
Assert-ManagerProcessChain $helper $manager $managerInfo @($manager) $launcher.Path; Check $true 'manager-owned helper accepted'
Assert-ManagerProcessChain $helper $manager $managerInfo @($manager,$launcher) $launcher.Path; Check $true 'verified auto-start launcher parent accepted'
$other = Clone $launcher; $other.Id=98; Reject { Assert-ManagerProcessChain $helper $manager $managerInfo @($manager,$other) $launcher.Path } 'unrelated manager refused'
$other = Clone $launcher; $other.Path='C:\other\Inhouse Photos.exe'; Reject { Assert-ManagerProcessChain $helper $manager $managerInfo @($manager,$other) $launcher.Path } 'launcher path must match installed parent'
$badHelper = Clone $helper; $badHelper.ParentProcessId=98; Reject { Assert-ManagerProcessChain $badHelper $manager $managerInfo @($manager) $launcher.Path } 'helper must be direct manager child'
$badHelper = Clone $helper; $badHelper.SessionId=3; Reject { Assert-ManagerProcessChain $badHelper $manager $managerInfo @($manager) $launcher.Path } 'helper session must match manager'

$mount = [pscustomobject]@{Type='bind';Source='/library';Destination='/data';Mode='rw';RW=$true;Propagation='rprivate'}
$dbMount = [pscustomobject]@{Type='volume';Name='inhouse_pgdata';Source='/var/lib/docker/volumes/inhouse_pgdata/_data';Destination='/var/lib/postgresql/data';Driver='local';Mode='rw';RW=$true;Propagation=''}
$before = @(
  [pscustomobject]@{Id=('1'*64);Image=('sha256:'+'a'*64);Service='immich-server';Project='inhouse';Mounts=@($mount)},
  [pscustomobject]@{Id=('2'*64);Image=('sha256:'+'b'*64);Service='database';Project='inhouse';Mounts=@($dbMount)},
  [pscustomobject]@{Id=('3'*64);Image=('sha256:'+'c'*64);Service='redis';Project='inhouse';Mounts=@()})
Assert-Containers $before $before 'inhouse'; Check $true 'unmodified production identity'
Check (-not (Assert-RecoveryContainers $before $before 'inhouse')) 'existing server recovery preserves all identities'
$withoutServer = @($before | Where-Object { $_.Service -cne 'immich-server' })
Check (Assert-RecoveryContainers $before $withoutServer 'inhouse') 'interrupted recreation accepts only the missing photo server'
$badRemaining = Clone $withoutServer; $badRemaining[0].Id='5'*64
Reject { Assert-RecoveryContainers $before $badRemaining 'inhouse' } 'missing server cannot hide database recreation'
Reject { Assert-RecoveryContainers $before @($withoutServer[0]) 'inhouse' } 'missing additional service requires manual review'
$after = Clone $before; $after[0].Id='4'*64; $after[0].Image='sha256:'+'d'*64
Assert-Containers $before $after 'inhouse' -ServerMayChange; Check $true 'only server recreation accepted'
Reject { Assert-Containers $before $after 'inhouse' } 'unexpected server recreation before apply'
$after = Clone $before; $after[1].Image='sha256:'+'e'*64; Reject { Assert-Containers $before $after 'inhouse' -ServerMayChange } 'database image change'
$after = Clone $before; $after[1].Id='5'*64; Reject { Assert-Containers $before $after 'inhouse' -ServerMayChange } 'database recreation'
$after = Clone $before; $after[0].Mounts[0].Source='/empty'; Reject { Assert-Containers $before $after 'inhouse' -ServerMayChange } 'media path change'
$after = Clone $before; $after[0].Mounts[0].RW=$false; Reject { Assert-Containers $before $after 'inhouse' -ServerMayChange } 'read-only media mount'
$after = Clone $before; $after[2].Project='other'; Reject { Assert-Containers $before $after 'inhouse' -ServerMayChange } 'wrong project'
$after = Clone $before; $after[2].Service='database'; Reject { Assert-Containers $before $after 'inhouse' -ServerMayChange } 'duplicate service'
$after = Clone $before; $after[2].Id='6'*64; $after[2].Image='sha256:'+'e'*64
Assert-Containers $before $after 'inhouse' -Adoption; Check $true 'manager adoption accepts application rollouts'
$after = Clone $before; $after[1].Image='sha256:'+'e'*64; Reject { Assert-Containers $before $after 'inhouse' -Adoption } 'adoption database remains pinned'

$hashes = [pscustomobject]@{'docker-compose.yml'='a';'.env'='b'}
Assert-Configuration $hashes @{'docker-compose.yml'='a';'.env'='b'}; Check $true 'matching configuration hashes'
Reject { Assert-Configuration $hashes @{'docker-compose.yml'='a';'.env'='changed'} } 'changed environment'
Reject { Assert-Configuration $hashes @{'docker-compose.yml'='a';'.env'='b';Caddyfile='c'} } 'additional configuration'

# Exercise metadata reconstruction, including absent bind-mount fields and an
# empty Redis mounts array, through the exact quote-free native argv template.
$originalDocker = ${function:Invoke-Docker}
try {
  function Invoke-Docker([string[]]$Arguments) {
    if ($Arguments[0] -ceq 'compose') { return (($before | ForEach-Object { $_.Id }) -join "`n") }
    Check ($Arguments[2].IndexOf('"') -eq -1) 'inspect template supports Windows PowerShell legacy argv'
    return (($before | ForEach-Object {
      $labels = [pscustomobject]@{'com.docker.compose.service'=$_.Service;'com.docker.compose.project'=$_.Project}
      ConvertTo-Json -InputObject @($_.Id, $_.Image, $labels, $_.Mounts) -Depth 15 -Compress
    }) -join "`n")
  }
  $prefs = [pscustomobject]@{Installation='unused';ProjectName='inhouse'}
  $parsed = @(Get-Containers $prefs 'unused')
  Assert-Containers $before $parsed 'inhouse'
  Check ($parsed[0].Mounts.Count -eq 1 -and $parsed[2].Mounts.Count -eq 0) 'native inspect retains mount array shape'
} finally { ${function:Invoke-Docker} = $originalDocker }

# Exercise the actual context writer under the running PowerShell version.
# JSON arrays in Windows PowerShell 5.1 must become separate env-file lines,
# including values containing spaces. Never print their contents.
$contextDirectory = Join-Path ([IO.Path]::GetTempPath()) ('inhouse-env-check-' + [Guid]::NewGuid().ToString('N'))
$originalDocker = ${function:Invoke-Docker}
try {
  [void][IO.Directory]::CreateDirectory($contextDirectory)
  $expectedEnvironment = @('DB_HOSTNAME=fixture-db', 'DB_PASSWORD=fixture with spaces', 'REDIS_HOSTNAME=fixture-redis', 'REDIS_PORT=6380')
  function Invoke-Docker([string[]]$Arguments) {
    if ($Arguments[2] -ceq '{{json .NetworkSettings.Networks}}') { return '{"fixture_network":{}}' }
    if ($Arguments[2] -ceq '{{json .Config.Env}}') { return ConvertTo-Json -InputObject $expectedEnvironment -Compress }
    throw 'Unexpected environment fixture query.'
  }
  $context = New-QueueContext ('1'*64) $contextDirectory
  $lines = [IO.File]::ReadAllLines($context.EnvironmentFile)
  Check ($context.Network -ceq 'fixture_network') 'queue helper uses the verified server network'
  Check ($lines.Count -eq $expectedEnvironment.Count) 'every Docker environment variable occupies its own line in PowerShell 5.1'
  Check ((ConvertTo-Json -InputObject $lines -Compress) -ceq (ConvertTo-Json -InputObject $expectedEnvironment -Compress)) 'queue context preserves exact variable values including spaces without printing them'
} finally {
  ${function:Invoke-Docker} = $originalDocker
  if ([IO.Directory]::Exists($contextDirectory)) { [IO.Directory]::Delete($contextDirectory, $true) }
}

# A cached image may avoid reimport only when every published identity agrees.
# A missing tag is different from an unresponsive Docker daemon.
$originalDocker = ${function:Invoke-Docker}
$script:imageProbeMode = 'present'
$script:imageProbeCommands = New-Object 'Collections.Generic.List[string]'
function Reset-ImageProbe {
  $script:imageProbeMode = 'present'
  $script:imageProbeCommands.Clear()
  $script:imageProbeValues = @($publicVersion.imageId, 'linux', 'amd64',
    [pscustomobject]@{'org.opencontainers.image.revision'=$publicVersion.sourceCommit;
      'org.opencontainers.image.version'=$publicVersion.version;
      'inhouse.runtime.database-schema-sha256'=$publicVersion.databaseSchemaSha256})
}
try {
  function Invoke-Docker([string[]]$Arguments, [int]$TimeoutSeconds = 0) {
    $script:imageProbeCommands.Add($Arguments[0])
    if ($Arguments[0] -ceq 'version') {
      if ($script:imageProbeMode -ceq 'daemon-down') { throw (New-Object TimeoutException 'Fixture daemon unavailable.') }
      return 'verified fixture daemon'
    }
    if ($script:imageProbeMode -ceq 'timeout') {
      $failure = New-Object TimeoutException 'Fixture inspect timeout.'
      $failure.Data['RuntimeNativeTimeout'] = $true
      throw $failure
    }
    if (@('missing', 'daemon-down', 'other-exit') -ccontains $script:imageProbeMode) {
      $failure = New-Object InvalidOperationException 'Fixture image inspect failed.'
      $failure.Data['RuntimeNativeExit'] = if ($script:imageProbeMode -ceq 'other-exit') { 2 } else { 1 }
      throw $failure
    }
    return ConvertTo-Json -InputObject $script:imageProbeValues -Depth 10 -Compress
  }
  Reset-ImageProbe
  Check (Test-RuntimeImage $publicVersion) 'exact published cached image can skip archive import'
  Check ($script:imageProbeCommands.Count -eq 1 -and $script:imageProbeCommands[0] -ceq 'image') 'cached image verification does not load or probe unrelated state'
  Reset-ImageProbe; $script:imageProbeValues[0]=$dualIdentity.imageConfigId
  Check ((Get-RuntimeImageId $dualIdentity) -ceq $dualIdentity.imageConfigId) 'classic Docker config digest is returned as the actual verified image identity'
  Reset-ImageProbe
  Check ((Get-RuntimeImageId $dualIdentity) -ceq $dualIdentity.imageId) 'containerd manifest digest is returned as the actual verified image identity'
  Reset-ImageProbe; $script:imageProbeValues[0]='sha256:' + '1' * 64
  Reject { Get-RuntimeImageId $dualIdentity } 'matching version labels never authorize an unpublished image digest'
  Reset-ImageProbe; $script:imageProbeValues[0]=$dualIdentity.imageConfigId
  $script:imageProbeValues[3].PSObject.Properties['org.opencontainers.image.revision'].Value='different'
  Reject { Get-RuntimeImageId $dualIdentity } 'alternate config identity still requires exact published source revision'
  foreach ($index in @(0, 1, 2)) {
    Reset-ImageProbe; $script:imageProbeValues[$index] = 'different'
    Reject { Test-RuntimeImage $publicVersion } ('cached image refuses identity or platform mismatch ' + $index)
  }
  foreach ($label in @('org.opencontainers.image.revision', 'org.opencontainers.image.version', 'inhouse.runtime.database-schema-sha256')) {
    Reset-ImageProbe; $script:imageProbeValues[3].PSObject.Properties[$label].Value = 'different'
    Reject { Test-RuntimeImage $publicVersion } ('cached image refuses mismatched ' + $label)
    Reset-ImageProbe; $script:imageProbeValues[3].PSObject.Properties.Remove($label)
    Reject { Test-RuntimeImage $publicVersion } ('cached image requires ' + $label)
  }
  Reset-ImageProbe; $script:imageProbeMode = 'missing'
  Check (-not (Test-RuntimeImage $publicVersion)) 'absent image with responsive daemon requires archive import'
  Check (($script:imageProbeCommands -join ',') -ceq 'image,version') 'absence checks Docker daemon before permitting archive import'
  Reset-ImageProbe; $script:imageProbeMode = 'daemon-down'
  Reject { Test-RuntimeImage $publicVersion } 'image absence never hides an unavailable Docker daemon'
  Reset-ImageProbe; $script:imageProbeMode = 'timeout'
  Reject { Test-RuntimeImage $publicVersion } 'image inspect timeout cannot trigger archive import'
  Check (($script:imageProbeCommands -join ',') -ceq 'image') 'inspect timeout does not issue another Docker operation'
  Reset-ImageProbe; $script:imageProbeMode = 'other-exit'
  Reject { Test-RuntimeImage $publicVersion } 'unexpected image inspect exit cannot trigger archive import'
  Check (($script:imageProbeCommands -join ',') -ceq 'image') 'unexpected inspect exit does not probe daemon or import archive'
} finally { ${function:Invoke-Docker} = $originalDocker }

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('inhouse-runtime-check-' + [Guid]::NewGuid().ToString('N'))
try {
  $journalDir = Join-Path $temporary 'runtime-updates/transaction'
  [void][IO.Directory]::CreateDirectory($journalDir)
  $journal = Join-Path $journalDir 'transaction.json'
  foreach ($status in @('prepared', 'starting', 'resuming', 'rollback-required')) {
    Write-PrivateJson $journal ([pscustomobject]@{status=$status})
    Reject { Assert-NoIncompleteUpdate $temporary } ('prevent rerun after interrupted ' + $status)
  }
  foreach ($status in @('completed', 'rolled-back', 'aborted')) {
    Write-PrivateJson $journal ([pscustomobject]@{status=$status})
    Assert-NoIncompleteUpdate $temporary
    Check $true ('allow rerun after ' + $status)
  }
} finally { if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary, $true) } }

# Windows PowerShell 5.1 treats redirected native stderr differently from pwsh
# on Linux. Exercise the real process boundary: successful Docker/Compose
# progress must not become a terminating PowerShell error or pollute JSON.
if ($env:OS -ceq 'Windows_NT') {
  function Check-NativeFixtureExited([int]$ProcessId, [string]$Role, [string]$Description) {
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    $exited = $null -eq $process
    $name = 'absent'
    if ($process) {
      try {
        $exited = $process.HasExited
        try { $name = $process.ProcessName } catch { $name = 'unavailable' }
      } catch { $exited = $null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) }
      finally { $process.Dispose() }
    }
    # A terminated Windows process can remain enumerable while another handle
    # or an outer runner job retains it. Its exit state proves the client has
    # stopped; a still-running or unverifiable descendant must fail this check.
    if (-not $exited) { Write-Host ('Native fixture role={0} HasExited={1} ProcessName={2}' -f $Role,$exited,$name) }
    Check $exited $Description
  }
  $nativeDirectory = Join-Path ([IO.Path]::GetTempPath()) ('inhouse native check ' + [Guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($nativeDirectory)
  $savedDockerExe = $script:DockerExe
  $savedCancellationPath = $script:CancellationPath
  $nativeCancellationPath = ''
  try {
    $script:DockerExe = Join-Path $nativeDirectory 'docker fixture.exe'
    Add-Type -Language CSharp -OutputType ConsoleApplication -OutputAssembly $script:DockerExe -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
public static class InhouseDockerNativeFixture {
  static readonly string DirectoryPath = Path.GetDirectoryName(Process.GetCurrentProcess().MainModule.FileName);
  static readonly string StatePath = Path.Combine(DirectoryPath, "helper-state.txt");
  static readonly string LogPath = Path.Combine(DirectoryPath, "helper-commands.txt");
  static readonly string HelperId = new string('a', 64);
  static string After(string[] args, string name) {
    var index = Array.IndexOf(args, name);
    return index >= 0 && index + 1 < args.Length ? args[index + 1] : "";
  }
  public static int Main(string[] args) {
    Console.Error.WriteLine("Native fixture progress on stderr.");
    if (Array.IndexOf(args, "--native-child-hang") >= 0) { Thread.Sleep(120000); return 0; }
    if (Array.IndexOf(args, "--native-orphan-parent") >= 0) {
      using (var child = Process.Start(new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "--native-child-hang") {
        UseShellExecute = false, CreateNoWindow = true
      })) {
        File.WriteAllLines(After(args, "--native-orphan-parent"), new [] { Process.GetCurrentProcess().Id.ToString(), child.Id.ToString() });
        // Give the supervisor time to attach its job before the parent exits.
        // The child keeps the inherited stdout/stderr handles open afterward.
        Thread.Sleep(500);
      }
      return 0;
    }
    if (Array.IndexOf(args, "--native-parent-hang") >= 0 || Array.IndexOf(args, "--native-parent-hang-with-cancel") >= 0) {
      var hangArgument = Array.IndexOf(args, "--native-parent-hang-with-cancel") >= 0 ? "--native-parent-hang-with-cancel" : "--native-parent-hang";
      using (var child = Process.Start(new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "--native-child-hang") {
        UseShellExecute = false, CreateNoWindow = true
      })) {
        File.WriteAllLines(After(args, hangArgument), new [] { Process.GetCurrentProcess().Id.ToString(), child.Id.ToString() });
        if (hangArgument == "--native-parent-hang-with-cancel") {
          Thread.Sleep(500);
          File.WriteAllText(After(args, "--native-cancel-signal"), "cancel");
        }
        Thread.Sleep(120000);
      }
      return 0;
    }
    if (Array.IndexOf(args, "--native-argv") >= 0) {
      var index = Array.IndexOf(args, "--native-argv");
      for (var item = index + 1; item < args.Length; item++)
        Console.Out.WriteLine("ARG:" + Convert.ToBase64String(Encoding.UTF8.GetBytes(args[item])));
      return 0;
    }
    if (Array.IndexOf(args, "--native-large-pipes") >= 0) {
      Console.Error.Write(new string('e', 262144));
      Console.Out.Write(new string('o', 262144));
      return 0;
    }
    if (Array.IndexOf(args, "--native-failure") >= 0) {
      Console.Out.WriteLine("This output must not be accepted.");
      return 23;
    }
    if (Array.IndexOf(args, "--native-success") >= 0) {
      Console.Out.WriteLine("native stdout");
      return 0;
    }
    if (Array.IndexOf(args, "create") >= 0) {
      if (After(args, "--pull") != "never" || After(args, "--entrypoint") != "node" || Array.IndexOf(args, "--interactive") < 0)
        return 26;
      var name = After(args, "--name");
      var label = After(args, "--label");
      var action = After(args, "-");
      File.WriteAllLines(StatePath, new [] { name, label, action });
      File.AppendAllText(LogPath, "create\n");
      Console.Out.WriteLine(HelperId);
      return 0;
    }
    if (Array.IndexOf(args, "start") >= 0) {
      if (!File.Exists(StatePath) || Array.IndexOf(args, HelperId) < 0 ||
          Array.IndexOf(args, "--attach") < 0 || Array.IndexOf(args, "--interactive") < 0) return 27;
      var input = Console.In.ReadToEnd();
      if (!input.Contains("Queue check timed out")) return 28;
      File.AppendAllText(LogPath, "start\n");
      if (File.ReadAllLines(StatePath)[2] == "resume") return 24;
      Console.Out.WriteLine("{\"schemaVersion\":1,\"activeJobs\":0,\"pausedStates\":{\"storageSaverCompression\":true,\"storageSaverVideoCompression\":true}}");
      return 0;
    }
    if (Array.IndexOf(args, "ps") >= 0) {
      File.AppendAllText(LogPath, "ps\n");
      if (File.Exists(StatePath)) {
        var state = File.ReadAllLines(StatePath);
        if (After(args, "--filter") != "name=^/" + state[0] + "$") return 29;
        Console.Out.WriteLine(HelperId);
      }
      return 0;
    }
    if (Array.IndexOf(args, "inspect") >= 0 && Array.IndexOf(args, HelperId) >= 0) {
      var state = File.ReadAllLines(StatePath);
      var labelValue = state[1].Substring("inhouse.runtime.helper=".Length);
      File.AppendAllText(LogPath, "inspect\n");
      Console.Out.WriteLine("[\"" + HelperId + "\",{\"inhouse.runtime.helper\":\"" + labelValue + "\"}]");
      return 0;
    }
    if (Array.IndexOf(args, "rm") >= 0 && Array.IndexOf(args, HelperId) >= 0) {
      if (Array.IndexOf(args, "-f") < 0) return 30;
      File.AppendAllText(LogPath, "rm\n");
      File.Delete(StatePath);
      return 0;
    }
    return 25;
  }
}
'@
    $legacyBridgeFailed = $false
    try {
      $legacyOutput = & $script:DockerExe --native-success 2>&1
      $legacyBridgeFailed = (($legacyOutput | Out-String).Trim() -cne 'native stdout')
    } catch { $legacyBridgeFailed = $true }
    Check $legacyBridgeFailed 'legacy native stderr redirection fails or contaminates stdout with an exit-zero fixture'
    Check ((Invoke-Docker @('--native-success')) -ceq 'native stdout') 'native stderr progress with exit zero preserves only stdout'
    try {
      function Get-Command([string]$Name, $CommandType, $ErrorAction) {
        return @([pscustomobject]@{Source=$script:DockerExe},[pscustomobject]@{Source=$script:DockerExe})
      }
      Check ((Invoke-Docker @('--native-success')) -ceq 'native stdout') 'duplicate executable PATH matches resolve one real native application'
    } finally { Remove-Item -LiteralPath Function:Get-Command }
    Reject { Invoke-Docker @('--native-failure') } 'native nonzero exit rejects regardless of stderr or stdout'
    $expectedArguments = @('', 'plain', 'two words', 'C:\folder with spaces\', 'one"two', 'one\"two',
      '--format', '{{json .Config.Labels}}', '" --native-failure "', '$(fixture); & echo fixture', ('line1' + "`n" + 'line2'))
    $argumentResult = Invoke-RuntimeNative (@('--native-argv') + $expectedArguments) '' 10
    $actualArguments = @($argumentResult.Output -split '\r?\n' | ForEach-Object {
      if (-not $_.StartsWith('ARG:')) { throw 'Unexpected argv fixture output.' }
      [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.Substring(4)))
    })
    Check ($argumentResult.ExitCode -eq 0 -and $actualArguments.Count -eq $expectedArguments.Count) 'native process retains every argument including the empty argument'
    Check ((ConvertTo-Json -InputObject $actualArguments -Compress) -ceq (ConvertTo-Json -InputObject $expectedArguments -Compress)) 'real Windows argv preserves quotes, spaces, trailing slashes and shell-looking text exactly'
    $largeOutput = Invoke-RuntimeNative @('--native-large-pipes') '' 10
    Check ($largeOutput.ExitCode -eq 0 -and $largeOutput.Output.Length -eq 262144 -and $largeOutput.Output -ceq ('o'*262144)) 'stdout and large stderr pipes drain concurrently without contaminating output'

    $savedManagerPid = $script:ManagerProcessId
    $savedConsole = [Console]::Out
    $heartbeatCapture = New-Object IO.StringWriter
    try {
      $script:ManagerProcessId = 1
      [Console]::SetOut($heartbeatCapture)
      $heartbeatResult = @(Invoke-RuntimeNative @('--native-success') '' 10)
    } finally { [Console]::SetOut($savedConsole); $script:ManagerProcessId = $savedManagerPid }
    Check ($heartbeatResult.Count -eq 1 -and $heartbeatResult[0].Output -ceq 'native stdout') 'heartbeat bypasses the captured native stdout pipeline'
    Check ($heartbeatCapture.ToString().Contains('INHOUSE_RUNTIME_STAGE:') -and $heartbeatCapture.ToString().Contains('INHOUSE_RUNTIME_PHASE:')) 'long native operations emit sanitized manager heartbeat markers'
    $heartbeatCapture.Dispose()

    $pidFile = Join-Path $nativeDirectory 'fixture process ids.txt'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    try { Invoke-RuntimeNative @('--native-parent-hang', $pidFile) '' 2 | Out-Null }
    catch { $timedOut = ($_.Exception -is [TimeoutException] -and $_.Exception.Data['RuntimeNativeTimeout'] -eq $true) }
    $timer.Stop()
    Check ($timedOut -and $timer.ElapsedMilliseconds -lt 15000) 'native timeout returns promptly with an explicit recoverable timeout marker'
    Check ([IO.File]::Exists($pidFile)) 'timeout fixture started a native child process'
    $fixturePids = @([IO.File]::ReadAllLines($pidFile) | ForEach-Object { [int]$_ })
    Check ($fixturePids.Count -eq 2) 'timeout fixture recorded its parent and child identities'
    for ($fixtureIndex=0; $fixtureIndex -lt $fixturePids.Count; $fixtureIndex++) {
      $role=if ($fixtureIndex -eq 0) { 'parent' } else { 'child' }
      Check-NativeFixtureExited $fixturePids[$fixtureIndex] $role 'native timeout stops its client process tree'
    }

    $orphanPidFile = Join-Path $nativeDirectory 'fixture orphan process ids.txt'
    $timer.Restart(); $orphanTimedOut = $false
    try { Invoke-RuntimeNative @('--native-orphan-parent', $orphanPidFile) '' 10 | Out-Null }
    catch { $orphanTimedOut = ($_.Exception -is [TimeoutException] -and $_.Exception.Data['RuntimeNativeTimeout'] -eq $true) }
    $timer.Stop()
    Check ($orphanTimedOut -and $timer.ElapsedMilliseconds -lt 15000) 'exited native parent with inherited pipes returns a bounded recoverable timeout'
    Check ([IO.File]::Exists($orphanPidFile)) 'orphan fixture started its recorded native child'
    $fixturePids = @([IO.File]::ReadAllLines($orphanPidFile) | ForEach-Object { [int]$_ })
    Check ($fixturePids.Count -eq 2) 'orphan fixture records the exited parent and remaining child'
    for ($fixtureIndex=0; $fixtureIndex -lt $fixturePids.Count; $fixtureIndex++) {
      $role=if ($fixtureIndex -eq 0) { 'exited-parent' } else { 'orphan-child' }
      Check-NativeFixtureExited $fixturePids[$fixtureIndex] $role 'native supervisor closes its job and removes remaining descendants after parent exit'
    }

    $nativeCancellationPath = Join-Path $PSScriptRoot ('cancel-' + [Guid]::NewGuid().ToString('N') + '.signal')
    $script:CancellationPath = $nativeCancellationPath
    Assert-RuntimeCancellationPath
    [IO.File]::WriteAllText($nativeCancellationPath, 'cancel')
    $cancelledBeforePidFile = Join-Path $nativeDirectory 'fixture cancelled before ids.txt'
    $cancelledBefore = $false
    try { Invoke-RuntimeNative @('--native-parent-hang', $cancelledBeforePidFile) '' 10 | Out-Null }
    catch { $cancelledBefore = ($_.Exception -is [OperationCanceledException] -and $_.Exception.Data['RuntimeNativeTimeout'] -eq $true) }
    Check $cancelledBefore 'existing manager cancellation is reported before starting a native operation'
    Check (-not [IO.File]::Exists($cancelledBeforePidFile)) 'cancelled native operation never creates a client or child'
    [IO.File]::Delete($nativeCancellationPath)

    $cancelledDuringPidFile = Join-Path $nativeDirectory 'fixture cancelled during ids.txt'
    $timer.Restart(); $cancelledDuring = $false
    try { Invoke-RuntimeNative @('--native-parent-hang-with-cancel', $cancelledDuringPidFile, '--native-cancel-signal', $nativeCancellationPath) '' 10 | Out-Null }
    catch { $cancelledDuring = ($_.Exception -is [OperationCanceledException] -and $_.Exception.Data['RuntimeNativeTimeout'] -eq $true) }
    $timer.Stop()
    Check ($cancelledDuring -and $timer.ElapsedMilliseconds -lt 15000) 'manager cancellation interrupts a running native operation within a bounded wait'
    Check ([IO.File]::Exists($cancelledDuringPidFile)) 'cancellation fixture had a running native client and child'
    $fixturePids = @([IO.File]::ReadAllLines($cancelledDuringPidFile) | ForEach-Object { [int]$_ })
    Check ($fixturePids.Count -eq 2) 'cancellation fixture recorded both native process identities'
    for ($fixtureIndex=0; $fixtureIndex -lt $fixturePids.Count; $fixtureIndex++) {
      $role=if ($fixtureIndex -eq 0) { 'cancelled-parent' } else { 'cancelled-child' }
      Check-NativeFixtureExited $fixturePids[$fixtureIndex] $role 'manager cancellation stops the native client process tree'
    }
    [IO.File]::Delete($nativeCancellationPath)
    $script:CancellationPath = $savedCancellationPath
    $environmentFile = Join-Path $nativeDirectory 'queue fixture.env'
    [IO.File]::WriteAllText($environmentFile, 'REDIS_HOSTNAME=fixture')
    $context = [pscustomobject]@{Network='fixture-network';EnvironmentFile=$environmentFile}
    $result = Invoke-QueueHelper ('sha256:' + 'a'*64) $context 'inspect' $null
    Check ($result.schemaVersion -eq 1 -and $result.activeJobs -eq 0 -and $result.pausedStates.storageSaverCompression) 'queue JSON stdout parses despite native stderr progress'
    Check (-not [IO.File]::Exists((Join-Path $nativeDirectory 'helper-state.txt'))) 'successful queue inspection removes only its temporary helper'
    Check (([IO.File]::ReadAllLines((Join-Path $nativeDirectory 'helper-commands.txt')) -join ',') -ceq 'create,start,ps,inspect,rm,ps') 'queue helper creates stopped, attaches input, verifies identity and confirms cleanup'
    $states = [pscustomobject]@{storageSaverCompression=$true;storageSaverVideoCompression=$true}
    Reject { Invoke-QueueHelper ('sha256:' + 'a'*64) $context 'resume' $states } 'queue helper nonzero native exit rejects before JSON parsing'
    Check (-not [IO.File]::Exists((Join-Path $nativeDirectory 'helper-state.txt'))) 'failed queue operation also removes its exact helper'
  } finally {
    $script:DockerExe = $savedDockerExe
    $script:CancellationPath = $savedCancellationPath
    if ($nativeCancellationPath -and [IO.File]::Exists($nativeCancellationPath)) { [IO.File]::Delete($nativeCancellationPath) }
    foreach ($fixturePidFile in @(Get-ChildItem -LiteralPath $nativeDirectory -Filter 'fixture * ids.txt' -File)) {
      foreach ($fixturePid in [IO.File]::ReadAllLines($fixturePidFile.FullName)) {
        $fixtureProcess = Get-Process -Id ([int]$fixturePid) -ErrorAction SilentlyContinue
        if ($fixtureProcess) { Stop-Process -Id $fixtureProcess.Id -Force -ErrorAction SilentlyContinue }
      }
    }
    if ([IO.Directory]::Exists($nativeDirectory)) { [IO.Directory]::Delete($nativeDirectory, $true) }
  }
}
Write-Output ($script:passed.ToString() + ' runtime updater checks passed.')
