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

$mount = [pscustomobject]@{Type='bind';Source='/library';Destination='/data';Mode='rw';RW=$true;Propagation='rprivate'}
$dbMount = [pscustomobject]@{Type='volume';Name='inhouse_pgdata';Source='/var/lib/docker/volumes/inhouse_pgdata/_data';Destination='/var/lib/postgresql/data';Driver='local';Mode='rw';RW=$true;Propagation=''}
$before = @(
  [pscustomobject]@{Id=('1'*64);Image=('sha256:'+'a'*64);Service='immich-server';Project='inhouse';Mounts=@($mount)},
  [pscustomobject]@{Id=('2'*64);Image=('sha256:'+'b'*64);Service='database';Project='inhouse';Mounts=@($dbMount)},
  [pscustomobject]@{Id=('3'*64);Image=('sha256:'+'c'*64);Service='redis';Project='inhouse';Mounts=@()})
Assert-Containers $before $before 'inhouse'; Check $true 'unmodified production identity'
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
Write-Output ($script:passed.ToString() + ' runtime updater checks passed.')
