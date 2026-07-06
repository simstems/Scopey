<#
.SYNOPSIS
  Scopey - a cartoony DHCP scope helper for Windows DHCP admins.

.DESCRIPTION
  Scopey manages common IPv4 Microsoft DHCP Server tasks from an admin workstation
  or directly from the DHCP server. It uses the DhcpServer PowerShell module and
  supports a remote DHCP server through the -DhcpServer parameter.

.PARAMETER DhcpServer
  DHCP server to manage. Defaults to the local computer.

.PARAMETER Credential
  Optional credential used for DHCP Server cmdlets that support -Credential.

.EXAMPLE
  .\Scopey.ps1 -DhcpServer DHCP01

.EXAMPLE
  .\Scopey.ps1 -DhcpServer DHCP01 -Credential (Get-Credential)

.NOTES
  Forked from DHCP_Scope_Manager by Flemming Sørvollen Skaret.
  Scopey modernization adds remote server targeting and cleaner command wrapping.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$DhcpServer = $env:COMPUTERNAME,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:FirstRun = $true
$script:SelectedScope = $null
$script:SelectedScopeId = $null

function Import-ScopeyDhcpModule {
    try {
        Import-Module DhcpServer -ErrorAction Stop
    }
    catch {
        Write-Host 'ERROR: Unable to import the DhcpServer PowerShell module.' -ForegroundColor Red
        Write-Host 'Install RSAT DHCP tools on this workstation or run from a machine with the DHCP Server tools installed.' -ForegroundColor Yellow
        Read-Host 'Press ENTER to exit'
        exit 1
    }
}

function Invoke-ScopeyDhcpCommand {
    param(
        [Parameter(Mandatory)]
        [string]$CommandName,

        [Parameter()]
        [hashtable]$Parameters = @{}
    )

    $command = Get-Command -Name $CommandName -ErrorAction Stop
    $boundParameters = @{} + $Parameters

    if ($command.Parameters.ContainsKey('ComputerName')) {
        $boundParameters['ComputerName'] = $script:DhcpServer
    }

    if ($script:Credential -and $command.Parameters.ContainsKey('Credential')) {
        $boundParameters['Credential'] = $script:Credential
    }

    & $CommandName @boundParameters
}

function Set-ScopeyWindowTitle {
    $scopeText = if ($script:SelectedScopeId) { "[$($script:SelectedScopeId)] $($script:SelectedScope.Name)" } else { 'None selected' }
    $host.UI.RawUI.WindowTitle = "Scopey - DHCP Server: $($script:DhcpServer) - Selected Scope: $scopeText"
}

function Test-ScopeyDhcpServerConnection {
    try {
        Invoke-ScopeyDhcpCommand -CommandName Get-DhcpServerv4Scope -Parameters @{ ErrorAction = 'Stop' } | Out-Null
        Write-Host "Connected to DHCP server: $($script:DhcpServer)" -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: Unable to query DHCP server '$($script:DhcpServer)'." -ForegroundColor Red
        Write-Host 'Verify network reachability, permissions, firewall rules, and that the DHCP Server service/tools are available.' -ForegroundColor Yellow
        Write-Host "Details: $($_.Exception.Message)" -ForegroundColor DarkYellow
        Read-Host 'Press ENTER to exit'
        exit 1
    }
}

