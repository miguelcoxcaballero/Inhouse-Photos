#Requires -Version 5.1
<#
Updates only the existing immich-server service. Use the separately published
manifest SHA-256; a checksum from an untrusted package is not a trust anchor.
Without -Apply this performs read-only preflight. Run as the Windows user who
owns the manager settings and Docker Desktop installation, with the manager shut.
#>
[CmdletBinding(DefaultParameterSetName = 'Update')]
param(
  [Parameter(Mandatory, ParameterSetName = 'Update')][string]$ManifestPath,
  [Parameter(Mandatory, ParameterSetName = 'Update')][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ManifestSha256,
  [Parameter(Mandatory, ParameterSetName = 'Update')][string]$ArchivePath,
  [Parameter(Mandatory, ParameterSetName = 'Rollback')][string]$RollbackRecord,
  [Parameter(Mandatory, ParameterSetName = 'Resume')][string]$ResumeRecord,
  [string]$SettingsDirectory = (Join-Path $env:LOCALAPPDATA 'Inhouse Photos Server'),
  [string]$DockerExe = 'docker',
  [ValidateRange(30, 1800)][int]$HealthTimeoutSeconds = 300,
  [ValidateRange(0, 2147483647)][int]$ManagerProcessId = 0,
  [string]$ManagerOperationKey = '',
  [switch]$Apply,
  [switch]$FunctionsOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:RuntimeFailureStage = 'preflight'

function Set-RuntimeStage([string]$Stage) {
  if (@('preflight', 'image', 'queues', 'quiesce', 'config', 'restart', 'receipt', 'recovery', 'rollback') -cnotcontains $Stage) {
    throw 'Etapa de actualización no válida.'
  }
  $script:RuntimeFailureStage = $Stage
}

function Write-RuntimeFailure {
  if ($ManagerProcessId -gt 0) { Write-Output ('INHOUSE_RUNTIME_FAILURE:' + $script:RuntimeFailureStage) }
}

function Write-RuntimePhase([string]$Phase) {
  if (@('verifying', 'waiting', 'installing', 'restarting', 'completed') -cnotcontains $Phase) {
    throw 'Fase de actualización no válida.'
  }
  if ($ManagerProcessId -gt 0) { Write-Output ('INHOUSE_RUNTIME_PHASE:' + $Phase) }
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-LocalFile([string]$Path) {
  $full = [IO.Path]::GetFullPath($Path)
  if ($full.StartsWith('\\') -or -not [IO.File]::Exists($full)) { throw 'Falta un archivo local necesario.' }
  $cursor = $full
  while ($cursor) {
    if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw 'Los archivos y directorios de la actualización no pueden ser enlaces.'
    }
    $cursor = [IO.Path]::GetDirectoryName($cursor)
  }
  return $full
}

function Read-Json([string]$Path) {
  return [IO.File]::ReadAllText((Assert-LocalFile $Path)) | ConvertFrom-Json
}

function Write-PrivateJson([string]$Path, $Value) {
  $temp = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.new'
  [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding $false))
  if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
  else { [IO.File]::Move($temp, $Path) }
}

function New-PrivateDirectory([string]$Path) {
  $cursor = [IO.Path]::GetFullPath($Path)
  while ($cursor) {
    if ((Test-Path -LiteralPath $cursor) -and
      ([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw 'El directorio de recuperación no puede contener enlaces.'
    }
    $cursor = [IO.Path]::GetDirectoryName($cursor)
  }
  [void][IO.Directory]::CreateDirectory($Path)
  $acl = New-Object Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  $sids = @([Security.Principal.WindowsIdentity]::GetCurrent().User,
    (New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'),
    (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
  foreach ($sid in $sids) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    [void]$acl.AddAccessRule($rule)
  }
  Set-Acl -LiteralPath $Path -AclObject $acl
}

function Invoke-Docker([string[]]$Arguments) {
  # Windows PowerShell 5.1 turns native stderr into NativeCommandError. Docker
  # writes ordinary progress/warnings there even on success. Keep stdout clean
  # for JSON and use the native exit status; never expose environment values.
  $savedPreference = $ErrorActionPreference
  $global:LASTEXITCODE = $null
  try {
    $ErrorActionPreference = 'Continue'
    $output = & $DockerExe --context desktop-linux @Arguments 2>$null
    $exitCode = $global:LASTEXITCODE
  } finally { $ErrorActionPreference = $savedPreference }
  if ($null -eq $exitCode -or $exitCode -ne 0) { throw ('Docker no completó la operación: ' + $Arguments[0] + '.') }
  return ($output | Out-String).Trim()
}

function Get-ComposeArguments($Preferences, [string]$ComposeFile) {
  return @('compose', '--project-directory', $Preferences.Installation,
    '--project-name', $Preferences.ProjectName, '-f', $ComposeFile)
}

function Get-Containers($Preferences, [string]$ComposeFile) {
  $args = (Get-ComposeArguments $Preferences $ComposeFile) + @('ps', '-a', '-q', '--no-trunc')
  $ids = @((Invoke-Docker $args) -split '\r?\n' | Where-Object { $_ })
  if (-not $ids.Count -or @($ids | Where-Object { $_ -notmatch '^[a-f0-9]{64}$' }).Count) {
    throw 'No se encuentra el proyecto existente. No se creará una biblioteca nueva.'
  }
  # JSON arrays avoid literal quotes in native argv: Windows PowerShell 5.1
  # removes embedded quotes when binding arguments to docker.exe.
  $format = '[{{json .Id}},{{json .Image}},{{json .Config.Labels}},{{json .Mounts}}]'
  $rows = Invoke-Docker (@('inspect', '--format', $format) + $ids)
  return @($rows -split '\r?\n' | Where-Object { $_ } | ForEach-Object {
    $parts = $_ | ConvertFrom-Json
    $labels = $parts[2]
    if (-not $labels.PSObject.Properties['com.docker.compose.service'] -or
      -not $labels.PSObject.Properties['com.docker.compose.project']) { throw 'Falta la identidad Compose de un contenedor.' }
    [pscustomobject]@{Id=$parts[0];Image=$parts[1];
      Service=$labels.PSObject.Properties['com.docker.compose.service'].Value;
      Project=$labels.PSObject.Properties['com.docker.compose.project'].Value;Mounts=@($parts[3])}
  })
}

function Get-MountKey($Mount) {
  # Match the manager's complete mount identity; ordering is not significant.
  $values = foreach ($name in @('Type', 'Name', 'Source', 'Destination', 'Driver', 'Mode', 'RW', 'Propagation')) {
    $property = $Mount.PSObject.Properties[$name]
    if ($property) { [string]$property.Value } else { '' }
  }
  return ($values | ConvertTo-Json -Compress)
}

function Assert-Containers($Expected, $Current, [string]$Project, [switch]$ServerMayChange, [switch]$Adoption) {
  if (-not $Expected.Count -or $Expected.Count -ne $Current.Count) { throw 'Cambió el conjunto de servicios del servidor.' }
  foreach ($set in @($Expected, $Current)) {
    $services = @($set | ForEach-Object { $_.Service })
    if (($services | Sort-Object -Unique).Count -ne $set.Count -or
      -not ($services -contains 'immich-server') -or -not ($services -contains 'database')) {
      throw 'La instalación no contiene un servidor y una base de datos únicos.'
    }
    foreach ($row in $set) {
      if ($row.Project -cne $Project -or $row.Id -notmatch '^[a-f0-9]{64}$' -or $row.Image -notmatch '^sha256:[a-f0-9]{64}$') {
        throw 'Cambió la identidad del proyecto.'
      }
    }
  }
  foreach ($before in $Expected) {
    $now = @($Current | Where-Object { $_.Service -ceq $before.Service })[0]
    $left = @($before.Mounts | ForEach-Object { Get-MountKey $_ } | Sort-Object)
    $right = @($now.Mounts | ForEach-Object { Get-MountKey $_ } | Sort-Object)
    if (($left | ConvertTo-Json -Compress) -cne ($right | ConvertTo-Json -Compress)) { throw 'Cambió un disco o montaje. Se detuvo la actualización.' }
    $rolling = $Adoption -and @('immich-server', 'immich-machine-learning', 'redis', 'caddy') -contains $before.Service
    if (-not $rolling -and -not ($ServerMayChange -and $before.Service -ceq 'immich-server')) {
      if ($now.Image -cne $before.Image -or (-not $Adoption -and $now.Id -cne $before.Id)) { throw 'Cambió un contenedor ajeno al servidor de fotos.' }
    }
  }
  foreach ($pair in @(@('immich-server', '/data'), @('database', '/var/lib/postgresql/data'))) {
    $row = @($Current | Where-Object { $_.Service -ceq $pair[0] })[0]
    if (-not @($row.Mounts | Where-Object { $_.Destination -ceq $pair[1] -and $_.RW -and $_.Source -and @('bind', 'volume') -contains $_.Type }).Count) {
      throw 'Falta un montaje persistente de la biblioteca o la base de datos.'
    }
  }
}

function Assert-RecoveryContainers($Expected, $Current, [string]$Project) {
  $server = @($Current | Where-Object { $_.Service -ceq 'immich-server' })
  if ($server.Count) {
    Assert-Containers $Expected $Current $Project -ServerMayChange
    return $false
  }
  # Compose can disappear between removing and recreating this one service.
  # Every remaining service must still have its exact original identity and
  # mounts. The missing server is created stopped and checked again below.
  $saved = @($Expected | Where-Object { $_.Service -ceq 'immich-server' })
  if ($saved.Count -ne 1 -or $Current.Count -ne ($Expected.Count - 1)) {
    throw 'La recuperación no encuentra únicamente el servidor de fotos.'
  }
  Assert-Containers $Expected (@($Current) + @($saved[0])) $Project -ServerMayChange
  return $true
}

function Get-ConfigurationHashes([string]$Installation) {
  $result = @{}
  foreach ($name in @('docker-compose.yml', '.env', 'Caddyfile')) {
    $file = Join-Path $Installation $name
    if (Test-Path -LiteralPath $file) { $result[$name] = Get-Sha256 (Assert-LocalFile $file) }
  }
  if (-not $result.ContainsKey('docker-compose.yml') -or -not $result.ContainsKey('.env')) { throw 'Falta la configuración existente.' }
  return $result
}

function Assert-Configuration($Expected, [hashtable]$Current) {
  $properties = @($Expected.PSObject.Properties)
  if ($properties.Count -ne $Current.Count) { throw 'Cambió la configuración desde la vinculación.' }
  foreach ($property in $properties) {
    if (-not $Current.ContainsKey($property.Name) -or $Current[$property.Name] -cne $property.Value) {
      throw 'Cambió la configuración desde la vinculación. Verifícala con el gestor antes de actualizar.'
    }
  }
}

function Assert-Manifest($Manifest) {
  foreach ($name in @('format', 'version', 'sourceCommit', 'image', 'imageId', 'archiveFile', 'archiveSha256', 'platform', 'compatibleServerImageIds', 'databaseMigrations', 'databaseSchemaSha256')) {
    if (-not $Manifest.PSObject.Properties[$name]) { throw ('Falta un campo del manifiesto: ' + $name + '.') }
  }
  if ($Manifest.format -ne 1 -or $Manifest.version -notmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[a-z0-9][a-z0-9.-]*)?$' -or
    $Manifest.sourceCommit -notmatch '^[a-f0-9]{40}$' -or
    $Manifest.image -notmatch '^inhouse-photos-server:[a-z0-9][a-z0-9_.-]{0,127}$' -or
    $Manifest.imageId -notmatch '^sha256:[a-f0-9]{64}$' -or
    $Manifest.archiveFile -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*\.tar(\.gz)?$' -or
    $Manifest.archiveSha256 -notmatch '^[a-f0-9]{64}$' -or
    $Manifest.databaseSchemaSha256 -notmatch '^[a-f0-9]{64}$' -or
    $Manifest.platform -cne 'linux/amd64' -or
    @('unchanged', 'additive-upload-outbox') -cnotcontains $Manifest.databaseMigrations -or
    -not @($Manifest.compatibleServerImageIds).Count -or
    @($Manifest.compatibleServerImageIds | Where-Object { $_ -notmatch '^sha256:[a-f0-9]{64}$' }).Count) {
    throw 'El manifiesto no describe una actualización compatible y verificable.'
  }
  if ($Manifest.databaseMigrations -ceq 'additive-upload-outbox') {
    if (-not $Manifest.PSObject.Properties['baselineDatabaseSchemaSha256'] -or
      -not $Manifest.PSObject.Properties['addedDatabaseMigrations'] -or
      $Manifest.baselineDatabaseSchemaSha256 -cne 'e4da4ec029df53f7657b2a81776bb48806c419ecfb509c95e5e84e128dbd4824' -or
      @($Manifest.addedDatabaseMigrations).Count -ne 1 -or
      $Manifest.addedDatabaseMigrations[0] -cne '1790985600000-DurableUploadProcessing') {
      throw 'El manifiesto no identifica la migración aditiva de la cola persistente.'
    }
  }
}

function Set-ServerImage([string]$Text, [string]$Image) {
  # Do not reserialize YAML or resolve its environment: retain every other byte.
  # Reject unfamiliar YAML rather than rewrite a different service or anchor.
  $service = [regex]::Matches($Text, '(?m)^  immich-server:[ \t]*(?:#[^\r\n]*)?\r?$')
  if ($service.Count -ne 1 -or [regex]::Matches($Text, '(?m)^services:[ \t]*(?:#[^\r\n]*)?\r?$').Count -ne 1) {
    throw 'El archivo Compose necesita revisión manual: estructura de servicios no compatible.'
  }
  $start = $service[0].Index + $service[0].Length
  $next = [regex]::Match($Text.Substring($start), '(?m)^(?:  [^ \t#\r\n][^\r\n]*:|[^ \t#\r\n][^\r\n]*:)')
  $length = if ($next.Success) { $next.Index } else { $Text.Length - $start }
  $block = $Text.Substring($start, $length)
  $images = [regex]::Matches($block, '(?m)^    image:[ \t]*(?<value>[^\r\n#]+?)[ \t]*(?:#[^\r\n]*)?\r?$')
  if ($images.Count -ne 1) { throw 'El servicio immich-server no tiene una imagen explícita única.' }
  $line = $images[0]
  $replacement = '    image: ' + $Image
  if ($line.Value.EndsWith("`r")) { $replacement += "`r" }
  return $Text.Substring(0, $start + $line.Index) + $replacement + $Text.Substring($start + $line.Index + $line.Length)
}

function Get-ComposeImage($Preferences, [string]$ComposeFile) {
  $config = Invoke-Docker ((Get-ComposeArguments $Preferences $ComposeFile) + @('config', '--format', 'json'))
  # This may include secrets: keep it in memory and emit only the image name.
  $parsed = $config | ConvertFrom-Json
  return [string]$parsed.services.'immich-server'.image
}

function Wait-ServerHealthy($Preferences, [string]$ComposeFile, [string]$ExpectedImage) {
  $deadline = [DateTime]::UtcNow.AddSeconds($HealthTimeoutSeconds)
  do {
    $rows = @(Get-Containers $Preferences $ComposeFile)
    $server = @($rows | Where-Object { $_.Service -ceq 'immich-server' })[0]
    if ($server.Image -cne $ExpectedImage) { throw 'El servidor arrancó con otra imagen.' }
    $state = (Invoke-Docker @('inspect', '--format', '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}', $server.Id))
    if ($state -ceq 'running|healthy') { return $rows }
    if ($state -match '^(exited|dead)\|' -or $state.EndsWith('|missing')) { throw 'El servidor no tiene un estado de salud verificable.' }
    Start-Sleep -Seconds 2
  } while ([DateTime]::UtcNow -lt $deadline)
  throw 'El nuevo servidor no confirmó su estado saludable a tiempo.'
}

function Assert-ManagerProcessChain($Helper, $Manager, $ManagerInfo, $Running, [string]$LauncherPath) {
  if ($Helper.ParentProcessId -ne $Manager.Id -or $Helper.SessionId -ne $Manager.SessionId -or
    $ManagerInfo.ProcessId -ne $Manager.Id -or $Manager.ProcessName -cne 'Inhouse-Photos-Server') {
    throw 'El proceso que inició la actualización no es el gestor esperado.'
  }
  foreach ($process in $Running) {
    if ($process.Id -eq $Manager.Id) { continue }
    # --startup keeps the immutable launcher waiting for its child manager.
    # Permit this exact parent only; every unrelated manager remains blocked.
    if ($process.Id -ne $ManagerInfo.ParentProcessId -or $process.ProcessName -cne 'Inhouse Photos' -or
      $process.SessionId -ne $Manager.SessionId -or
      -not [string]::Equals($process.Path, $LauncherPath, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'Hay otro gestor en ejecución; se conserva el motor actual.'
    }
  }
}

function Assert-NoManager {
  $running = @(Get-Process -Name 'Inhouse Photos', 'Inhouse-Photos-Server' -ErrorAction SilentlyContinue)
  if ($ManagerProcessId -gt 0) {
    # Only a direct child of the current manager may keep that manager open.
    # Its operation event exists only while the UI holds its mutation lock.
    if ($ManagerOperationKey -cnotmatch '^[a-f0-9]{32}$') { throw 'Falta la operación verificada del gestor.' }
    $self = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $PID)
    $manager = Get-Process -Id $ManagerProcessId -ErrorAction Stop
    $managerInfo = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $ManagerProcessId)
    $owner = Invoke-CimMethod -InputObject $managerInfo -MethodName GetOwnerSid
    if ($owner.ReturnValue -ne 0 -or $owner.Sid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
      throw 'El gestor y el actualizador deben utilizar el mismo usuario de Windows.'
    }
    $launcherPath = Join-Path $env:LOCALAPPDATA 'Programs\Inhouse Photos Server\Inhouse Photos.exe'
    Assert-ManagerProcessChain $self $manager $managerInfo $running $launcherPath
    $operation = $null
    try {
      $operation = [Threading.EventWaitHandle]::OpenExisting(('Local\InhousePhotosRuntime-' + $ManagerProcessId + '-' + $ManagerOperationKey))
      if (-not $operation.WaitOne(0)) { throw 'La operación del gestor ya no está activa.' }
    } finally { if ($operation) { $operation.Dispose() } }
    return
  }
  if ($ManagerOperationKey) { throw 'La operación del gestor necesita su proceso de origen.' }
  if ($running.Count) {
    throw 'Cierra Inhouse Photos Server desde su icono de la bandeja antes de actualizar.'
  }
}

function New-QueueContext([string]$ServerId, [string]$Directory) {
  Set-RuntimeStage 'queues'
  $networks = (Invoke-Docker @('inspect', '--format', '{{json .NetworkSettings.Networks}}', $ServerId)) | ConvertFrom-Json
  $names = @($networks.PSObject.Properties.Name)
  if ($names.Count -ne 1) { throw 'La red del servidor necesita revisión manual antes de actualizar.' }
  # Docker inspect is deliberately filtered. Keep Env only in memory and a
  # current-user ACL directory; never emit it as output or in the journal.
  $environment = @((Invoke-Docker @('inspect', '--format', '{{json .Config.Env}}', $ServerId)) | ConvertFrom-Json)
  if (@($environment | Where-Object { $_ -match '[\r\n]' }).Count) { throw 'Una variable del servidor no es compatible con el helper de colas.' }
  if (@($environment | Where-Object { $_ -match '^REDIS_(PASSWORD_FILE|SOCKET)=.+' }).Count) {
    throw 'Redis utiliza un archivo secreto o un socket local; esta instalación necesita una actualización adaptada a esos montajes.'
  }
  $path = Join-Path $Directory ('queue-env-' + [Guid]::NewGuid().ToString('N') + '.env')
  [IO.File]::WriteAllLines($path, [string[]]$environment, (New-Object Text.UTF8Encoding $false))
  return [pscustomobject]@{Network=$names[0];EnvironmentFile=$path}
}

function Invoke-QueueHelper([string]$Image, $Context, [string]$Action, $OriginalState) {
  if ($Action -ceq 'assert-rollback-safe') { Set-RuntimeStage 'rollback' }
  else { Set-RuntimeStage 'queues' }
  $helper = Assert-LocalFile (Join-Path $PSScriptRoot 'server-runtime-queue-handoff.cjs')
  $arguments = @('--context', 'desktop-linux', 'run', '--rm', '-i', '--no-healthcheck',
    '--network', $Context.Network, '--env-file', $Context.EnvironmentFile,
    '--entrypoint', 'node', '--workdir', '/usr/src/app/server', $Image, '-', $Action)
  if ($null -ne $OriginalState) {
    $json = $OriginalState | ConvertTo-Json -Depth 15 -Compress
    $arguments += [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
  }
  $inputText = [IO.File]::ReadAllText($helper)
  $savedPreference = $ErrorActionPreference
  $global:LASTEXITCODE = $null
  try {
    $ErrorActionPreference = 'Continue'
    $output = $inputText | & $DockerExe @arguments 2>$null
    $exitCode = $global:LASTEXITCODE
  } finally { $ErrorActionPreference = $savedPreference }
  if ($null -eq $exitCode -or $exitCode -ne 0) { throw ('No se pudo completar la operación de colas: ' + $Action + '.') }
  return ($output | Out-String | ConvertFrom-Json)
}

function Wait-CompressionIdle([string]$Image, $Context) {
  Set-RuntimeStage 'quiesce'
  Write-RuntimePhase 'waiting'
  $deadline = [DateTime]::UtcNow.AddMinutes(15)
  do {
    $state = Invoke-QueueHelper $Image $Context 'inspect' $null
    Set-RuntimeStage 'quiesce'
    if ($state.activeJobs -eq 0) { return }
    Write-Progress -Activity 'Preparando actualización' -Status ('Esperando ' + $state.activeJobs + ' compresiones activas')
    Start-Sleep -Seconds 2
  } while ([DateTime]::UtcNow -lt $deadline)
  throw 'Las compresiones activas no terminaron a tiempo; se conserva el servidor anterior.'
}

function Restore-Runtime($Record, $Preferences, [string]$ComposeFile, [string]$RecordPath) {
  Set-RuntimeStage 'rollback'
  # Pending jobs and durable outbox migrations have no consumer in the old
  # image. Never revert the database; retain the current image for recovery.
  Invoke-QueueHelper $Record.newImageId $script:QueueContext 'pause' $null | Out-Null
  Wait-CompressionIdle $Record.newImageId $script:QueueContext
  # Restore only our configuration and receipt. Never use down, rm or -V.
  if ((Invoke-Docker @('image', 'inspect', '--format', '{{.Id}}', $Record.previousImageReference)) -cne $Record.previousImageId) {
    throw 'La etiqueta anterior cambió. Se conserva la copia y no se intenta un rollback ambiguo.'
  }
  $composeBackup = Join-Path ([IO.Path]::GetDirectoryName($RecordPath)) 'docker-compose.before.yml'
  $receiptBackup = Join-Path ([IO.Path]::GetDirectoryName($RecordPath)) 'adoption-receipt.before.json'
  if ((Get-Sha256 (Assert-LocalFile $composeBackup)) -cne $Record.previousComposeSha256 -or
    (Get-Sha256 (Assert-LocalFile $receiptBackup)) -cne $Record.previousReceiptSha256) { throw 'Una copia de recuperación no supera la verificación.' }
  $expectedHashes = (Read-Json $receiptBackup).ConfigurationHashes
  $expectedHashes.'docker-compose.yml' = $Record.newComposeSha256
  Assert-Configuration $expectedHashes (Get-ConfigurationHashes $Preferences.Installation)
  $currentServer = @((Get-Containers $Preferences $ComposeFile) | Where-Object { $_.Service -ceq 'immich-server' })[0]
  Invoke-Docker @('stop', $currentServer.Id) | Out-Null
  try { Invoke-QueueHelper $Record.newImageId $script:QueueContext 'assert-rollback-safe' $null | Out-Null }
  catch {
    Invoke-Docker @('start', $currentServer.Id) | Out-Null
    throw 'La versión anterior no puede recuperar el estado persistente actual. Se mantiene la imagen nueva, los archivos y la base de datos.'
  }
  [IO.File]::Copy($composeBackup, $ComposeFile, $true)
  Invoke-Docker ((Get-ComposeArguments $Preferences $ComposeFile) + @('up', '-d', '--no-deps', '--pull', 'never', 'immich-server')) | Out-Null
  $restored = @(Wait-ServerHealthy $Preferences $ComposeFile $Record.previousImageId)
  Assert-Containers $Record.previousContainers $restored $Preferences.ProjectName -ServerMayChange
  [IO.File]::Copy($receiptBackup, $Preferences.ReceiptPath, $true)
  Invoke-QueueHelper $Record.newImageId $script:QueueContext 'resume' $Record.queueState | Out-Null
  $Record.status = 'rolled-back'
  Write-PrivateJson $RecordPath $Record
}

function Assert-NoIncompleteUpdate([string]$SettingsPath) {
  $root = Join-Path $SettingsPath 'runtime-updates'
  if (-not (Test-Path -LiteralPath $root)) { return }
  foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter transaction.json -Recurse -File)) {
    $transaction = Read-Json $file.FullName
    if (@('completed', 'rolled-back', 'aborted') -cnotcontains $transaction.status) {
      throw ('Hay una actualización pendiente. Recupera su estado con -ResumeRecord "' + $file.FullName + '" -Apply antes de reintentar.')
    }
  }
}

function Invoke-RuntimeUpdate {
  Set-RuntimeStage 'preflight'
  if ($env:OS -cne 'Windows_NT') { throw 'Este actualizador solo se ejecuta en el PC Windows del servidor.' }
  Assert-NoManager
  Write-RuntimePhase 'verifying'
  $settingsFile = Assert-LocalFile (Join-Path $SettingsDirectory 'settings.json')
  $prefs = Read-Json $settingsFile
  if (-not $prefs.Managed -or $prefs.ProjectName -notmatch '^[a-z0-9][a-z0-9_-]*$') { throw 'Completa primero la vinculación segura con Inhouse Photos Server.' }
  if (-not $ResumeRecord -and -not $RollbackRecord) { Assert-NoIncompleteUpdate $SettingsDirectory }
  $composeFile = Assert-LocalFile (Join-Path $prefs.Installation 'docker-compose.yml')
  $receiptFile = Assert-LocalFile $prefs.ReceiptPath
  $receipt = Read-Json $receiptFile
  if (-not $receipt.RestoreVerified -or (Get-Sha256 (Assert-LocalFile $receipt.Snapshot)) -cne $receipt.SnapshotSha256) {
    throw 'La copia de migración no está verificada.'
  }
  $hashes = Get-ConfigurationHashes $prefs.Installation
  if (-not $ResumeRecord) { Assert-Configuration $receipt.ConfigurationHashes $hashes }
  $before = @(Get-Containers $prefs $composeFile)
  if (-not $ResumeRecord) { Assert-Containers $receipt.Containers $before $prefs.ProjectName -Adoption }
  $servers = @($before | Where-Object { $_.Service -ceq 'immich-server' })
  $server = if ($servers.Count) { $servers[0] } else { $null }

  if ($ResumeRecord) {
    Set-RuntimeStage 'recovery'
    $recordPath = Assert-LocalFile $ResumeRecord
    $record = Read-Json $recordPath
    if ($record.format -ne 1 -or $record.project -cne $prefs.ProjectName -or
      $record.installation -cne $prefs.Installation -or $record.receiptPath -cne $prefs.ReceiptPath -or
      $record.settingsSha256 -cne (Get-Sha256 $settingsFile) -or
      ($null -ne $server -and @($record.previousImageId, $record.newImageId) -cnotcontains $server.Image)) {
      throw 'El registro pendiente no corresponde a esta instalación.'
    }
    $missingServer = Assert-RecoveryContainers $record.previousContainers $before $prefs.ProjectName
    $backup = Assert-LocalFile (Join-Path ([IO.Path]::GetDirectoryName($recordPath)) 'adoption-receipt.before.json')
    if ((Get-Sha256 $backup) -cne $record.previousReceiptSha256) { throw 'La copia del recibo cambió.' }
    $savedReceipt = Read-Json $backup
    $targetImage = if ($hashes['docker-compose.yml'] -ceq $record.previousComposeSha256) { $record.previousImageId }
      elseif ($record.newComposeSha256 -and $hashes['docker-compose.yml'] -ceq $record.newComposeSha256) { $record.newImageId }
      else { throw 'Compose cambió fuera de la actualización. Se conservan las copias para revisión manual.' }
    $savedReceipt.ConfigurationHashes.'docker-compose.yml' = $hashes['docker-compose.yml']
    Assert-Configuration $savedReceipt.ConfigurationHashes $hashes
    $targetReference = Get-ComposeImage $prefs $composeFile
    if ((Invoke-Docker @('image', 'inspect', '--format', '{{.Id}}', $targetReference)) -cne $targetImage) {
      throw 'La etiqueta de imagen de la recuperación cambió. No se recreará el servidor con otra versión.'
    }
    if (-not $Apply) { Write-Output 'Transacción pendiente verificada. Añade -Apply para confirmar el motor y restaurar el estado original de las colas.'; return }
    if ($null -eq $record.queueState) {
      if ($missingServer -or $targetImage -cne $record.previousImageId -or $server.Image -cne $record.previousImageId) { throw 'El registro no contiene el estado original de las colas.' }
      $record.status = 'aborted'
      Write-PrivateJson $recordPath $record
      Write-Output 'Preparación cancelada; el servidor y las colas no se habían cambiado.'
      return
    }
    if ($missingServer) {
      Invoke-Docker ((Get-ComposeArguments $prefs $composeFile) + @('up', '--no-start', '--no-deps', '--no-build', '--pull', 'never', 'immich-server')) | Out-Null
      $before = @(Get-Containers $prefs $composeFile)
      Assert-Containers $record.previousContainers $before $prefs.ProjectName -ServerMayChange
      $server = @($before | Where-Object { $_.Service -ceq 'immich-server' })[0]
      if ($server.Image -cne $targetImage) { throw 'El servidor creado no coincide con la imagen de recuperación.' }
    }
    $script:QueueContext = New-QueueContext $server.Id ([IO.Path]::GetDirectoryName($recordPath))
    try {
      # The target image has BullMQ in either version. Keep queues paused while
      # finishing an interrupted recreation or checking its health.
      Invoke-QueueHelper $targetImage $script:QueueContext 'pause' $null | Out-Null
      Wait-CompressionIdle $targetImage $script:QueueContext
      if ($targetImage -ceq $record.previousImageId) {
        $currentServer = @((Get-Containers $prefs $composeFile) | Where-Object { $_.Service -ceq 'immich-server' })[0]
        Invoke-Docker @('stop', $currentServer.Id) | Out-Null
        # If the old image cannot read the durable migration/outbox, leave it
        # stopped. Starting it here would defeat the rollback safety guard.
        Invoke-QueueHelper $targetImage $script:QueueContext 'assert-rollback-safe' $null | Out-Null
      }
      $targetReference = Get-ComposeImage $prefs $composeFile
      if ((Invoke-Docker @('image', 'inspect', '--format', '{{.Id}}', $targetReference)) -cne $targetImage) {
        throw 'La etiqueta de imagen de la recuperación cambió. No se recreará el servidor con otra versión.'
      }
      Set-RuntimeStage 'restart'
      Invoke-Docker ((Get-ComposeArguments $prefs $composeFile) + @('up', '-d', '--no-deps', '--pull', 'never', 'immich-server')) | Out-Null
      Write-RuntimePhase 'restarting'
      $after = @(Wait-ServerHealthy $prefs $composeFile $targetImage)
      Assert-Containers $record.previousContainers $after $prefs.ProjectName -ServerMayChange
      Assert-Configuration $savedReceipt.ConfigurationHashes (Get-ConfigurationHashes $prefs.Installation)
      Set-RuntimeStage 'receipt'
      if ($targetImage -ceq $record.previousImageId) { [IO.File]::Copy($backup, $receiptFile, $true) }
      else { $savedReceipt.Containers = $after; Write-PrivateJson $receiptFile $savedReceipt }
      $record.status = 'resuming'
      Write-PrivateJson $recordPath $record
      Invoke-QueueHelper $targetImage $script:QueueContext 'resume' $record.queueState | Out-Null
      $record.status = if ($targetImage -ceq $record.previousImageId) { 'rolled-back' } else { 'completed' }
      Write-PrivateJson $recordPath $record
      Write-Output 'Transacción recuperada. Se confirmó el motor y se restauró el estado original de las colas.'
      Write-RuntimePhase 'completed'
    } catch {
      $record.status = 'rollback-required'
      Write-PrivateJson $recordPath $record
      throw ('La recuperación no se confirmó. Se conservan las colas y copias; vuelve a verificar -ResumeRecord ' + $recordPath + '.')
    } finally { [IO.File]::Delete($script:QueueContext.EnvironmentFile) }
    return
  }

  if ($RollbackRecord) {
    $recordPath = Assert-LocalFile $RollbackRecord
    $record = Read-Json $recordPath
    if ($record.format -ne 1 -or $record.status -cne 'completed' -or $record.project -cne $prefs.ProjectName -or
      $record.installation -cne $prefs.Installation -or $record.receiptPath -cne $prefs.ReceiptPath -or
      $record.newImageId -cne $server.Image -or $record.newComposeSha256 -cne $hashes['docker-compose.yml'] -or
      $record.settingsSha256 -cne (Get-Sha256 $settingsFile)) { throw 'El registro de recuperación no corresponde a la instalación actual.' }
    Assert-Containers $record.previousContainers $before $prefs.ProjectName -ServerMayChange
    if (-not $Apply) { Write-Output 'Identidad del rollback verificada. Al aplicar se comprobarán también las colas pendientes.'; return }
    $script:QueueContext = New-QueueContext $server.Id ([IO.Path]::GetDirectoryName($recordPath))
    try {
      $record.queueState = (Invoke-QueueHelper $record.newImageId $script:QueueContext 'inspect' $null).pausedStates
      try {
        Invoke-QueueHelper $record.newImageId $script:QueueContext 'pause' $null | Out-Null
        Wait-CompressionIdle $record.newImageId $script:QueueContext
        Restore-Runtime $record $prefs $composeFile $recordPath
      }
      catch {
        $record.status = 'rollback-required'
        Write-PrivateJson $recordPath $record
        throw
      }
    } finally { [IO.File]::Delete($script:QueueContext.EnvironmentFile) }
    Write-Output 'Se restauró la imagen anterior y su recibo. Biblioteca y base de datos conservadas.'
    return
  }

  $manifestFile = Assert-LocalFile $ManifestPath
  if ((Get-Sha256 $manifestFile) -cne $ManifestSha256.ToLowerInvariant()) { throw 'El manifiesto no coincide con el SHA-256 publicado.' }
  $manifest = Read-Json $manifestFile
  Assert-Manifest $manifest
  $archiveFile = Assert-LocalFile $ArchivePath
  if ([IO.Path]::GetFileName($archiveFile) -cne $manifest.archiveFile -or (Get-Sha256 $archiveFile) -cne $manifest.archiveSha256) {
    throw 'El archivo de la imagen no coincide con la publicación.'
  }
  if (@($manifest.compatibleServerImageIds) -cnotcontains $server.Image -and $server.Image -cne $manifest.imageId) {
    throw 'La versión instalada no figura como compatible en la publicación. No se sustituirá.'
  }
  $previousRef = Get-ComposeImage $prefs $composeFile
  if ((Invoke-Docker @('image', 'inspect', '--format', '{{.Id}}', $previousRef)) -cne $server.Image) { throw 'La imagen de Compose no coincide con el servidor en ejecución.' }
  $candidate = Set-ServerImage ([IO.File]::ReadAllText($composeFile)) $manifest.image
  if ($server.Image -ceq $manifest.imageId) { Write-Output ('Ya está instalada la imagen ' + $manifest.version + '.'); return }
  if (-not $Apply) { Write-Output ('Actualización compatible: ' + $manifest.version + '. Añade -Apply para instalarla. Solo se recreará immich-server.'); return }

  # A private transaction journal survives PowerShell termination and retains
  # original bytes, settings identity, image identity and the adoption receipt.
  $directory = Join-Path $SettingsDirectory ('runtime-updates\' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N'))
  New-PrivateDirectory $directory
  [IO.File]::Copy($composeFile, (Join-Path $directory 'docker-compose.before.yml'))
  [IO.File]::Copy($receiptFile, (Join-Path $directory 'adoption-receipt.before.json'))
  [IO.File]::Copy($manifestFile, (Join-Path $directory 'release-manifest.json'))
  $recordPath = Join-Path $directory 'transaction.json'
  $record = [pscustomobject]@{format=1; status='prepared'; version=$manifest.version; sourceCommit=$manifest.sourceCommit;
    project=$prefs.ProjectName; installation=$prefs.Installation; receiptPath=$prefs.ReceiptPath;
    settingsSha256=(Get-Sha256 $settingsFile); previousImageReference=$previousRef; previousImageId=$server.Image;
    newImageId=$manifest.imageId; previousComposeSha256=$hashes['docker-compose.yml']; newComposeSha256='';
    previousReceiptSha256=(Get-Sha256 $receiptFile); previousContainers=$before; queueState=$null;
    startedUtc=[DateTime]::UtcNow.ToString('o')}
  Write-PrivateJson $recordPath $record
  $changed = $false
  $paused = $false
  $script:QueueContext = $null
  try {
    # A release archive is a docker save, with a unique release tag. The archive
    # hash is checked before load; inspect verifies its content after load.
    Write-RuntimePhase 'installing'
    Set-RuntimeStage 'image'
    Invoke-Docker @('load', '--input', $archiveFile) | Out-Null
    $imageFormat = '[{{json .Id}},{{json .Os}},{{json .Architecture}},{{json .Config.Labels}}]'
    $image = (Invoke-Docker @('image', 'inspect', '--format', $imageFormat, $manifest.image)) | ConvertFrom-Json
    $revision = $image[3].PSObject.Properties['org.opencontainers.image.revision']
    $schema = $image[3].PSObject.Properties['inhouse.runtime.database-schema-sha256']
    if ($image[0] -cne $manifest.imageId -or $image[1] -cne 'linux' -or $image[2] -cne 'amd64' -or
      -not $revision -or $revision.Value -cne $manifest.sourceCommit -or
      -not $schema -or $schema.Value -cne $manifest.databaseSchemaSha256) {
      throw 'La imagen cargada no coincide con el commit y la plataforma publicados.'
    }
    $script:QueueContext = New-QueueContext $server.Id $directory
    $record.queueState = (Invoke-QueueHelper $manifest.imageId $script:QueueContext 'inspect' $null).pausedStates
    Write-PrivateJson $recordPath $record
    # Preserve every pending job. Pause both queues and let active old workers
    # finish before changing the image; readiness runs while they remain paused.
    $paused = $true
    Invoke-QueueHelper $manifest.imageId $script:QueueContext 'pause' $null | Out-Null
    Wait-CompressionIdle $manifest.imageId $script:QueueContext
    # Do not replace configuration changed by the manager or a concurrent admin.
    Set-RuntimeStage 'config'
    Assert-NoManager
    Assert-Configuration $receipt.ConfigurationHashes (Get-ConfigurationHashes $prefs.Installation)
    Assert-Containers $before @(Get-Containers $prefs $composeFile) $prefs.ProjectName
    if ((Get-Sha256 $settingsFile) -cne $record.settingsSha256 -or (Get-Sha256 $receiptFile) -cne $record.previousReceiptSha256) { throw 'La vinculación cambió durante la preparación.' }
    $temporary = Join-Path $prefs.Installation ('inhouse-runtime-' + [Guid]::NewGuid().ToString('N') + '.yml')
    [IO.File]::WriteAllText($temporary, $candidate, (New-Object Text.UTF8Encoding $false))
    try {
      if ((Get-ComposeImage $prefs $temporary) -cne $manifest.image) { throw 'Compose no resolvió la imagen prevista.' }
      $record.newComposeSha256 = Get-Sha256 $temporary
      Write-PrivateJson $recordPath $record
      [IO.File]::Replace($temporary, $composeFile, [NullString]::Value)
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    $changed = $true
    $record.newComposeSha256 = Get-Sha256 $composeFile
    $record.status = 'starting'
    Write-PrivateJson $recordPath $record
    Set-RuntimeStage 'restart'
    Invoke-Docker ((Get-ComposeArguments $prefs $composeFile) + @('up', '-d', '--no-deps', '--pull', 'never', 'immich-server')) | Out-Null
    Write-RuntimePhase 'restarting'
    $after = @(Wait-ServerHealthy $prefs $composeFile $manifest.imageId)
    Assert-Containers $before $after $prefs.ProjectName -ServerMayChange
    $expectedHashes = $receipt.ConfigurationHashes | ConvertTo-Json | ConvertFrom-Json
    $expectedHashes.'docker-compose.yml' = $record.newComposeSha256
    Assert-Configuration $expectedHashes (Get-ConfigurationHashes $prefs.Installation)
    Set-RuntimeStage 'receipt'
    $receipt.ConfigurationHashes.'docker-compose.yml' = $record.newComposeSha256
    $receipt.Containers = $after
    Write-PrivateJson $receiptFile $receipt
    $record.status = 'resuming'
    Write-PrivateJson $recordPath $record
    Invoke-QueueHelper $manifest.imageId $script:QueueContext 'resume' $record.queueState | Out-Null
    $paused = $false
    $record.status = 'completed'
    Write-PrivateJson $recordPath $record
    Write-Output ('Instalada ' + $manifest.version + ', commit ' + $manifest.sourceCommit + '. Solo se recreó immich-server.')
    Write-Output ('Recuperación: ' + $recordPath)
    Write-RuntimePhase 'completed'
  } catch {
    if ($changed) {
      try { Restore-Runtime $record $prefs $composeFile $recordPath }
      catch { $record.status = 'rollback-required'; Write-PrivateJson $recordPath $record; throw ('No se confirmó la recuperación automática; la imagen anterior no puede leer trabajos o migraciones nuevos. Se conservan la imagen nueva, los archivos y las copias en ' + $directory + '. Usa -ResumeRecord para recuperar el motor nuevo.') }
      $paused = $false
      throw 'La actualización no se confirmó. Se restauró el servidor anterior y su recibo.'
    }
    $record.status = 'failed-before-change'
    Write-PrivateJson $recordPath $record
    throw
  } finally {
    if ($script:QueueContext) {
      # If an update failed before switching images, restore the original queue
      # state. After an unsafe rollback, leave both paused for operator recovery.
      if ($paused -and -not $changed) {
        Invoke-QueueHelper $manifest.imageId $script:QueueContext 'resume' $record.queueState | Out-Null
        $record.status = 'aborted'
        Write-PrivateJson $recordPath $record
      }
      [IO.File]::Delete($script:QueueContext.EnvironmentFile)
    }
  }
}

if (-not $FunctionsOnly) {
  $runtimeMutex = New-Object Threading.Mutex($false, 'Local\InhousePhotosRuntimeUpdate')
  $ownsRuntimeMutex = $false
  try {
    try { $ownsRuntimeMutex = $runtimeMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $ownsRuntimeMutex = $true }
    if (-not $ownsRuntimeMutex) { throw 'Ya hay una actualización del motor en curso.' }
    Invoke-RuntimeUpdate
  } catch {
    Write-RuntimeFailure
    throw
  } finally {
    if ($ownsRuntimeMutex) { $runtimeMutex.ReleaseMutex() }
    $runtimeMutex.Dispose()
  }
}
