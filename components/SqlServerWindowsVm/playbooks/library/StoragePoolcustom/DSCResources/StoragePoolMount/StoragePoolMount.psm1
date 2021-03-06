function Get-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $FriendlyName,

        [parameter(Mandatory = $true)]
        [System.String]
        $AccessPath,

        [parameter(Mandatory = $true)]
        [System.UInt16[]]
        $LUNS
    )


    Write-Warning -Message "Checking for StoragePool $FriendlyName"
    #Get-StoragePool -FriendlyName $Pool.FriendlyName -ErrorAction SilentlyContinue

    $storageSS = Get-StorageSubSystem -ErrorAction Ignore
    $AvailableDisks = Get-PhysicalDisk -ErrorAction Ignore | ? CanPool -EQ $True |
                        Select @{n='LUN';E={($_.physicallocation -split 'LUN ')[1]}},
                        CanPool,@{n='SizeGB';E={$_.Size/1GB}},UniqueID | sort LUN

    $MyDisks = $AvailableDisks | ? {$_.LUN -in $Luns} | Select LUN,CanPool

    $returnValue = @{
    FriendlyName = $FriendlyName
    AccessPath  = $AccessPath
    LUNS         = $MyDisks

    Ensure = $Ensure
    }

    $returnValue

}


function Set-TargetResource
{
    [CmdletBinding()]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $FriendlyName,

        [parameter(Mandatory = $true)]
        [System.String]
        $AccessPath,

        [parameter(Mandatory = $true)]
        [System.UInt16[]]
        $LUNS,

        [ValidateSet("Present","Absent")]
        [System.String]
        $Ensure,

        [System.UInt16]
        $ColumnCount = 0

    )

        Write-Warning -Message "Running Set"

        $storageSS = Get-StorageSubSystem -ErrorAction Ignore
        $AvailableDisks = Get-PhysicalDisk -ErrorAction Ignore | ? CanPool -EQ $True |
                            Select @{n='LUN';E={($_.physicallocation -split 'LUN ')[1]}},
                            CanPool,@{n='SizeGB';E={$_.Size/1GB}},UniqueID | sort LUN

        $MyDisks = $AvailableDisks | ? {$_.LUN -in $LUNS}
        if ($MyDisks)
        {
            $MyPhysicalDisks = Get-PhysicalDisk -ErrorAction Ignore | 
                Where {$_.CanPool -EQ $True -and $_.UniqueID -in $MyDisks.UniqueID}
        }

        # Create the storage pool if it doesn't exist.
        $SP = Get-StoragePool -FriendlyName $FriendlyName -ErrorAction Ignore
        if (! $SP)
        {
            $SP = New-StoragePool -PhysicalDisks $MyPhysicalDisks -FriendlyName $FriendlyName -StorageSubSystemFriendlyName $storageSS.FriendlyName -ErrorAction Ignore
            Remove-Variable -Name storageSS -ErrorAction Ignore
        }
                    
        if ($SP)
        {
            # Create VirtualDisk if it doesn't exist.
            $VD = Get-VirtualDisk -FriendlyName $SP.FriendlyName -ErrorAction Ignore
            if (! $VD)
            {
                Stop-Service -Name ShellHWDetection -erroraction ignore
                if ($ColumnCount -gt 0)
                {
                    $VD = New-VirtualDisk -ResiliencySettingName Simple -StoragePoolFriendlyName $SP.FriendlyName -FriendlyName $SP.FriendlyName -ProvisioningType Fixed -UseMaximumSize -NumberOfColumns $ColumnCount -ErrorAction Ignore
                }
                else
                {
                    $VD = New-VirtualDisk -ResiliencySettingName Simple -StoragePoolFriendlyName $SP.FriendlyName -FriendlyName $SP.FriendlyName -ProvisioningType Fixed -UseMaximumSize -ErrorAction Ignore
                }
            }
                        
            if ($VD)
            {
                $Vol = Get-Volume -StoragePool $SP -ErrorAction Ignore
                if (! $Vol)
                {
                    #-------------

                    if (-Not (Test-Path -Path $AccessPath))
                    {
                        MkDir $AccessPath -Force
                    }

                    $init = $VD | Initialize-Disk -PartitionStyle GPT -ErrorAction Ignore

                    $Partition = $VD | Get-Disk | New-Partition -UseMaximumSize

                    $Access = $VD | Get-Disk | Get-Partition -PartitionNumber 2 | Add-PartitionAccessPath -AccessPath $AccessPath

                    $Volume = $VD | Get-Disk | Get-Partition -PartitionNumber 2 | Get-Volume | Format-Volume -FileSystem NTFS -AllocationUnitSize 64KB -NewFileSystemLabel $SP.FriendlyName

                    #-------------
                }
                elseif ($MyPhysicalDisks)
                {
                    $pd = Get-StoragePool -FriendlyName $FriendlyName -ErrorAction Ignore | Add-PhysicalDisk -PhysicalDisks $MyPhysicalDisks -Usage AutoSelect -ErrorAction Ignore
                }
                        
            }                            

            else
            {
                Write-Warning -Message "Could not create virtual disk $Friendlyname"
            }                        
                        
        }
        else
        {
            Write-Warning -Message "Could not create storage pool $Friendlyname"
        }
				

}


function Test-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $FriendlyName,

        [parameter(Mandatory = $true)]
        [System.String]
        $AccessPath,

        [parameter(Mandatory = $true)]
        [System.UInt16[]]
        $LUNS,

        [ValidateSet("Present","Absent")]
        [System.String]
        $Ensure,

        [System.UInt16]
        $ColumnCount = 0
    )

        if (Get-StoragePool -FriendlyName $FriendlyName -ErrorAction Ignore)
        {
            $AvailableDisks = Get-PhysicalDisk | ? CanPool -EQ $True |
                            Select @{n='LUN';E={($_.physicallocation -split 'LUN ')[1]}},
                            CanPool,@{n='SizeGB';E={$_.Size/1GB}},UniqueID | sort LUN

            $MyDisks = $AvailableDisks | ? {$_.LUN -in $Luns}
            if ($MyDisks)
            {
                # If there are disks to pool from the list that was requested, need to run setscript
                $False
            }
            else
            {
                if (Get-VirtualDisk -FriendlyName $FriendlyName  -ErrorAction Ignore -OutVariable VD)
                {
                                
                    if ($VD | Get-Disk | Get-Partition -PartitionNumber 2 | Get-Volume)
                    {
                        $True
                    }
                    else
                    {
                        $False
                    }
                }
                else
                {
                    $False
                }
            }
        }
        else
        {
            if (Get-PhysicalDisk | ? CanPool -EQ $True)
            {
                $False
            }
            else
            {
                write-warning -Message "There are no disks to pool"
            }
                        
        }
}


Export-ModuleMember -Function *-TargetResource