function Select-ScopeyScope {
    Write-Host ''
    Write-Host "Available scopes on $($script:DhcpServer):" -ForegroundColor Cyan

    try {
        Invoke-ScopeyDhcpCommand -CommandName Get-DhcpServerv4Scope |
            Select-Object ScopeId, Name, StartRange, EndRange, State |
            Format-Table -AutoSize
    }
    catch {
        Write-Host 'Unable to list scopes.' -ForegroundColor Red
    }

    $scopeInput = Read-Host 'Select ScopeID'

    try {
        $scope = Invoke-ScopeyDhcpCommand -CommandName Get-DhcpServerv4Scope -Parameters @{ ScopeId = $scopeInput }
        $stats = Invoke-ScopeyDhcpCommand -CommandName Get-DhcpServerv4ScopeStatistics -Parameters @{ ScopeId = $scopeInput }

        $script:SelectedScope = $scope
        $script:SelectedScopeId = $scope.ScopeId.IPAddressToString

        Write-Host "Scope [$($script:SelectedScopeId)] $($scope.Name) selected" -ForegroundColor Green
        Write-Host "IP Range: $($scope.StartRange.IPAddressToString) - $($scope.EndRange.IPAddressToString)" -ForegroundColor Yellow
        Write-Host "Subnet Mask: $($scope.SubnetMask.IPAddressToString)" -ForegroundColor Yellow
        Write-Host "Addresses in use: $($stats.AddressesInUse) - $($stats.PercentageInUse)%" -ForegroundColor Yellow
    }
    catch {
        Write-Host 'Unable to select scope.' -ForegroundColor Red
        $script:SelectedScope = $null
        $script:SelectedScopeId = $null
    }
    finally {
        Set-ScopeyWindowTitle
        if ($script:SelectedScopeId) { Show-ScopeyMenu } else { Select-ScopeyScope }
    }
}

function Invoke-ScopeyFailoverReplication {
    try {
        Invoke-ScopeyDhcpCommand -CommandName Invoke-DhcpServerv4FailoverReplication -Parameters @{
            ScopeId = $script:SelectedScopeId
            Force = $true
        } | Out-Null

        $failover = Invoke-ScopeyDhcpCommand -CommandName Get-DhcpServerv4Failover
        $partnerServer = ($failover | Select-Object -First 1).PartnerServer
        Write-Host "Scope $($script:SelectedScopeId) replicated successfully to failover partner $partnerServer" -ForegroundColor Green
    }
    catch {
        Write-Host 'An error occurred during replication.' -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor DarkYellow
    }
    finally { Show-ScopeyMenu }
}

function Show-ScopeyFreeIpAddresses {
    try {
        $stats = Invoke-ScopeyDhcpCommand -CommandName Get-DhcpServerv4ScopeStatistics -Parameters @{ ScopeId = $script:SelectedScopeId }

        if ($stats.Free -eq 0) {
            Write-Host 'There are no available IP addresses in this scope.' -ForegroundColor Yellow
        }
        else {
            Invoke-ScopeyDhcpCommand -CommandName Get-DhcpServerv4FreeIPAddress -Parameters @{
                ScopeId = $script:SelectedScopeId
                NumAddress = $stats.Free
            }
        }
    }
    catch {
        Write-Host 'An error occurred while listing free IP addresses.' -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor DarkYellow
    }
    finally { Show-ScopeyMenu }
}

function Show-ScopeyLeasesByState {
    param(
        [Parameter(Mandatory)]
        [string]$AddressState,

        [Parameter(Mandatory)]
        [string]$EmptyMessage
    )

    try {
        $result = Invoke-ScopeyDhcpCommand -CommandName Get-DhcpServerv4Lease -Parameters @{
            ScopeId = $script:SelectedScopeId
            AllLeases = $true
        } | Where-Object AddressState -eq $AddressState | Select-Object IPAddress, ClientId, HostName, AddressState

        if (-not $result) { Write-Host $EmptyMessage -ForegroundColor Yellow }
        else { $result | Format-Table -AutoSize }
    }
    catch {
        Write-Host 'An error occurred while listing leases.' -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor DarkYellow
    }
    finally { Show-ScopeyMenu }
}

