 <#
    .SYNOPSIS
        Export Azure Device Report using MS Graph PowerShell

    .DESCRIPTION
        Download all devices in an Azure AD or Entra ID tenant and export them to CSV or downoad just a subset based on specific criteria - see parameters and examples for more information. 
        The script requires the use of Microsoft.Graph.Beta and will install it if its not available. It will prompt the operator for permission before continuing   
        
        1.The script can be executed with MFA-enabled accounts too. 
        2.Exports output to CSV. 
        3.Automatically installs the Microsoft Graph PowerShell module in your PowerShell environment after asking for confirmation. 
        4.Supports certificate-based authentication. 
        5.The script lists all the Azure AD devices of your organization. That too customization of reports is possible according to the major device types like managed, enabled, disabled etc. 

    .INPUTS
        The script does not take piped input, but requires command line parameters specified at runtime

    .OUTPUTS
        A CSV File stored in the current directory

    .EXAMPLE
        .\GetAzureADDevicesReport.ps1

        To Use Crtoficate based authentication (App Only)
        .\GetAzureADDevicesReport.ps1 -TenantId< TenantId> -ClientId <ClientId> -CertificateThumbprint<CertThumbprint>

        To export only Managed Devices
        .\GetAzureADDevicesReport.ps1 -ManagedDevice

        To export only devcie with a stored BitLocker Key (not available with Cert Based Authentication)
        .\GetAzureADDevicesReport.ps1 -DevicesWithBitLockerKey

        Identify inactive devices in Azure AD
        .\GetAzureADDevicesReport.ps1 -InactiveDays <NumberOfDays>

        Export enabled devices in Azure AD
        .\GetAzureADDevicesReport.ps1 -EnabledDevice

        Export disabled devices in Azure AD 
        .\GetAzureADDevicesReport.ps1 -DisabledDevice
        
    .LINK
        https://o365reports.com/2023/04/18/get-azure-ad-devices-report-using-powershell/

    .NOTES
        V2.0 downloaded from creators website
        V2.1 added Powershell Synopsis, Parameter help and other comments

    #>


## If you execute via CBA, then your application required "Directory.Read.All" application permissions. NOTE: Cert Based Auth will not allow access to BitLocker Keys

## This sets the parameters for command line execution
Param
(
    [Parameter(Mandatory = $false)]
    # TenantID is the TenantID required for certificate based authentication 
    [string]$TenantId,
    # ClientID is the CLientID required for certificate based authentication
    [string]$ClientId,
    # CertificateThumbprint is the thrumbprint of the certificate to be used for app only/cert based authentication
    [string]$CertificateThumbprint,
    # EnabledDevice - if this parameter is specified then only enabled devices will be processed and exported
    [switch]$EnabledDevice,
    # DisabledDevice - if this parameter is specified then only disabled devices will be processed and exported
    [switch]$DisabledDevice,
    # InactiveDays - exports the devices that have been inactive for the number of days specified e.g. .\GetAzureADDevicesReport.ps1 -InactiveDays 30
    [Int]$InactiveDays,
    # ManagedDevice - if this parameter is specified then only managed devices are exported
    [switch]$ManagedDevice,
    # DevicesWithBitlockerKey - if this parameter is specified then only devices with store bitlockerkeys are exported NOTE: this is not available when using Cert Based Auth 
    [switch]$DevicesWithBitLockerKey
)
# Check to see if the MsGraphBetaModule is installed/available to the user
$MsGraphBetaModule =  Get-Module Microsoft.Graph.Beta -ListAvailable
# If its not available offer to install it
if($MsGraphBetaModule -eq $null)
{ 
    Write-host "Important: Microsoft Graph Beta module is unavailable. It is mandatory to have this module installed in the system to run the script successfully." 
    $confirm = Read-Host Are you sure you want to install Microsoft Graph Beta module? [Y] Yes [N] No  
    if($confirm -match "[yY]") 
    { 
        Write-host "Installing Microsoft Graph Beta module..."
        Install-Module Microsoft.Graph.Beta -Scope CurrentUser -AllowClobber
        Write-host "Microsoft Graph Beta module is installed in the machine successfully" -ForegroundColor Magenta 
    } 
    else
    { 
        Write-host "Exiting. `nNote: Microsoft Graph Beta module must be available in your system to run the script" -ForegroundColor Red
        Exit 
    } 
}
# if either Tenant ID or Client ID is missing terminate the run with an error
if(($TenantId -ne "") -and ($ClientId -ne "") -and ($CertificateThumbprint -ne ""))  
{  
    Connect-MgGraph  -TenantId $TenantId -AppId $ClientId -CertificateThumbprint $CertificateThumbprint -ErrorAction SilentlyContinue -ErrorVariable ConnectionError|Out-Null
    if($ConnectionError -ne $null)
    {    
        Write-Host $ConnectionError -Foregroundcolor Red
        Exit
    }
    $Certificate = (Get-MgContext).CertificateThumbprint
    Write-Host "Note: You don't get device with bitlocker key info while using certificate based authentication. If you want to get bitlocker key enabled devices, then you can connect graph using credentials(User interaction based authentication)" -ForegroundColor Yellow
}
else
# Connect to MgGraph
{
    Connect-MgGraph -Scopes "Directory.Read.All,BitLockerKey.Read.All"  -ErrorAction SilentlyContinue -Errorvariable ConnectionError |Out-Null
    if($ConnectionError -ne $null)
    {
        Write-Host "$ConnectionError" -Foregroundcolor Red
        Exit
    }
}
# Write some informationl messages
Write-Host "Microsoft Graph Beta Powershell module is connected successfully" -ForegroundColor Green
Write-Host "`nNote: If you encounter module related conflicts, run the script in a fresh Powershell window."

