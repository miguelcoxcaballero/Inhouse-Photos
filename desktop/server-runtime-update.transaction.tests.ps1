$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'server-runtime-update.ps1') -FunctionsOnly -ManifestPath unused -ManifestSha256 ('a' * 64) -ArchivePath unused -SettingsDirectory unused

$script:checks = 0
function Check([bool]$Value, [string]$Description) {
  if (-not $Value) { throw ('FAIL: ' + $Description) }
  $script:checks++
}
function Reject([scriptblock]$Action, [string]$Description) {
  try { & $Action | Out-Null; throw ('DID NOT REJECT: ' + $Description) }
  catch { if ($_.Exception.Message.StartsWith('DID NOT REJECT:')) { throw }; $script:checks++ }
}
function Clone($Value) {
  # An explicit variable return enumerates the top-level array consistently
  # in Windows PowerShell 5.1, preserving arrays inside each row's mounts.
  $parsed = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 30)
  return $parsed
}
function Assert-NoManager {}
function New-PrivateDirectory([string]$Path) { [void][IO.Directory]::CreateDirectory($Path) }
$script:fixturePhase='initial'
$script:productionAssertContainers=${function:Assert-Containers}
function Assert-Containers($Expected, $Current, [string]$Project, [switch]$ServerMayChange, [switch]$Adoption) {
  try { & $script:productionAssertContainers $Expected $Current $Project -ServerMayChange:$ServerMayChange -Adoption:$Adoption }
  catch {
    # Fake row counts and test names only; no environment, paths or identities.
    Write-Host ('Transaction fixture phase={0} checks={1} expectedRows={2} currentRows={3} fixtureRows={4}' -f
      $script:fixturePhase,$script:checks,$Expected.Count,$Current.Count,$script:fixture.Rows.Count)
    Write-Host $_.ScriptStackTrace
    throw
  }
}