function Add-ScopeyReservation {
    $suggestion = $null

    try {
        $stats = Invoke-ScopeyDhcpCommand -CommandName Get-DhcpServerv4ScopeStatistics -Parameters @{ ScopeId = $script:SelectedScopeId }
        if ($stats.Free -ne 0) {
            $freeIp = Invoke-ScopeyDhcpCommand -CommandName Get-DhcpServerv4FreeIPAddress -Parameters @{ ScopeId = $script:SelectedScopeId }
            $suggestion = " (example free IP: $freeIp)"
        }
    }
    catch { }

    $ipAddress = Read-Host "Select an IP address$suggestion in range $($script:SelectedScope.StartRange.IPAddressToString) - $($script:SelectedScope.EndRange.IPAddressToString)"
    $clientId = Read-Host "Select a ClientID/MAC for $ipAddress"
    $description = Read-Host 'Optional reservation description'

    try {
        $params = @{
            ScopeId = $script:SelectedScopeId
            IPAddress = $ipAddress
            ClientId = $clientId
        }

        if ($description) { $params['Description'] = $description }

        Invoke-ScopeyDhcpCommand -CommandName Add-DhcpServerv4Reservation -Parameters $params
        Write-Host "The IP address $ipAddress was successfully reserved for $clientId." -ForegroundColor Green
    }
    catch {
        Write-Host 'An error occurred. Make sure the IP and MAC address are free and valid.' -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor DarkYellow
    }
    finally { Show-ScopeyMenu }
}

function Remove-ScopeyReservationByIp {
    $ipAddress = Read-Host 'Select an IP address in the scope to delete the reservation for'

    try {
        $reservation = Invoke-ScopeyDhcpCommand -CommandName Get-DhcpServerv4Reservation -Parameters @{ IPAddress = $ipAddress }

        if ($reservation.ScopeId.IPAddressToString -ne $script:SelectedScopeId) {
            Write-Host 'The selected IP address is not inside the selected scope.' -ForegroundColor Yellow
        }
        else {
            Invoke-ScopeyDhcpCommand -CommandName Remove-DhcpServerv4Reservation -Parameters @{ IPAddress = $ipAddress }
            Write-Host "The reservation of $ipAddress was successfully removed from $($reservation.ClientId)." -ForegroundColor Green
        }
    }
    catch {
        Write-Host 'The selected IP address reservation was not found on this DHCP server.' -ForegroundColor Yellow
        Write-Host $_.Exception.Message -ForegroundColor DarkYellow
    }
    finally { Show-ScopeyMenu }
}

function Remove-ScopeyReservationByClientId {
    $clientId = Read-Host 'Select a ClientID/MAC address in the scope to delete the reservation for'

    try {
        $reservation = Invoke-ScopeyDhcpCommand -CommandName Get-DhcpServerv4Reservation -Parameters @{
            ScopeId = $script:SelectedScopeId
            ClientId = $clientId
        }

        Invoke-ScopeyDhcpCommand -CommandName Remove-DhcpServerv4Reservation -Parameters @{ IPAddress = $reservation.IPAddress.IPAddressToString }
        Write-Host "The reservation of $($reservation.IPAddress.IPAddressToString) was successfully removed from $clientId." -ForegroundColor Green
    }
    catch {
        Write-Host 'The selected ClientID was not found in this scope.' -ForegroundColor Yellow
        Write-Host $_.Exception.Message -ForegroundColor DarkYellow
    }
    finally { Show-ScopeyMenu }
}

function Find-ScopeyLeaseByClientId {
    $clientId = Read-Host 'Select a ClientID/MAC address in this scope to find the related lease'

    try {
        Invoke-ScopeyDhcpCommand -CommandName Get-DhcpServerv4Lease -Parameters @{
            ScopeId = $script:SelectedScopeId
            ClientId = $clientId
        } | Select-Object IPAddress, ClientId, HostName, AddressState | Format-Table -AutoSize
    }
    catch {
        Write-Host 'No lease for the specified ClientID was found in this scope.' -ForegroundColor Yellow
    }
    finally { Show-ScopeyMenu }
}

