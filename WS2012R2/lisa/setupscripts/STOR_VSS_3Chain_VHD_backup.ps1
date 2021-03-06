########################################################################
#
# Linux on Hyper-V and Azure Test Code, ver. 1.0.0
# Copyright (c) Microsoft Corporation
#
# All rights reserved. 
# Licensed under the Apache License, Version 2.0 (the ""License"");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0  
#
# THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
# OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
# ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR
# PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.
#
# See the Apache Version 2.0 License for specific language governing
# permissions and limitations under the License.
#
########################################################################

<#
.Synopsis
    This script tests VSS backup functionality.

.Description
    This script will create a new VM with a 3-chained differencing disk 
    attached based on the source vm vhd/x. 
    If the source Vm has more than 1 snapshot, they will be removed except
    the latest one. If the VM has no snapshots, the script will create one.
    After that it will proceed with backup/restore operation. 
    
    It uses a second partition as target. 

    Note: The script has to be run on the host. A second partition
    different from the Hyper-V one has to be available. 

    <test>
        <testName>VSS_BackupRestore_3Chain_VHD</testName>
        <testScript>setupscripts\VSS_3Chain_VHD_backup.ps1</testScript> 
        <testParams>
            <param>driveletter=F:</param>
        </testParams>
        <timeout>1200</timeout>
        <OnError>Continue</OnError>
    </test>

.Parameter vmName
    Name of the VM to remove disk from .

.Parameter hvServer
    Name of the Hyper-V server hosting the VM.

.Parameter testParams
    Test data for this test case

.Example
    setupScripts\VSS_3Chain_VHD_backup.ps1 -hvServer localhost -vmName NameOfVm -testParams 'sshKey=path/to/ssh;rootdir=path/to/testdir;ipv4=ipaddress;driveletter=D:'

#>

param([string] $vmName, [string] $hvServer, [string] $testParams)