$script:roots = New-Object 'Collections.Generic.List[string]'
function New-Fixture {
  $root = Join-Path ([IO.Path]::GetTempPath()) ('inhouse-transaction-test-' + [Guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($root); $script:roots.Add($root)
  $settings = Join-Path $root 'manager'; $install = Join-Path $root 'library'
  [void][IO.Directory]::CreateDirectory($settings); [void][IO.Directory]::CreateDirectory($install)
  $compose = "services:`n  immich-server:`n    image: previous:tag`n    volumes:`n      - ./photos:/data`n  database:`n    image: postgres`n"
  [IO.File]::WriteAllText((Join-Path $install 'docker-compose.yml'), $compose)
  [IO.File]::WriteAllText((Join-Path $install '.env'), 'DB_HOSTNAME=database')
  $old = 'sha256:' + 'a' * 64; $new = 'sha256:' + 'b' * 64
  $rows = @(
    [pscustomobject]@{Id=('1'*64);Image=$old;Service='immich-server';Project='inhouse';Mounts=@(
      [pscustomobject]@{Type='bind';Source='/photos';Destination='/data';Mode='rw';RW=$true;Propagation='rprivate'})},
    [pscustomobject]@{Id=('2'*64);Image=('sha256:'+'c'*64);Service='database';Project='inhouse';Mounts=@(
      [pscustomobject]@{Type='volume';Name='pg';Source='/pg';Destination='/var/lib/postgresql/data';Driver='local';Mode='rw';RW=$true;Propagation=''})},
    [pscustomobject]@{Id=('3'*64);Image=('sha256:'+'d'*64);Service='redis';Project='inhouse';Mounts=@()})
  $snapshot = Join-Path $settings 'snapshot'; [IO.File]::WriteAllText($snapshot, 'verified snapshot')
  $receiptPath = Join-Path $settings 'receipt.json'
  $receipt = [pscustomobject]@{RestoreVerified=$true;Snapshot=$snapshot;SnapshotSha256=(Get-Sha256 $snapshot);
    ConfigurationHashes=(Get-ConfigurationHashes $install);Containers=$rows}
  Write-PrivateJson $receiptPath $receipt
  $prefs = [pscustomobject]@{Managed=$true;ProjectName='inhouse';Installation=$install;ReceiptPath=$receiptPath}
  Write-PrivateJson (Join-Path $settings 'settings.json') $prefs
  $archive = Join-Path $root 'server.tar.gz'; [IO.File]::WriteAllText($archive, 'verified image archive fixture')
  $manifest = [pscustomobject]@{format=1;version='3.1.0-storage-saver-test';sourceCommit=('e'*40);
    image='inhouse-photos-server:release';imageId=$new;archiveFile='server.tar.gz';archiveSha256=(Get-Sha256 $archive);
    platform='linux/amd64';compatibleServerImageIds=@($old);databaseMigrations='unchanged';databaseSchemaSha256=('f'*64)}
  $manifestPath = Join-Path $root 'manifest.json'; Write-PrivateJson $manifestPath $manifest
  $script:fixture = [pscustomobject]@{Root=$root;Settings=$settings;Installation=$install;Prefs=$prefs;
    Old=$old;New=$new;Manifest=$manifest;Rows=(Clone $rows);OriginalRows=(Clone $rows);
    QueueStates=[pscustomobject]@{storageSaverCompression=$false;storageSaverVideoCompression=$true};
    FailLoad=$false;FailHealth=$false;TimeoutCompose=$false;ImageAvailable=$false;MigrationInstalled=$false;
    HelperName='';HelperPresent=$false;HelperLabelMatches=$true;Commands=(New-Object 'Collections.Generic.List[string]')}
  $script:SettingsDirectory=$settings; $script:ManifestPath=$manifestPath
  $script:ManifestSha256=Get-Sha256 $manifestPath; $script:ArchivePath=$archive
  $script:ResumeRecord=''; $script:RollbackRecord=''; $script:Apply=$true
  $script:QueueContext=$null; $script:ManagerProcessId=0
}
function Journal {
  $files = @(Get-ChildItem -LiteralPath $fixture.Settings -Filter transaction.json -Recurse -File)
  if ($files.Count -ne 1) { throw 'Fixture must have one durable journal.' }
  return $files[0].FullName
}
function Get-Containers($Preferences, [string]$ComposeFile) {
  $rows = Clone $script:fixture.Rows
  foreach ($row in $rows) { $row }
}
function Invoke-Docker([string[]]$Arguments, [int]$TimeoutSeconds = 0) {
  $fixture.Commands.Add(($Arguments -join ' '))
  if ($Arguments[0] -ceq 'compose') {
    if ($Arguments -contains 'config') {
      $path=$Arguments[([array]::IndexOf($Arguments, '-f')+1)]
      $image=[regex]::Match([IO.File]::ReadAllText($path), '(?m)^    image: (.+)$').Groups[1].Value
      return (@{services=@{'immich-server'=@{image=$image}}} | ConvertTo-Json -Depth 10 -Compress)
    }
    if ($Arguments -contains 'up') {
      $image=if ([IO.File]::ReadAllText((Join-Path $fixture.Installation 'docker-compose.yml')).Contains($fixture.Manifest.image)) { $fixture.New } else { $fixture.Old }
      $other=@($fixture.Rows | Where-Object { $_.Service -cne 'immich-server' })
      $server=Clone (@($fixture.OriginalRows | Where-Object { $_.Service -ceq 'immich-server' })[0])
      $server.Id='4'*64; $server.Image=$image; $fixture.Rows=@($server)+$other
      if ($fixture.TimeoutCompose) {
        $failure=New-Object TimeoutException 'Fixture Compose client timed out after the daemon created the new service.'
        $failure.Data['RuntimeNativeTimeout']=$true
        throw $failure
      }
      return 'server created'
    }
  }
  if ($Arguments[0] -ceq 'load') {
    if ($fixture.FailLoad) { throw 'Fixture image load interrupted.' }
    $fixture.ImageAvailable=$true
    return 'image loaded'
  }
  if ($Arguments[0] -ceq 'image') {
    if ($Arguments[-1] -ceq 'previous:tag') { return $fixture.Old }
    if ($Arguments[3] -ceq '{{.Id}}') { return $fixture.New }
    if (-not $fixture.ImageAvailable) {
      $failure=New-Object InvalidOperationException 'Fixture image absent.'
      $failure.Data['RuntimeNativeExit']=1
      throw $failure
    }
    return ConvertTo-Json -InputObject @($fixture.New,'linux','amd64',
      [pscustomobject]@{'org.opencontainers.image.revision'=$fixture.Manifest.sourceCommit;
        'org.opencontainers.image.version'=$fixture.Manifest.version;
        'inhouse.runtime.database-schema-sha256'=$fixture.Manifest.databaseSchemaSha256}) -Depth 10 -Compress
  }
  if ($Arguments[0] -ceq 'version') { return 'fixture Docker daemon' }
  if ($Arguments[0] -ceq 'ps') { if ($fixture.HelperPresent) { return '5'*64 }; return '' }
  if ($Arguments[0] -ceq 'rm') {
    if ($Arguments[-1] -cne ('5'*64)) { throw 'Fixture tried removing a Compose service.' }
    $fixture.HelperPresent=$false; return 'helper removed'
  }
  if ($Arguments[0] -ceq 'inspect') {
    if ($Arguments[-1] -ceq ('5'*64)) {
      $key=if ($fixture.HelperLabelMatches) { $fixture.HelperName.Substring('inhouse-runtime-helper-'.Length) } else { 'unexpected-owner' }
      return ConvertTo-Json -InputObject @(('5'*64), [pscustomobject]@{'inhouse.runtime.helper'=$key}) -Compress
    }
    if ($Arguments[2] -ceq '{{json .NetworkSettings.Networks}}') { return '{"inhouse_default":{}}' }
    if ($Arguments[2] -ceq '{{json .Config.Env}}') { return '["DB_HOSTNAME=database","REDIS_HOSTNAME=redis"]' }
    if ($fixture.FailHealth) { return 'exited|unhealthy' }
    return 'running|healthy'
  }
  if ($Arguments[0] -ceq 'stop' -or $Arguments[0] -ceq 'start') { return 'container state changed' }
  throw ('Unexpected fixture Docker command: ' + $Arguments[0])
}
function Invoke-QueueHelper([string]$Image, $Context, [string]$Action, $OriginalState) {
  $fixture.Commands.Add('queue ' + $Action)
  if ($Action -ceq 'assert-rollback-safe' -and $fixture.MigrationInstalled) { throw 'Fixture durable schema forbids downgrade.' }
  if ($Action -ceq 'pause') {
    $fixture.QueueStates.storageSaverCompression=$true; $fixture.QueueStates.storageSaverVideoCompression=$true
  }
  if ($Action -ceq 'resume') { $fixture.QueueStates=Clone $OriginalState }
  return [pscustomobject]@{activeJobs=0;pausedStates=(Clone $fixture.QueueStates)}
}
function Assert-Preserved {
  $receipt = Read-Json $fixture.Prefs.ReceiptPath
  Check ((Get-Sha256 $receipt.Snapshot) -ceq $receipt.SnapshotSha256) 'verified backup survives the transaction'
  foreach ($service in @('database','redis')) {
    $original=@($fixture.OriginalRows | Where-Object { $_.Service -ceq $service })[0]
    $actual=@($fixture.Rows | Where-Object { $_.Service -ceq $service })[0]
    Check ($actual.Id -ceq $original.Id -and $actual.Image -ceq $original.Image) ('preserve ' + $service + ' identity')
  }
  Check (@($fixture.Commands | Where-Object { $_ -match '(^| )(down|-V)( |$)' -or
    ($_ -match '^rm ' -and $_ -cne ('rm -f ' + '5'*64)) }).Count -eq 0) 'never remove library, database, volumes or jobs'
}

$savedOs=$env:OS
try {
  $env:OS='Windows_NT'
  $script:fixturePhase='normal-install'
  New-Fixture
  Invoke-RuntimeUpdate | Out-Null
  $record=Read-Json (Journal)
  Check ($record.status -ceq 'completed') 'normal install reaches terminal completed'
  $receipt=Read-Json $fixture.Prefs.ReceiptPath
  Check ($receipt.ConfigurationHashes.'docker-compose.yml' -ceq (Get-Sha256 (Join-Path $fixture.Installation 'docker-compose.yml'))) 'receipt accepts the installed configuration'
  Check (@($receipt.Containers | Where-Object { $_.Service -ceq 'immich-server' })[0].Image -ceq $fixture.New) 'receipt records actual new image'
  Check (-not $fixture.QueueStates.storageSaverCompression -and $fixture.QueueStates.storageSaverVideoCompression) 'preserve original independent paused flags'
  Assert-Preserved

  $script:fixturePhase='skip-already-loaded-image'
  New-Fixture; $fixture.ImageAvailable=$true
  Invoke-RuntimeUpdate | Out-Null
  Check ((Read-Json (Journal)).status -ceq 'completed') 'a fully verified preloaded image installs normally'
  Check (@($fixture.Commands | Where-Object { $_ -like 'load *' }).Count -eq 0) 'do not reimport an already verified Docker image'
  Assert-Preserved

  $script:fixturePhase='classic-Docker-config-identity'
  New-Fixture; $fixture.ImageAvailable=$true
  $fixture.Manifest | Add-Member imageConfigId $fixture.New
  $fixture.Manifest.imageId='sha256:' + '9' * 64
  Write-PrivateJson $script:ManifestPath $fixture.Manifest
  $script:ManifestSha256=Get-Sha256 $script:ManifestPath
  Invoke-RuntimeUpdate | Out-Null
  $record=Read-Json (Journal)
  Check ($record.status -ceq 'completed' -and $record.newImageId -ceq $fixture.New) 'journal saves exact actual config digest, not the other backend manifest digest'
  Check (@($fixture.Commands | Where-Object { $_ -like 'load *' }).Count -eq 0) 'config identity backend does not download or import an already verified image again'
  Check (@($fixture.Commands | Where-Object { $_ -like '*sha256:999999*' -and $_ -notlike 'image *' }).Count -eq 0) 'queues and restart target only the actual verified image digest'
  Assert-Preserved

  $script:fixturePhase='compose-timeout-recovery'
  New-Fixture; $fixture.TimeoutCompose=$true; $fixture.MigrationInstalled=$true
  Reject { Invoke-RuntimeUpdate } 'Compose timeout ends the operation without racing a rollback'
  $path=Journal
  Check ((Read-Json $path).status -ceq 'rollback-required') 'uncertain daemon mutation retains recoverable journal'
  Check (@($fixture.Commands | Where-Object { $_ -ceq 'queue assert-rollback-safe' -or $_ -like 'stop *' }).Count -eq 0) 'Compose timeout never starts an automatic downgrade or stops a possibly transitioning server'
  $fixture.TimeoutCompose=$false; $script:ResumeRecord=$path
  Invoke-RuntimeUpdate | Out-Null
  Check ((Read-Json $path).status -ceq 'completed') 'retry reconciles actual new server after Compose timeout'
  Check (-not $fixture.QueueStates.storageSaverCompression -and $fixture.QueueStates.storageSaverVideoCompression) 'timeout recovery restores independent original queue states'
  Assert-Preserved

  $script:fixturePhase='cleanup-interrupted-queue-helper'
  New-Fixture; $fixture.FailLoad=$true
  Reject { Invoke-RuntimeUpdate } 'prepare an interrupted journal for helper cleanup'
  $path=Journal; $record=Read-Json $path
  $fixture.HelperName='inhouse-runtime-helper-' + ('a'*32); $fixture.HelperPresent=$true
  $record | Add-Member activeQueueHelper $fixture.HelperName
  Write-PrivateJson $path $record
  $script:ResumeRecord=$path; $fixture.FailLoad=$false; $fixture.Commands.Clear()
  Invoke-RuntimeUpdate | Out-Null
  Check (-not $fixture.HelperPresent) 'recovery removes only its exact labelled auxiliary container'
  Check ((Read-Json $path).status -ceq 'aborted') 'untouched preparation becomes terminal after helper cleanup'
  Check ((Read-Json $path).activeQueueHelper -ceq '') 'confirmed helper cleanup clears persisted helper receipt'
  Assert-Preserved
  $record=Read-Json $path
  $record | Add-Member deferredQueueHelpers @($fixture.HelperName)
  Write-PrivateJson $path $record
  $fixture.HelperPresent=$true; $fixture.ImageAvailable=$true; $script:ResumeRecord=''; $fixture.Commands.Clear()
  $script:Apply=$false
  Invoke-RuntimeUpdate | Out-Null
  Check ($fixture.HelperPresent -and @($fixture.Commands | Where-Object { $_ -like 'rm *' }).Count -eq 0) 'read-only preflight never removes even its deferred helper'
  $script:Apply=$true
  Invoke-RuntimeUpdate | Out-Null
  Check (-not $fixture.HelperPresent) 'a stopped helper created late is cleaned on the next update using its retained receipt'
  Check ((Read-Json $path).status -ceq 'aborted') 'deferred cleanup never makes a terminal preparation pending again'
  Assert-Preserved

  $script:fixturePhase='refuse-unowned-queue-helper'
  New-Fixture; $fixture.FailLoad=$true
  Reject { Invoke-RuntimeUpdate } 'prepare journal to reject another container ownership'
  $path=Journal; $record=Read-Json $path
  $fixture.HelperName='inhouse-runtime-helper-' + ('b'*32); $fixture.HelperPresent=$true; $fixture.HelperLabelMatches=$false
  $record | Add-Member activeQueueHelper $fixture.HelperName
  Write-PrivateJson $path $record
  $script:ResumeRecord=$path; $fixture.FailLoad=$false; $fixture.Commands.Clear()
  Reject { Invoke-RuntimeUpdate } 'never remove a helper name with a different ownership label'
  Check ($fixture.HelperPresent -and @($fixture.Commands | Where-Object { $_ -like 'rm *' }).Count -eq 0) 'ownership mismatch leaves the container untouched'
  Assert-Preserved

  $script:fixturePhase='failed-before-change'
  New-Fixture
  $fixture.FailLoad=$true
  Reject { Invoke-RuntimeUpdate } 'image load failure preserves recoverable journal'
  $path=Journal; $record=Read-Json $path
  Check ($record.status -ceq 'failed-before-change' -and $null -eq $record.queueState) 'failure before queues leaves an explicit durable preparation'
  $fixture.FailLoad=$false; $script:ResumeRecord=$path
  Invoke-RuntimeUpdate | Out-Null
  Check ((Read-Json $path).status -ceq 'aborted') 'retry finishes untouched preparation instead of an endless pending state'
  Check (@($fixture.Commands | Where-Object { $_ -like 'queue *' }).Count -eq 0) 'unmodified preparation never touches Redis'
  $script:ResumeRecord=''
  Invoke-RuntimeUpdate | Out-Null
  $records=@(Get-ChildItem -LiteralPath $fixture.Settings -Filter transaction.json -Recurse -File | ForEach-Object { Read-Json $_.FullName })
  Check (@($records | Where-Object { $_.status -ceq 'completed' }).Count -eq 1) 'a fresh installation succeeds immediately after aborted preparation'
  Assert-Preserved

  $script:fixturePhase='recover-new-engine'
  New-Fixture
  $fixture.FailHealth=$true; $fixture.MigrationInstalled=$true
  Reject { Invoke-RuntimeUpdate } 'failed new health never downgrades a migrated database'
  $path=Journal
  Check ((Read-Json $path).status -ceq 'rollback-required') 'new engine failure retains durable recovery journal'
  Check (@($fixture.Rows | Where-Object { $_.Service -ceq 'immich-server' })[0].Image -ceq $fixture.New) 'retain new engine for durable migration recovery'
  $fixture.FailHealth=$false; $script:ResumeRecord=$path
  Invoke-RuntimeUpdate | Out-Null
  Check ((Read-Json $path).status -ceq 'completed') 'retry confirms existing new engine and clears pending journal'
  Check (-not $fixture.QueueStates.storageSaverCompression -and $fixture.QueueStates.storageSaverVideoCompression) 'retry restores original paused flags'
  Assert-Preserved

  $script:fixturePhase='recover-missing-server'
  New-Fixture
  $fixture.FailHealth=$true; $fixture.MigrationInstalled=$true
  Reject { Invoke-RuntimeUpdate } 'create fixture for interrupted container recreation'
  $path=Journal; $fixture.Rows=@($fixture.Rows | Where-Object { $_.Service -cne 'immich-server' })
  $fixture.FailHealth=$false; $script:ResumeRecord=$path; $fixture.Commands.Clear()
  Invoke-RuntimeUpdate | Out-Null
  Check ((Read-Json $path).status -ceq 'completed') 'missing photo server is safely recreated and recovered'
  Check (@($fixture.Commands | Where-Object { $_ -match 'up --no-start --no-deps --no-build --pull never immich-server' }).Count -eq 1) 'recovery creates only photo server stopped before starting'
  Assert-Preserved

  $script:fixturePhase='refuse-unsafe-old-engine'
  New-Fixture
  $fixture.FailHealth=$true; $fixture.MigrationInstalled=$true
  Reject { Invoke-RuntimeUpdate } 'create fixture for incompatible old engine recovery'
  $path=Journal
  [IO.File]::Copy((Join-Path ([IO.Path]::GetDirectoryName($path)) 'docker-compose.before.yml'), (Join-Path $fixture.Installation 'docker-compose.yml'), $true)
  $fixture.Rows=Clone $fixture.OriginalRows; $fixture.FailHealth=$false
  $script:ResumeRecord=$path; $fixture.Commands.Clear()
  Reject { Invoke-RuntimeUpdate } 'old engine cannot start after durable schema appears'
  Check (@($fixture.Commands | Where-Object { $_ -match '(^start | up )' }).Count -eq 0) 'failed downgrade guard never starts an incompatible old image'
  Check ((Read-Json $path).status -ceq 'rollback-required') 'unsafe downgrade remains recoverable without changing database'
  Assert-Preserved

  Reject { Set-RuntimeStage 'private-user-data' } 'failure stage accepts only fixed public codes'
  $script:ManagerProcessId=1; Set-RuntimeStage 'queues'
  Check ((Write-RuntimeFailure) -ceq 'INHOUSE_RUNTIME_FAILURE:queues') 'failure protocol contains no paths, credentials or raw Docker output'
  $script:RuntimeFailureReason='image_identity'
  Check ((@(Write-RuntimeFailure) -join ',') -ceq 'INHOUSE_RUNTIME_FAILURE:queues,INHOUSE_RUNTIME_REASON:image_identity') 'failure protocol exposes only a safe specific reason code'
  $script:RuntimeFailureReason='private-user:private-token'
  Check ((Write-RuntimeFailure) -ceq 'INHOUSE_RUNTIME_FAILURE:queues') 'unknown failure reasons never leak private diagnostic text'
  $script:RuntimeFailureReason=''
  $script:ManagerProcessId=0
  Write-Output ($script:checks.ToString() + ' runtime transaction checks passed.')
} finally {
  $env:OS=$savedOs
  foreach ($root in $script:roots) { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}
