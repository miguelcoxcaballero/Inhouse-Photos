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
function Clone($Value) { return ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 30) }
function Assert-NoManager {}
function New-PrivateDirectory([string]$Path) { [void][IO.Directory]::CreateDirectory($Path) }

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
    FailLoad=$false;FailHealth=$false;MigrationInstalled=$false;Commands=(New-Object 'Collections.Generic.List[string]')}
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
function Get-Containers($Preferences, [string]$ComposeFile) { return Clone $script:fixture.Rows }
function Invoke-Docker([string[]]$Arguments) {
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
      return 'server created'
    }
  }
  if ($Arguments[0] -ceq 'load') {
    if ($fixture.FailLoad) { throw 'Fixture image load interrupted.' }
    return 'image loaded'
  }
  if ($Arguments[0] -ceq 'image') {
    if ($Arguments[-1] -ceq 'previous:tag') { return $fixture.Old }
    if ($Arguments[3] -ceq '{{.Id}}') { return $fixture.New }
    return ConvertTo-Json -InputObject @($fixture.New,'linux','amd64',
      [pscustomobject]@{'org.opencontainers.image.revision'=$fixture.Manifest.sourceCommit;
        'inhouse.runtime.database-schema-sha256'=$fixture.Manifest.databaseSchemaSha256}) -Depth 10 -Compress
  }
  if ($Arguments[0] -ceq 'inspect') {
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
  Check (@($fixture.Commands | Where-Object { $_ -match '(^| )(down|rm|-V)( |$)' }).Count -eq 0) 'never remove library, database, volumes or jobs'
}

$savedOs=$env:OS
try {
  $env:OS='Windows_NT'
  New-Fixture
  Invoke-RuntimeUpdate | Out-Null
  $record=Read-Json (Journal)
  Check ($record.status -ceq 'completed') 'normal install reaches terminal completed'
  $receipt=Read-Json $fixture.Prefs.ReceiptPath
  Check ($receipt.ConfigurationHashes.'docker-compose.yml' -ceq (Get-Sha256 (Join-Path $fixture.Installation 'docker-compose.yml'))) 'receipt accepts the installed configuration'
  Check (@($receipt.Containers | Where-Object { $_.Service -ceq 'immich-server' })[0].Image -ceq $fixture.New) 'receipt records actual new image'
  Check (-not $fixture.QueueStates.storageSaverCompression -and $fixture.QueueStates.storageSaverVideoCompression) 'preserve original independent paused flags'
  Assert-Preserved

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

  New-Fixture
  $fixture.FailHealth=$true; $fixture.MigrationInstalled=$true
  Reject { Invoke-RuntimeUpdate } 'create fixture for interrupted container recreation'
  $path=Journal; $fixture.Rows=@($fixture.Rows | Where-Object { $_.Service -cne 'immich-server' })
  $fixture.FailHealth=$false; $script:ResumeRecord=$path; $fixture.Commands.Clear()
  Invoke-RuntimeUpdate | Out-Null
  Check ((Read-Json $path).status -ceq 'completed') 'missing photo server is safely recreated and recovered'
  Check (@($fixture.Commands | Where-Object { $_ -match 'up --no-start --no-deps --no-build --pull never immich-server' }).Count -eq 1) 'recovery creates only photo server stopped before starting'
  Assert-Preserved

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
  $script:ManagerProcessId=0
  Write-Output ($script:checks.ToString() + ' runtime transaction checks passed.')
} finally {
  $env:OS=$savedOs
  foreach ($root in $script:roots) { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}