#######################################################################
# Runs a remote script on the VM an returns the log.
#######################################################################
function RunRemoteScript($remoteScript)
{
    $retValue = $False
    $stateFile     = "state.txt"
    $TestCompleted = "TestCompleted"
    $TestAborted   = "TestAborted"
    $TestRunning   = "TestRunning"
    $timeout       = 6000    

    "./${remoteScript} > ${remoteScript}.log" | out-file -encoding ASCII -filepath runtest.sh 

    .\bin\pscp -i ssh\${sshKey} .\runtest.sh root@${ipv4}:
    if (-not $?)
    {
       Write-Output "ERROR: Unable to copy runtest.sh to the VM"
       return $False
    }      

     .\bin\pscp -i ssh\${sshKey} .\remote-scripts\ica\${remoteScript} root@${ipv4}:
    if (-not $?)
    {
       Write-Output "ERROR: Unable to copy ${remoteScript} to the VM"
       return $False
    }

    .\bin\plink.exe -i ssh\${sshKey} root@${ipv4} "dos2unix ${remoteScript} 2> /dev/null"
    if (-not $?)
    {
        Write-Output "ERROR: Unable to run dos2unix on ${remoteScript}"
        return $False
    }

    .\bin\plink.exe -i ssh\${sshKey} root@${ipv4} "dos2unix runtest.sh  2> /dev/null"
    if (-not $?)
    {
        Write-Output "ERROR: Unable to run dos2unix on runtest.sh" 
        return $False
    }
    
    .\bin\plink.exe -i ssh\${sshKey} root@${ipv4} "chmod +x ${remoteScript}   2> /dev/null"
    if (-not $?)
    {
        Write-Output "ERROR: Unable to chmod +x ${remoteScript}" 
        return $False
    }
    .\bin\plink.exe -i ssh\${sshKey} root@${ipv4} "chmod +x runtest.sh  2> /dev/null"
    if (-not $?)
    {
        Write-Output "ERROR: Unable to chmod +x runtest.sh " -
        return $False
    }

    # Run the script on the vm
    .\bin\plink.exe -i ssh\${sshKey} root@${ipv4} "./runtest.sh"
    
    # Return the state file
    while ($timeout -ne 0 )
    {
    .\bin\pscp -q -i ssh\${sshKey} root@${ipv4}:${stateFile} . #| out-null
    $sts = $?
    if ($sts)
    {
        if (test-path $stateFile)
        {
            $contents = Get-Content -Path $stateFile
            if ($null -ne $contents)
            {
                    if ($contents -eq $TestCompleted)
                    {                    
                        Write-Output "Info : state file contains Testcompleted"              
                        $retValue = $True
                        break                                             
                                     
                    }

                    if ($contents -eq $TestAborted)
                    {
                         Write-Output "Info : State file contains TestAborted failed. "                                  
                         break
                          
                    }
                    #Start-Sleep -s 1
                    $timeout-- 

                    if ($timeout -eq 0)
                    {                        
                        Write-Output "Error : Timed out on Test Running , Exiting test execution."                    
                        break                                               
                    }                                
                  
            }    
            else
            {
                Write-Output "Warn : state file is empty"
                break
            }
           
        }
        else
        {
             Write-Host "Warn : ssh reported success, but state file was not copied"
             break
        }
    }
    else #
    {
         Write-Output "Error : pscp exit status = $sts"
         Write-Output "Error : unable to pull state.txt from VM." 
         break
    }     
    }

    # Get the logs
    $remoteScriptLog = $remoteScript+".log"
    
    bin\pscp -q -i ssh\${sshKey} root@${ipv4}:${remoteScriptLog} . 
    $sts = $?
    if ($sts)
    {
        if (test-path $remoteScriptLog)
        {
            $contents = Get-Content -Path $remoteScriptLog
            if ($null -ne $contents)
            {
                    if ($null -ne ${TestLogDir})
                    {
                        move "${remoteScriptLog}" "${TestLogDir}\${remoteScriptLog}"
                
                    }

                    else 
                    {
                        Write-Output "INFO: $remoteScriptLog is copied in ${rootDir}"                                
                    }                              
                  
            }    
            else
            {
                Write-Output "Warn: $remoteScriptLog is empty"                
            }           
        }
        else
        {
             Write-Output "Warn: ssh reported success, but $remoteScriptLog file was not copied"             
        }
    }
    
    # Cleanup 
    del state.txt -ErrorAction "SilentlyContinue"
    del runtest.sh -ErrorAction "SilentlyContinue"

    return $retValue
}

#######################################################################
# Check boot.msg in Linux VM for Recovering journal. 
#######################################################################
function CheckRecoveringJ()
{
    $retValue = $False
       
    echo y | .\bin\pscp -i ssh\${sshKey} root@${ipv4}:/var/log/boot.* ./boot.msg 

    if (-not $?)
    {
      Write-Output "ERROR: Unable to copy boot.msg from the VM"
       return $False
    }

    $filename = ".\boot.msg"
    $text = "recovering journal"
    
    $file = Get-Content $filename
    if (-not $file)
    {
        Write-Error -Message "Unable to read file" -Category InvalidArgument -ErrorAction SilentlyContinue
        return $null
    }

     foreach ($line in $file)
    {
        if ($line -match $text)
        {           
            $retValue = $True 
            Write-Output "$line"          
        }             
    }

    del $filename
    return $retValue    
}

