function Get-TargetResource {
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $FriendlyName,

        [parameter(Mandatory = $true)]
        [System.String]
        $DriveLetter,

        [parameter(Mandatory = $true)]
        [System.UInt16[]]
        $LUNS
    )

    Write-Warning -Message "Checking for StoragePool $FriendlyName"
    ###
    # 1. PhysicalDisk
    # 2. StoragePool
    # 3. VirtualDisk
    # 4. Volume

    $Ensure = 'Absent'

    $MyDriveLetter = (Get-Volume -filesystemlabel $FriendlyName).DriveLetter

    # Compare LUNS
    $SP_LUNS =  Get-StoragePool -FriendlyName $FriendlyName -ErrorAction Ignore |
        Get-PhysicalDisk -ErrorAction Ignore |
        Select-Object @{n='LUN';E={($_.physicallocation -split 'LUN ')[1]}} |
        ForEach-Object {($_.LUN)}
    $IN_LUNS = $LUNS | select-object @{n = 'LUN'; E = {($_)} }
    $COMP_LUNS = Compare-Object -ReferenceObject $IN_LUNS -DifferenceObject $SP_LUNS -Property LUN -IncludeEqual |
        Where-Object {$_.SideIndicator -eq '==' }

    if ((Get-StoragePool -FriendlyName $FriendlyName).OperationalStatus -eq 'OK' `
        -and (Get-VirtualDisk -FriendlyName $FriendlyName).OperationalStatus -eq 'OK' `
        -and (Get-Volume -filesystemlabel $FriendlyName -DriveLetter $DriveLetter).filesystem -eq 'NTFS' `
        -and ($LUNS.Count -eq $COMP_LUNS.Count)) {
        $Ensure = 'Present'
    }

    $MyDisks = $SP_LUNS | ForEach-Object {($_.LUN)}

    $returnValue = @{
        FriendlyName = $FriendlyName
        DriveLetter  = $MyDriveLetter
        LUNS         = $MyDisks

        Ensure       = $Ensure
    }

    $returnValue
}


function Set-TargetResource {
    [CmdletBinding()]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $FriendlyName,

        [parameter(Mandatory = $true)]
        [System.String]
        $DriveLetter,

        [parameter(Mandatory = $true)]
        [System.UInt16[]]
        $LUNS,

        [ValidateSet("Present", "Absent")]
        [System.String]
        $Ensure,

        [System.UInt16]
        $ColumnCount = 0
    )

    Write-Warning -Message "Running Set"

    $storageSS = Get-StorageSubSystem -ErrorAction Ignore
    $AvailableDisks = Get-PhysicalDisk -ErrorAction Ignore | ? CanPool -EQ $True |
        Select @{n = 'LUN'; E = { ($_.physicallocation -split 'LUN ')[1] } },
        CanPool, @{n = 'SizeGB'; E = { $_.Size / 1GB } }, UniqueID | sort LUN

    $MyDisks = $AvailableDisks | ? { $_.LUN -in $LUNS }
    if ($MyDisks) {
        $MyPhysicalDisks = Get-PhysicalDisk -ErrorAction Ignore |
        Where { $_.CanPool -EQ $True -and $_.UniqueID -in $MyDisks.UniqueID }
    }
    $DiskCount = $MyPhysicalDisks.Count

    # Create the storage pool if it doesn't exist.
    $SP = Get-StoragePool -FriendlyName $FriendlyName -ErrorAction Ignore
    if (! $SP) {
        $SP = New-StoragePool -PhysicalDisks $MyPhysicalDisks -FriendlyName $FriendlyName -StorageSubSystemFriendlyName $storageSS.FriendlyName -ErrorAction Ignore
        Remove-Variable -Name storageSS -ErrorAction Ignore
    }

    if ($SP) {
        # Create VirtualDisk if it doesn't exist.
        $VD = Get-VirtualDisk -FriendlyName $SP.FriendlyName -ErrorAction Ignore
        if (! $VD) {
            Stop-Service -Name ShellHWDetection -erroraction ignore
            if ($ColumnCount -gt 0) {
                $VD = New-VirtualDisk -ResiliencySettingName Simple -StoragePoolFriendlyName $SP.FriendlyName -FriendlyName $SP.FriendlyName -ProvisioningType Fixed -UseMaximumSize -NumberOfColumns $ColumnCount -ErrorAction Ignore
            }
            else {
                $VD = New-VirtualDisk -ResiliencySettingName Simple -StoragePoolFriendlyName $SP.FriendlyName -FriendlyName $SP.FriendlyName -ProvisioningType Fixed -UseMaximumSize -NumberOfColumns $DiskCount -ErrorAction Ignore
            }
        }

        if ($VD) {
            $Vol = Get-Volume -DriveLetter $DriveLetter -ErrorAction Ignore
            if (! $Vol) {
                # Initialize the disk
                $init = Get-VirtualDisk $VD.FriendlyName | Initialize-Disk -PartitionStyle GPT -ErrorAction Ignore
                # format the disk
                $vol = Get-VirtualDisk $VD.FriendlyName -ErrorAction Ignore | Get-Disk -ErrorAction Ignore | New-Partition -UseMaximumSize -DriveLetter $DriveLetter  -ErrorAction Ignore |
                Format-Volume -FileSystem NTFS -NewFileSystemLabel $VD.FriendlyName -AllocationUnitSize 64KB  -ErrorAction Ignore
            }
            elseif ($MyPhysicalDisks) {
                $pd = Get-StoragePool -FriendlyName $FriendlyName -ErrorAction Ignore | Add-PhysicalDisk -PhysicalDisks $MyPhysicalDisks -Usage AutoSelect -ErrorAction Ignore
            }
        }
        else {
            Write-Warning -Message "Could not create virtual disk $Friendlyname"
        }
    }
    else {
        Write-Warning -Message "Could not create storage pool $Friendlyname"
    }
}


function Test-TargetResource {
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $FriendlyName,

        [parameter(Mandatory = $true)]
        [System.String]
        $DriveLetter,

        [parameter(Mandatory = $true)]
        [System.UInt16[]]
        $LUNS,

        [ValidateSet("Present", "Absent")]
        [System.String]
        $Ensure,

        [System.UInt16]
        $ColumnCount = 0
    )

    if (Get-StoragePool -FriendlyName $FriendlyName -ErrorAction Ignore) {
        $AvailableDisks = Get-PhysicalDisk | ? CanPool -EQ $True |
            Select-Object @{n = 'LUN'; E = { ($_.physicallocation -split 'LUN ')[1] } },
            CanPool, @{n = 'SizeGB'; E = { $_.Size / 1GB } }, UniqueID | sort LUN

        $MyDisks = $AvailableDisks | ? { $_.LUN -in $Luns }
        if ($MyDisks) {
            # If there are disks to pool from the list that was requested, need to run setscript
            return $False
        }
        else {
            if (Get-VirtualDisk -FriendlyName $FriendlyName  -ErrorAction Ignore) {

                if (Get-Volume -DriveLetter $DriveLetter -ErrorAction Ignore) {
                    return $True
                }
                else {
                    return $False
                }
            }
            else {
                return $False
            }
        }
    }
    else {
        if (Get-PhysicalDisk | ? CanPool -EQ $True) {
            return $False
        }
        else {
            write-warning -Message "There are no disks to pool"
            return $True
        }
    }
}

Export-ModuleMember -Function *-TargetResource

