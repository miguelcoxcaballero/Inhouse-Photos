param([ValidateSet('Inspect','Create','Add')][string]$Action='Inspect',[string]$RequestBase64='')
$ErrorActionPreference='Stop'
function Get-SafeInventory {
  foreach($physical in Get-PhysicalDisk) {
    $disk=$null
    if("$($physical.DeviceId)" -match '^\d+$') { $disk=Get-Disk -Number ([int]$physical.DeviceId) -ErrorAction SilentlyContinue }
    $reason='Disponible'
    if(-not $physical.CanPool){$reason='Ya está en uso o pertenece a un grupo'}
    elseif(-not $disk){$reason='No se puede identificar el disco de forma inequívoca'}
    elseif([string]::IsNullOrWhiteSpace($physical.SerialNumber) -or ($disk.SerialNumber -replace '\s','') -ne ($physical.SerialNumber -replace '\s','')){$reason='Identidad física no verificable'}
    elseif($disk.IsBoot -or $disk.IsSystem){$reason='Disco del sistema: protegido'}
    elseif($disk.PartitionStyle -ne 'RAW' -or $disk.NumberOfPartitions -ne 0){$reason='Contiene particiones: protegido'}
    elseif($disk.IsOffline -or $disk.IsReadOnly){$reason='Desconectado o solo lectura'}
    elseif($physical.HealthStatus -ne 'Healthy'){$reason='Estado de salud no válido'}
    elseif($physical.Size -lt 16GB){$reason='Capacidad insuficiente'}
    [pscustomobject]@{PhysicalId=[string]$physical.UniqueId;DiskId=[string]$disk.UniqueId;Serial=[string]$physical.SerialNumber;Model=[string]$physical.FriendlyName;Size=[long]$physical.Size;Eligible=($reason -eq 'Disponible');Reason=$reason}
  }
}
$inventory=@(Get-SafeInventory)
$pools=@(Get-StoragePool | Where-Object { -not $_.IsPrimordial -and $_.FriendlyName -like 'Inhouse Photos *' } | ForEach-Object {
  [pscustomobject]@{Id=[string]$_.UniqueId;Name=[string]$_.FriendlyName;Size=[long]$_.Size;Free=[long]($_.Size-$_.AllocatedSize);Health=[string]$_.HealthStatus}
})
if($Action -eq 'Inspect'){[pscustomobject]@{Disks=$inventory;Pools=$pools}|ConvertTo-Json -Depth 6 -Compress;return}
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Esta operación requiere el permiso de administrador de Windows.'}
$request=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($RequestBase64))|ConvertFrom-Json
if($request.Confirmation -cne 'CREAR'){throw 'Falta la confirmación escrita.'}
if($request.Disks.Count -lt 1 -or $request.Disks.Count -gt 16){throw 'Número de discos no válido.'}
if(@($request.Disks.PhysicalId|Select-Object -Unique).Count -ne $request.Disks.Count){throw 'La selección contiene discos duplicados.'}
$selected=@(foreach($chosen in $request.Disks){
  $safe=@($inventory|Where-Object {$_.PhysicalId -ceq $chosen.PhysicalId})
  if($safe.Count -ne 1 -or -not $safe[0].Eligible -or $safe[0].DiskId -cne $chosen.DiskId -or $safe[0].Serial -cne $chosen.Serial -or $safe[0].Size -ne $chosen.Size){throw 'La identidad o el estado de un disco ha cambiado. Vuelve a revisarlo.'}
  $current=@(Get-PhysicalDisk|Where-Object UniqueId -CEQ $chosen.PhysicalId)
  if($current.Count -ne 1 -or -not $current[0].CanPool){throw 'El disco ya no está disponible.'}
  $current[0]
})
if($Action -eq 'Add'){
  $pool=@(Get-StoragePool -IsPrimordial $false|Where-Object { $_.UniqueId -ceq $request.PoolId -and $_.FriendlyName -like 'Inhouse Photos *' })
  if($pool.Count -ne 1 -or $pool[0].HealthStatus -ne 'Healthy'){throw 'No se puede verificar el grupo de destino.'}
  Add-PhysicalDisk -StoragePool $pool[0] -PhysicalDisks $selected
  [pscustomobject]@{Message='Discos añadidos al grupo. La biblioteca no se ha movido. El nuevo espacio queda disponible en el grupo; los volúmenes existentes conservan su tamaño.'}|ConvertTo-Json -Compress
  return
}
if($request.Mode -notin @('Mirror','Parity')){throw 'Solo se permiten espejo y paridad con redundancia.'}
if(($request.Mode -eq 'Mirror' -and $selected.Count -lt 2) -or ($request.Mode -eq 'Parity' -and $selected.Count -lt 3)){throw 'No hay suficientes discos para la redundancia seleccionada.'}
$subsystems=@(Get-StorageSubSystem|Where-Object FriendlyName -like 'Windows Storage*')
if($subsystems.Count -ne 1){throw 'No se encuentra un subsistema compatible de Espacios de almacenamiento.'}
$name='Inhouse Photos '+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+([guid]::NewGuid().ToString('N').Substring(0,6))
$pool=New-StoragePool -FriendlyName $name -StorageSubSystemUniqueId $subsystems[0].UniqueId -PhysicalDisks $selected -ResiliencySettingNameDefault $request.Mode
# Only format the newly returned virtual disk. Never enumerate existing disks
# for formatting, clear a physical disk, or roll back by deleting user data.
$virtual=New-VirtualDisk -InputObject $pool -FriendlyName $name -ResiliencySettingName $request.Mode -ProvisioningType Fixed -UseMaximumSize
$virtualDisk=@($virtual|Get-Disk)
if($virtualDisk.Count -ne 1 -or $virtualDisk[0].IsBoot -or $virtualDisk[0].IsSystem -or $virtualDisk[0].PartitionStyle -ne 'RAW' -or $virtualDisk[0].NumberOfPartitions -ne 0){throw 'El grupo está creado pero el volumen no se inicializó: identidad inesperada. No se ha formateado nada.'}
$initialized=Initialize-Disk -InputObject $virtualDisk[0] -PartitionStyle GPT -PassThru
$partition=New-Partition -DiskNumber $initialized.Number -AssignDriveLetter -UseMaximumSize
$volume=$partition|Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Inhouse Photos' -Confirm:$false
[pscustomobject]@{Message=('Espacio protegido creado en '+$volume.DriveLetter+':. Puedes elegirlo para una biblioteca nueva o una copia de seguridad.');PoolId=$pool.UniqueId;Drive=$volume.DriveLetter}|ConvertTo-Json -Compress
