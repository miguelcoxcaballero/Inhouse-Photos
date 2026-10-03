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
  $nativeDirectory = Join-Path ([IO.Path]::GetTempPath()) ('inhouse native check ' + [Guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($nativeDirectory)
  $savedDockerExe = $script:DockerExe
  try {
    $script:DockerExe = Join-Path $nativeDirectory 'docker fixture.exe'
    Add-Type -Language CSharp -OutputType ConsoleApplication -OutputAssembly $script:DockerExe -TypeDefinition @'
using System;
public static class InhouseDockerNativeFixture {
  public static int Main(string[] args) {
    Console.Error.WriteLine("Native fixture progress on stderr.");
    if (Array.IndexOf(args, "--native-failure") >= 0) {
      Console.Out.WriteLine("This output must not be accepted.");
      return 23;
    }
    if (Array.IndexOf(args, "--native-success") >= 0) {
      Console.Out.WriteLine("native stdout");
      return 0;
    }
    if (Array.IndexOf(args, "run") >= 0) {
      Console.In.ReadToEnd();
      if (Array.IndexOf(args, "resume") >= 0) return 24;
      Console.Out.WriteLine("{\"schemaVersion\":1,\"activeJobs\":0,\"pausedStates\":{\"storageSaverCompression\":true,\"storageSaverVideoCompression\":true}}");
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
    Reject { Invoke-Docker @('--native-failure') } 'native nonzero exit rejects regardless of stderr or stdout'
    $environmentFile = Join-Path $nativeDirectory 'queue fixture.env'
    [IO.File]::WriteAllText($environmentFile, 'REDIS_HOSTNAME=fixture')
    $context = [pscustomobject]@{Network='fixture-network';EnvironmentFile=$environmentFile}
    $result = Invoke-QueueHelper ('sha256:' + 'a'*64) $context 'inspect' $null
    Check ($result.schemaVersion -eq 1 -and $result.activeJobs -eq 0 -and $result.pausedStates.storageSaverCompression) 'queue JSON stdout parses despite native stderr progress'
    $states = [pscustomobject]@{storageSaverCompression=$true;storageSaverVideoCompression=$true}
    Reject { Invoke-QueueHelper ('sha256:' + 'a'*64) $context 'resume' $states } 'queue helper nonzero native exit rejects before JSON parsing'
  } finally {
    $script:DockerExe = $savedDockerExe
    if ([IO.Directory]::Exists($nativeDirectory)) { [IO.Directory]::Delete($nativeDirectory, $true) }
  }
}
Write-Output ($script:passed.ToString() + ' runtime updater checks passed.')