#######################################################################
# Fix snapshots. If there are more then 1 remove all except latest.
#######################################################################
function FixSnapshots($vmName, $hvServer)
{
    # Get all the snapshots
    $vmsnapshots = Get-VMSnapshot -VMName $vmName
    $snapnumber = ${vmsnapshots}.count

    # Get latest snapshot
    $latestsnapshot = Get-VMSnapshot -VMName $vmName | sort CreationTime | select -Last 1
    $LastestSnapName = $latestsnapshot.name
    
    # Delete all snapshots except the latest
    if ($snapnumber -gt 1)
    {
        Write-Output "INFO: $vmName has $snapnumber snapshots. Removing all except $LastestSnapName"
        foreach ($snap in $vmsnapshots) 
        {
            if ($snap.id -ne $latestsnapshot.id)
            {
                $snapName = ${snap}.Name
                $sts = Remove-VMSnapshot -Name $snap.Name -VMName $vmName -ComputerName $hvServer
                if (-not $?)
                {
                    Write-Output "ERROR: Unable to remove snapshot $snapName of ${vmName}: `n${sts}"
                    return $False
                }
                Write-Output "INFO: Removed snapshot $snapName"
            }

        }
    }

    # If there are no snapshots, create one.
    ElseIf ($snapnumber -eq 0)
    {
        Write-Output "INFO: There are no snapshots for $vmName. Creating one ..."
        $sts = Checkpoint-VM -VMName $vmName -ComputerName $hvServer 
        if (-not $?)
        {
           Write-Output "ERROR: Unable to create snapshot of ${vmName}: `n${sts}"
           return $False
        }

    }

    return $True
}

#######################################################################
# To Get Parent VHD from VM.
#######################################################################
function GetParentVHD($vmName, $hvServer)
{
    $ParentVHD = $null     

    $VmInfo = Get-VM -Name $vmName 
    if (-not $VmInfo)
        { 
             Write-Error -Message "Error: Unable to collect VM settings for ${vmName}" -ErrorAction SilentlyContinue
             return $False
        }    
    
    if ( $VmInfo.Generation -eq "" -or $VmInfo.Generation -eq 1  )
        {
            $Disks = $VmInfo.HardDrives
            foreach ($VHD in $Disks)
                {
                    if ( ($VHD.ControllerLocation -eq 0 ) -and ($VHD.ControllerType -eq "IDE"  ))
                        {
                            $Path = Get-VHD $VHD.Path
                            if ([string]::IsNullOrEmpty($Path.ParentPath))
                                {
                                    $ParentVHD = $VHD.Path
                                }
                            else{
                                    $ParentVHD =  $Path.ParentPath
                                }

                            Write-Host "Parent VHD Found: $ParentVHD "
                        }
                }            
        }
    if ( $VmInfo.Generation -eq 2 )
        {
            $Disks = $VmInfo.HardDrives
            foreach ($VHD in $Disks)
                {
                    if ( ($VHD.ControllerLocation -eq 0 ) -and ($VHD.ControllerType -eq "SCSI"  ))
                        {
                            $Path = Get-VHD $VHD.Path
                            if ([string]::IsNullOrEmpty($Path.ParentPath))
                                {
                                    $ParentVHD = $VHD.Path
                                }
                            else{
                                    $ParentVHD =  $Path.ParentPath
                                }
                            Write-Host "Parent VHD Found: $ParentVHD "
                        }
                }  
        }

    if ( -not ($ParentVHD.EndsWith(".vhd") -xor $ParentVHD.EndsWith(".vhdx") ))
    {
         Write-Error -Message " Parent VHD is Not correct please check VHD, Parent VHD is: $ParentVHD " -ErrorAction SilentlyContinue
         return $False
    }

    return $ParentVHD    

}

