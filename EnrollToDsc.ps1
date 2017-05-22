function executePsRemoteCommand($command, $machine, $credenital, $elevated)
{
    $script = {
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo -ArgumentList 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe'
        $pinfo.RedirectStandardError = $true
        $pinfo.RedirectStandardOutput = $true
        #$command = 'Set-DscLocalConfigurationManager -Path C:\DscLcm -Verbose -ComputerName localhost'
        $commandEncoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Using:command))
        $pinfo.Arguments = '-NoProfile -NonInteractive -EncodedCommand {0}' -f $commandEncoded
        $pinfo.WindowStyle = 'Hidden'
        if ($elevated) {
            $pinfo.Verb = "runas"
        }
        $pinfo.UseShellExecute = $false
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $pinfo
        $p.Start() | Out-Null
        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        New-Object -TypeName Hashtable @{"output"=$stdout+$stderr;"stderr"=$stderr;"exit_code"=[string]$p.ExitCode}
    }

    $remotePsSession = New-PSSession -ComputerName $machine -Credential $credential -EnableNetworkAccess
    $output = Invoke-Command -Session $remotePsSession -ScriptBlock $script
    Remove-PSSession -Session $remotePsSession

    return $output
}

function isDscEnrolledMachine ($machine, $credential)
{
            $command = '$(Get-DscLocalConfigurationManager).RefreshMode'
            $output = executePsRemoteCommand -command $command -machine $machine -credential $credential -elevated $true

            if ($output.exit_code -like "0") {
                if ($output.output -like "*Pull*") {
                    Write-Host "Machine enrolled with DSC Pull Server"
                    return $true
                }
                elseif ($output.output -like "*PUSH*") {
                    Write-Host "Machine not enrolled with DSC Pull Server"
                    return $false
                }
            }

}

function enrollToDsc($os, $machine, $credential, $server)
{
    $enrollmentStatus = ""
    $dscLcms = @{
        "Microsoft Windows Server 2012 (64-bit) WMF4" = "\\fileshare\DSC\LCM\localhostWMF4.meta.mof"
        "Microsoft Windows Server 2012 (64-bit) WMF5" = "\\fileshare\DSC\LCM\localhostWMF5.meta.mof"
    }

    if ($dscLcms.$os) {
        $LcmRemotePath = $dscLcms.$os

        Write-host "LCM found, applying it."
        $machine = $machine.Guest.HostName

        Write-Host "Checking if machine is already DSC-enrolled"
        $dscEnrolled = isDscEnrolledMachine -machine $machine -credential $credential
        if ($dscEnrolled) {
            $enrollmentStatus = "Already enrolled"
        }
        else {

            Write-Host "Creating DscLcm folder"
            $command = "New-Item -Type Directory -Path C:\DscLcm -Force"
            $output = executePsRemoteCommand -command $command -machine $machine -credential $credential -elevated $false
            Write-host $output.output
            if ($output.exit_code -notlike "0") {
                $enrollmentStatus = "Failure"
            }

            Write-Host "Copying MOF files to session"
            Copy-Item -ToSession $remotePsSession -Path $($LcmRemotePath) -Destination "C:\DscLcm\localhost.meta.mof" -Recurse

            $command = 'Set-DscLocalConfigurationManager -Path C:\DscLcm -Verbose -ComputerName localhost'
            $output = executePsRemoteCommand -command $command -machine $machine -credential $credential -elevated $true
            Write-host $output.output
            if ($output.exit_code -notlike "0") {
                $enrollmentStatus = "Failure"
            }


            $command = "Update-DscConfiguration"
            $output = executePsRemoteCommand -command $command -machine $machine -credential $credential -elevated $false
            Write-host $output.output
            if ($output.exit_code -notlike "0") {
                $enrollmentStatus = "Failure"
            } else {
                $enrollmentStatus = "Success"
            }

            foreach ($session in $(Get-PSSession)) {Remove-PSSession -Id $session.id}
        }

    }
    else {
        Write-Host "LCM not found"
    }

    return $enrollmentStatus

}

function main
{
    param(
        [string]$ViServer,
        $Credential = (Get-Credential)
    )

    Get-Module -ListAvailable VMWare* | Import-Module

    Write-Host "Connecting to vSphere"
    $server = Connect-VIServer -Server $ViServer -Protocol https -Credential $Credential | Out-Null

    Write-Host "Getting Windows powered on machines"

    # be carefule here, it gets all powered-on Win machines
    $allVms = Get-Vm | Where-Object { $_.PowerState -eq "PoweredOn" -and $_.ExtensionData.Guest.GuestFullName -like "*win*" }

    $EnrolledVms = @()
    $EnrollFailedVms = @()
    $EnrollExistedVms = @()

    foreach ($vm in $allVms) {

        Write-Host $Vm.Name
        $vmGuestName = $(Get-VMGuest -VM $vm).OSFullName

        $remotePsSession = ""
        if (-Not $remotePsSession) {
            $remotePsSession = New-PSSession -ComputerName $Vm.Guest.HostName -Credential $credential
        }
        $command = {$($PSVersionTable.PSVersion.Major) 4>&1}
        $psVersion = Invoke-Command -Session $remotePsSession -ScriptBlock $command

        if ($psVersion -like "*4*") {
            $vmGuestName = $vmGuestName + " WMF4"
        }

        if ($psVersion -like "*5*") {
            $vmGuestName = $vmGuestName + " WMF5"
        }

        Write-Host "Enrolling to DSC for: $($Vm.Name)"
        $enrollmentStatus = enrollToDsc -os $vmGuestName -machine $Vm -credential $Credential -server $server
        Write-Host "Machine $($Vm.Name) enrolled with status: $enrollmentStatus"
        if ($enrollmentStatus -like "Success") { $EnrolledVms += $Vm.Name }
        if ($enrollmentStatus -like "Failure") { $EnrollFailedVms += $Vm.Name }
        if ($enrollmentStatus -like "Already enrolled") { $EnrollExistedVms += $Vm.Name }
    }

    Write-Host "---------------------"
    Write-Host "Enrolled successfully"
    Write-Host "$EnrolledVms"
    Write-Host "-------------------------"
    Write-Host "Already enrolled with DSC"
    Write-Host "$EnrollExistedVms"
    Write-Host "-----------------"
    Write-Host "Enrollment failed"
    Write-Host "$EnrollFailedVms"

}