function Find-ScopeyLeaseByIp {
    $ipAddress = Read-Host 'Select an IP address in this scope to find the related lease'

    try {
        $result = Invoke-ScopeyDhcpCommand -CommandName Get-DhcpServerv4Lease -Parameters @{ IPAddress = $ipAddress } |
            Where-Object { $_.ScopeId.IPAddressToString -eq $script:SelectedScopeId }

        if ($result) {
            $result | Select-Object IPAddress, ClientId, HostName, AddressState | Format-Table -AutoSize
        }
        else {
            Write-Host 'No lease for the specified IP was found in this scope.' -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host 'No lease for the specified IP was found in this scope.' -ForegroundColor Yellow
    }
    finally { Show-ScopeyMenu }
}

function Show-ScopeyServerInfo {
    Write-Host ''
    Write-Host "Scopey server target: $($script:DhcpServer)" -ForegroundColor Cyan
    Write-Host "Running from: $env:COMPUTERNAME" -ForegroundColor Cyan
    Write-Host "Credential supplied: $([bool]$script:Credential)" -ForegroundColor Cyan
    Show-ScopeyMenu
}

function Show-ScopeyMenu {
    Set-ScopeyWindowTitle

    if (-not $script:FirstRun) {
        Read-Host 'Press ENTER to continue to menu'
    }

    $script:FirstRun = $false

    Write-Host ''
    Write-Host '+-------------------------------------------------------+' -ForegroundColor Magenta
    Write-Host ' Scopey - DHCP Scope Helper'
    Write-Host " DHCP Server: $($script:DhcpServer)"
    Write-Host '+-------------------------------------------------------+' -ForegroundColor Magenta
    Write-Host ' 0  - Exit'
    Write-Host ' 1  - Select a New Scope'
    Write-Host ' 2  - Replicate Scope'
    Write-Host ' 3  - List all free IP addresses'
    Write-Host ' 4  - List all active IP addresses which are not reserved'
    Write-Host ' 5  - List all active IP addresses which are reserved'
    Write-Host ' 6  - List all inactive IP addresses which are reserved'
    Write-Host ' 7  - Reserve IP address'
    Write-Host ' 8  - Remove reservation by IP'
    Write-Host ' 9  - Remove reservation by ClientID'
    Write-Host ' 10 - Find lease by ClientID'
    Write-Host ' 11 - Find lease by IP'
    Write-Host ' 12 - Show server connection info'
    Write-Host '+-------------------------------------------------------+' -ForegroundColor Magenta

    $choice = Read-Host 'Select alternative'

    switch ($choice) {
        '0'  { exit }
        '1'  { Select-ScopeyScope }
        '2'  { Invoke-ScopeyFailoverReplication }
        '3'  { Show-ScopeyFreeIpAddresses }
        '4'  { Show-ScopeyLeasesByState -AddressState Active -EmptyMessage 'There are no active unreserved IP addresses in this scope.' }
        '5'  { Show-ScopeyLeasesByState -AddressState ActiveReservation -EmptyMessage 'There are no active reserved IP addresses in this scope.' }
        '6'  { Show-ScopeyLeasesByState -AddressState InactiveReservation -EmptyMessage 'There are no inactive reserved IP addresses in this scope.' }
        '7'  { Add-ScopeyReservation }
        '8'  { Remove-ScopeyReservationByIp }
        '9'  { Remove-ScopeyReservationByClientId }
        '10' { Find-ScopeyLeaseByClientId }
        '11' { Find-ScopeyLeaseByIp }
        '12' { Show-ScopeyServerInfo }
        default {
            Write-Host 'Invalid choice.' -ForegroundColor Red
            Show-ScopeyMenu
        }
    }
}

$script:DhcpServer = $DhcpServer
$script:Credential = $Credential

Set-ScopeyWindowTitle
Import-ScopeyDhcpModule
Test-ScopeyDhcpServerConnection
Select-ScopeyScope