# Declare a function to close the connection 
function CloseConnection
{
    Disconnect-MgGraph |  Out-Null
    Exit
}
# Declare some variables
$OutputCsv =".\AzureDeviceReport_$((Get-Date -format MMM-dd` hh-mm-ss` tt).ToString()).csv" 
$Report=""
$FilterCondition = @()
# Get all devcies from Azure AD
$DeviceInfo = Get-MgBetaDevice -All
# If the variable is empty assume no devcis exists in Azure AD
if($DeviceInfo -eq $null)
{
    Write-Host "You have no devices enrolled in your Azure AD" -ForegroundColor Red
    CloseConnection
}
# Check command line parameters and store only the devices the operator requested
if($EnabledDevice.IsPresent)
{
    $DeviceInfo = $DeviceInfo | Where-Object {$_.AccountEnabled -eq $True}
}
elseif($DisabledDevice.IsPresent)
{
    $DeviceInfo = $DeviceInfo | Where-Object {$_.AccountEnabled -eq $False}
}
if($ManagedDevice.IsPresent)
{
    $DeviceInfo = $DeviceInfo | Where-Object {$_.IsManaged -eq $True}
}
# Get the local time zone
$TimeZone = (Get-TimeZone).Id

# Process the information recovered about the stored AAD devices  
Foreach($Device in $DeviceInfo){
    Write-Progress -Activity "Fetching devices: $($Device.DisplayName)"
    $LastSigninActivity = "-"
    # calculate the last sign in
    if(($Device.ApproximateLastSignInDateTime -ne $null))
    {
        $LastSigninActivity = (New-TimeSpan -Start $Device.ApproximateLastSignInDateTime).Days
    }
    # check bitlocker if not using cert based authentcation
    if($Certificate -eq $null)
    {
        $BitLockerKeyIsPresent = "No"
        try {
            $BitLockerKeys = Get-MgBetaInformationProtectionBitlockerRecoveryKey -Filter "DeviceId eq '$($Device.DeviceId)'" -ErrorAction SilentlyContinue -ErrorVariable Err
            if($Err -ne $null)
            {
                Write-Host $Err -ForegroundColor Red
                CloseConnection
            }
        }
        catch
        {
            Write-Host $_.Exception.Message -ForegroundColor Red
            CloseConnection
        }
        if($BitLockerKeys -ne $null)
        {
            $BitLockerKeyIsPresent = "Yes"
        }
        if($DevicesWithBitLockerKey.IsPresent)
        {
            if($BitLockerKeyIsPresent -eq "No")
            {
                Continue
            }
        }
    }
    # Not sure what this does. It has not script blocks in the conditionals it just continues.
    if($InactiveDays -ne "")
    {
        if(($Device.ApproximateLastSignInDateTime -eq $null))
        {
            Continue
        }
        if($LastSigninActivity -le $InactiveDays) 
        {
            continue
        }
    }
    #Set some variables - rquired to expand data from recovered records
    $DeviceOwners = Get-MgBetaDeviceRegisteredOwner -DeviceId $Device.Id -All |Select-Object -ExpandProperty AdditionalProperties
    $DeviceUsers = Get-MgBetaDeviceRegisteredUser -DeviceId $Device.Id -All |Select-Object -ExpandProperty AdditionalProperties
    $DeviceMemberOf = Get-MgBetaDeviceMemberOf -DeviceId $Device.Id -All |Select-Object -ExpandProperty AdditionalProperties
    $Groups = $DeviceMemberOf|Where-Object {$_.'@odata.type' -eq '#microsoft.graph.group'}
    $AdministrativeUnits = $DeviceMemberOf|Where-Object{$_.'@odata.type' -eq '#microsoft.graph.administrativeUnit'}
    
    # Set the Join Type to a more friendly name
    if($Device.TrustType -eq "Workplace")
    {
        $JoinType = "Azure AD registered"
    }
    elseif($Device.TrustType -eq "AzureAd")
    {
        $JoinType = "Azure AD joined"
    }
    elseif($Device.TrustType -eq "ServerAd")
    {
        $JoinType = "Hybrid Azure AD joined"
    }
    
    # Set dates and time on loca regional time (I think)
    if($Device.ApproximateLastSignInDateTime -ne $null)
    {
        $LastSigninDateTime = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($Device.ApproximateLastSignInDateTime,$TimeZone) 
        $RegistrationDateTime = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($Device.RegistrationDateTime,$TimeZone)
    }
    else
    {
        $LastSigninDateTime = "-"
        $RegistrationDateTime = "-"
    }

    $ExtensionAttributes = $Device.ExtensionAttributes
    $AttributeArray = @()
    $Attributes = $ExtensionAttributes.psobject.properties |Where-Object {$_.Value -ne $null -and $_.Name -ne "AdditionalProperties"}| select Name,Value
        Foreach($Attribute in $Attributes)
    {
        $AttributeArray+=$Attribute.Name+":"+$Attribute.Value
    }
    # Prepare a custom object to consolidate all the Data into easily read columns for export
    $ExportResult = @{'Name'                 =$Device.DisplayName
                    'Enabled'                ="$($Device.AccountEnabled)"
                    'Operating System'       =$Device.OperatingSystem
                    'OS Version'             =$Device.OperatingSystemVersion
                    'Join Type'              =$JoinType
                    'Owners'                 =(@($DeviceOwners.userPrincipalName) -join ',')
                    'Users'                  =(@($DeviceUsers.userPrincipalName)-join ',')
                    'Is Managed'             ="$($Device.IsManaged)"
                    'Management Type'        =$Device.ManagementType
                    'Is Compliant'           ="$($Device.IsCompliant)"
                    'Registration Date Time' =$RegistrationDateTime
                    'Last SignIn Date Time'  =$LastSigninDateTime
                    'InActive Days'           =$LastSigninActivity
                    'Groups'                 =(@($Groups.displayName) -join ',')
                    'Administrative Units'   =(@($AdministrativeUnits.displayName) -join ',')
                    'Device Id'              =$Device.DeviceId
                    'Object Id'              =$Device.Id
                    'BitLocker Encrypted'    =$BitLockerKeyIsPresent
                    'Extension Attributes'   =(@($AttributeArray)| Out-String).Trim()
                    }
    $Results = $ExportResult.GetEnumerator() | Where-Object {$_.Value -eq $null -or $_.Value -eq ""} 
    Foreach($Result in $Results){
        $ExportResult[$Result.Name] = "-"
    }
    $Report = [PSCustomObject]$ExportResult

    # Choose report format (based on authentication method)
    if($Certificate -eq $null)
    {
        $Report|Select 'Name','Enabled','Operating System','OS Version','Join Type','Owners','Users','Is Managed','Management Type','Is Compliant','Registration Date Time','Last SignIn Date Time','InActive Days','Groups','Administrative Units','Device Id','Object Id','BitLocker Encrypted','Extension Attributes' | Export-csv -path $OutputCsv -NoType -Append  
    }
    else
    {
        $Report|Select 'Name','Enabled','Operating System','OS Version','Join Type','Owners','Users','Is Managed','Management Type','Is Compliant','Registration Date Time','Last SignIn Date Time','InActive Days','Groups','Administrative Units','Device Id','Object Id','Extension Attributes' | Export-csv -path $OutputCsv -NoType -Append          
    }
}

# Output the report to CSV and ask the user if they want to open it.
if((Test-Path -Path $OutputCsv) -eq "True") 
{ 
     Write-Host `n "The Output file availble in:" -NoNewline -ForegroundColor Yellow; Write-Host "$outputCsv" `n 
    $prompt = New-Object -ComObject wscript.shell    
    $UserInput = $prompt.popup("Do you want to open output file?",` 0,"Open Output File",4)    
    if ($UserInput -eq 6)    
    {    
        Invoke-Item "$OutputCsv"  
        Write-Host "Report generated successfully"  
    }
} 
else
{
    Write-Host "No devices found"
}

# Call the CloseConnection Function to disconnect from MgGraph and end the script 
CloseConnection