#######################################################################
# To Create Grand Child VHD from Parent VHD.
#######################################################################
function CreateGChildVHD($ParentVHD)
{

    $GChildVHD = $null
    $ChildVHD  = $null

    $hostInfo = Get-VMHost -ComputerName $hvServer
        if (-not $hostInfo)
        {
             Write-Error -Message "Error: Unable to collect Hyper-V settings for ${hvServer}" -ErrorAction SilentlyContinue
             return $False
        }

    $defaultVhdPath = $hostInfo.VirtualHardDiskPath
        if (-not $defaultVhdPath.EndsWith("\"))
        {
            $defaultVhdPath += "\"
        }

    # Create Child VHD

    if ($ParentVHD.EndsWith("x") )
    {
        $ChildVHD = $defaultVhdPath+$vmName+"-child.vhdx"
        $GChildVHD = $defaultVhdPath+$vmName+"-Gchild.vhdx"

    }
    else
    {
        $ChildVHD = $defaultVhdPath+$vmName+"-child.vhd"
        $GChildVHD = $defaultVhdPath+$vmName+"-Gchild.vhd"
    }

    if ( Test-Path  $ChildVHD )
    {
        Write-Host "Deleting existing VHD $ChildVHD"        
        del $ChildVHD
    }

     if ( Test-Path  $GChildVHD )
    {
        Write-Host "Deleting existing VHD $GChildVHD"        
        del $GChildVHD
    }

     # Create Child VHD  

    New-VHD -ParentPath:$ParentVHD -Path:$ChildVHD     
    if (-not $?)
    {
       Write-Error -Message "Error: Unable to create child VHD"  -ErrorAction SilentlyContinue
       return $False
    }

     # Create Grand Child VHD    
    
    $newVHD = New-VHD -ParentPath:$ChildVHD -Path:$GChildVHD
    if (-not $?)
    {
       Write-Error -Message "Error: Unable to create Grand child VHD" -ErrorAction SilentlyContinue
       return $False
    }

    return $GChildVHD    

}

#######################################################################
#
# Main script body
#
#######################################################################

$retVal = $false

$summaryLog  = "${vmName}_summary.log"

echo "Covers: VSS Backup 3 Chain VHD " >> $summaryLog

Write-Output "Removing old backups"
try { Remove-WBBackupSet -Force -WarningAction SilentlyContinue }
Catch { Write-Output "No existing backup's to remove"}

# Check input arguments
if ($vmName -eq $null)
{
    Write-Output "Error: VM name is null"
    return $retVal
}

if ($hvServer -eq $null)
{
    Write-Output "Error: hvServer is null"
    return $retVal
}

$vm2Name = $null

$params = $testParams.Split(";")

foreach ($p in $params)
{
  $fields = $p.Split("=")
    
  switch ($fields[0].Trim())
    {
    "sshKey" { $sshKey  = $fields[1].Trim() }
    "ipv4"   { $ipv4    = $fields[1].Trim() }
    "rootDir" { $rootDir = $fields[1].Trim() }
    "driveletter" { $driveletter = $fields[1].Trim() }
     default  {}          
    }
}

if ($null -eq $sshKey)
{
    Write-Output "ERROR: Test parameter sshKey was not specified"
    return $False
}

if ($null -eq $ipv4)
{
    Write-Output "ERROR: Test parameter ipv4 was not specified"
    return $False
}

if ($null -eq $driveletter)
{
    Write-Output "ERROR: Test parameter driveletter was not specified."
    return $False
}

# Change the working directory to where we need to be
if (-not (Test-Path $rootDir))
{
    Write-Output "Error: The directory `"${rootDir}`" does not exist"
    return $False
}

$vmName1 = "${vmName}_ChildVM"

cd $rootDir

# Source the TCUtils.ps1 file
. .\setupscripts\TCUtils.ps1

# Check if the Vm VHD in not on the same drive as the backup destination 
$vm = Get-VM -Name $vmName -ComputerName $hvServer
if (-not $vm)
{
    "Error: VM '${vmName}' does not exist"
    return $False
}
 
foreach ($drive in $vm.HardDrives)
{
    if ( $drive.Path.StartsWith("${driveLetter}"))
    {
        "Error: Backup partition '${driveLetter}' is same as partition hosting the VMs disk"
        "       $($drive.Path)"
        return $False
    }
}

# Check to see Linux VM is running VSS backup daemon 
$sts = RunRemoteScript "STOR_VSS_Check_VSS_Daemon.sh"
if (-not $sts[-1])
{
    Write-Output "ERROR executing $remoteScript on VM. Exiting test case!" >> $summaryLog
    Write-Output "ERROR: Running $remoteScript script failed on VM!"
    return $False
}

Write-Output "VSS Daemon is running " >> $summaryLog

# Stop the running VM so we can create New VM from this parent disk.
# Shutdown gracefully so we dont corrupt VHD.
Stop-VM -Name $vmName 
if (-not $?)
    {
       Write-Output "Error: Unable to Shut Down VM" 
       return $False
    }

echo "after stop vm" >> $summaryLog

# Add Check to make sure if the VM is shutdown then Proceed
$timeout = 50
$sts = WaitForVMToStop $vmName $hvServer $timeout
if (-not $sts)
    {
       Write-Output "Error: Unable to Shut Down VM"
       return $False
    }

# Clean snapshots
Write-Output "INFO: Cleaning up snapshots..."
$sts = FixSnapshots $vmName $hvServer
if (-not $sts[-1])
{
    Write-Output "Error: Cleaning snapshots on $vmname failed."
    return $False
}

# Get Parent VHD 
echo "after stopped vm " >> $summaryLog
$ParentVHD = GetParentVHD $vmName -$hvServer
if(-not $ParentVHD)
{
    "Error: Error getting Parent VHD of VM $vmName"
    return $False
} 

Write-Output "INFO: Successfully Got Parent VHD"
echo "get parent vhd " >> $summaryLog

# Creat Child and Grand Child VHD .
$CreateVHD = CreateGChildVHD $ParentVHD
if(-not $CreateVHD)
{
    Write-Output "Error: Error Creating Child and Grand Child VHD of VM $vmName"
    return $False
} 

Write-Output "INFO: Successfully Created GrandChild VHD"

# Now create New VM out of this VHD.
# New VM is static hardcoded since we do not need it to be dynamic
$GChildVHD = $CreateVHD[-1]

# Get-VM 
$vm = Get-VM -Name $vmName -ComputerName $hvServer

# Get the VM Network adapter so we can attach it to the new vm.
$VMNetAdapter = Get-VMNetworkAdapter $vmName
if (-not $?)
    {
       Write-Output "Error: Get-VMNetworkAdapter" 
       return $false
    }

#Get VM Generation
$vm_gen = $vm.Generation

# Create the GChildVM
$newVm = New-VM -Name $vmName1 -VHDPath $GChildVHD -MemoryStartupBytes 1024MB -SwitchName $VMNetAdapter[0].SwitchName -Generation $vm_gen
if (-not $?)
    {
       Write-Output "Error: Creating New VM" 
       return $False
    }

# Disable secure boot
if ($vm_gen -eq 2)
{
    Set-VMFirmware -VMName $vmName1 -EnableSecureBoot Off
    if(-not $?)
    {
        Write-Output "Error: Unable to disable secure boot"
        return $false
    }
}

echo "New 3 Chain VHD VM $vmName1 Created: Success" >> $summaryLog
Write-Output "INFO: New 3 Chain VHD VM $vmName1 Created"

$timeout = 500
$sts = Start-VM -Name $vmName1 -ComputerName $hvServer 
if (-not (WaitForVMToStartKVP $vmName1 $hvServer $timeout ))
{
    Write-Output "Error: ${vmName1} failed to start"
     return $False
}

Write-Output "INFO: New VM $vmName1 started"

# Install the Windows Backup feature
Write-Output "INFO: Checking if the Windows Server Backup feature is installed..."
try { Add-WindowsFeature -Name Windows-Server-Backup -IncludeAllSubFeature:$true -Restart:$false }
Catch { Write-Output "Windows Server Backup feature is already installed, no actions required."}

echo "`n"
# Remove Existing Backup Policy
try { Remove-WBPolicy -all -force }
Catch { Write-Output "No existing backup policy to remove"}

echo "`n"
# Set up a new Backup Policy
$policy = New-WBPolicy

# Set the backup backup location
$backupLocation = New-WBBackupTarget -VolumePath $driveletter

# Define VSS WBBackup type
Set-WBVssBackupOptions -Policy $policy -VssCopyBackup

# Add the Virtual machines to the list
$VMtoBackup = Get-WBVirtualMachine | where vmname -like $vmName1
Add-WBVirtualMachine -Policy $policy -VirtualMachine $VMtoBackup
Add-WBBackupTarget -Policy $policy -Target $backupLocation

# Display the Backup policy
Write-Output "Backup policy is: `n$policy"

# Start the backup
Write-Output "Backing to $driveletter"
Start-WBBackup -Policy $policy

# Review the results            
$BackupTime = (New-Timespan -Start (Get-WBJob -Previous 1).StartTime -End (Get-WBJob -Previous 1).EndTime).Minutes
Write-Output "Backup duration: $BackupTime minutes"           
"Backup duration: $BackupTime minutes" >> $summaryLog

$sts=Get-WBJob -Previous 1
if ($sts.JobState -ne "Completed" -or $sts.HResult -ne 0)
{
    Write-Output "ERROR: VSS Backup failed"
    Write-Output $sts.ErrorDescription
    $retVal = $false
    return $retVal
}

Write-Output "`nBackup success!`n"
# Let's wait a few Seconds
Start-Sleep -Seconds 30

# Start the Restore
Write-Output "`nNow let's do restore ...`n"

# Get BackupSet
$BackupSet=Get-WBBackupSet -BackupTarget $backupLocation

# Start Restore
Start-WBHyperVRecovery -BackupSet $BackupSet -VMInBackup $BackupSet.Application[0].Component[0] -Force -WarningAction SilentlyContinue
$sts=Get-WBJob -Previous 1
if ($sts.JobState -ne "Completed" -or $sts.HResult -ne 0)
{
    Write-Output "ERROR: VSS Restore failed"
    Write-Output $sts.ErrorDescription
    $retVal = $false
    return $retVal
}

# Review the results  
$RestoreTime = (New-Timespan -Start (Get-WBJob -Previous 1).StartTime -End (Get-WBJob -Previous 1).EndTime).Minutes
Write-Output "Restore duration: $RestoreTime minutes"
"Restore duration: $RestoreTime minutes" >> $summaryLog

# Make sure VM exist after VSS backup/restore operation 
$vm = Get-VM -Name $vmName1 -ComputerName $hvServer
    if (-not $vm)
    {
        Write-Output "ERROR: VM ${vmName1} does not exist after restore"
        return $False
    }
Write-Output "Restore success!"

# After Backup Restore VM must be off make sure that.
if ( $vm.state -ne "Off" )  
{
    Write-Output "ERROR: VM is not in OFF state, current state is " + $vm.state
    return $False
}

# Now Start the VM
$timeout = 300
$sts = Start-VM -Name $vmName1 -ComputerName $hvServer 
if (-not (WaitForVMToStartKVP $vmName1 $hvServer $timeout ))
{
    Write-Output "ERROR: ${vmName1} failed to start"
    return $False
}
else
{
    Write-Output "INFO: Started VM ${vmName1}"
}

# Get new IPV4
$ipv4 =  GetIPv4 $vmName1 $hvServer
if (-not $?)
    {
       Write-Output "Error: Getting IPV4 of New VM"
       return $False
    }

Write-Output "INFO: New VM's IP is $ipv4" 

# Now Check the boot logs in VM to verify if there is no Recovering journals in it . 
$recovery=CheckRecoveringJ $ipv4
if ($recovery[-1])
{
    Write-Output "ERROR: Recovering Journals in Boot log file, VSS backup/restore failed!"
    Write-Output "No Recovering Journal in boot logs: Failed" >> $summaryLog
    return $False
}
else 
{
    $results = "Passed"
    $retVal = $True
    Write-Output "`nINFO: VSS Back/Restore: Success"   
    Write-Output "No Recovering Journal in boot msg: Success" >> $summaryLog
}

Write-Output "INFO: Test ${results}"

$sts = Stop-VM -Name $vmName1 -TurnOff
if (-not $?)
    {
       Write-Output "Error: Unable to Shut Down VM $vmName1" 
       
    }

# Remove Existing Backups
Write-Output "Removing old backups from $backupLocation"
try { Remove-WBBackupSet -BackupTarget $backupLocation -Force -WarningAction SilentlyContinue }
Catch { Write-Output "No existing backup's to remove"}

# Clean Delete New VM created 
$sts = Remove-VM -Name $vmName1 -Confirm:$false -Force
if (-not $?)
    {
      Write-Output "Error: Deleting New VM $vmName1"  
    } 

Write-Output "INFO: Deleted VM $vmName1"

if ($recovery[-1])
{
    return $false
}

return $retVal
