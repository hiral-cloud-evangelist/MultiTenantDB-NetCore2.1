﻿[CmdletBinding()]
Param(
    # Resource group containing the 
    [Parameter(Mandatory=$True)]    
    [string]$WtpResourceGroupName,
    
    [Parameter(Mandatory=$True)]    
    [string]$WtpUser, 

    # Intensity of load - equates roughly to the workload in DTU applied to each tenant 
    [int][validaterange(1,100)] $Intensity = 30,

    # Duration of the load generation session in minutes. Due to the way loads are applied, some 
    # activity may continue after this time. 
    [int]$DurationMinutes = 120,

    # If enabled causes databases in different pools on the same server to be loaded unequally
    # Use to demonstrate load balancing databases between pools  
    [switch]$Unbalanced,

    # If enabled, causes a single tenant to have a specific distinct load applied
    # Use with SingleTenantIntensity to demonstrate moving a database in or out of a pool  
    [switch] $SingleTenant,

    # If SingleTenant is enabled, defines the load in DTU applied to an isolated tenant 
    [int][validateRange(1,100)] $SingleTenantDtu = 90,

    # If singleTenant is enabled, identifes the tenant.  If not specified a random tenant database is chosen
    [string]$SingleTenantName = "Contoso Concert Hall",

    [switch]$LongerBursts,

    # if OneTime switch is used then jobs are submitted and the script stops, othewise it continues to poll for new tenants 
    [switch]$OneTime
)

## Configuration

$WtpUser = $WtpUser.ToLower()

Import-Module "$PSScriptRoot\..\Common\SubscriptionManagement" -Force
Import-Module "$PSScriptRoot\..\Common\CatalogAndDatabaseManagement" -Force

#import the saved Azure context to avoid having to log in to Azure again
Import-AzureRmContext -Path $env:temp\AzureContext.json > $null

# Get Azure credentials if not already logged on,  Use -Force to select a different subscription 
Initialize-Subscription

$config = Get-Configuration

$tenantAdminUser = $config.TenantAdminUsername
$tenantAdminPassword = $config.TenantAdminPassword

## MAIN SCRIPT ------------------------------------------------------------------------------

# Get the catalog 
$catalog = Get-Catalog -ResourceGroupName $WtpResourceGroupName -WtpUser $WtpUser 

# Burst durations are randomized, the following set the min and max duration in seconds
$burstMinDuration = 25 
$burstMaxDuration = 40

# boost increases burst duration, increasing the likelihood of overlaps  
if ($LongerBursts.IsPresent) {$burstMinDuration = 30; $burstMaxDuration = 52}

# interval between bursts is randomized, the following set min and max interval in seconds for normal range
$intervalMin = 100
$intervalMax = 360

# longer bursts also decreases the interval between bursts, increasing likelihood of overlaps
if ($LongerBursts.IsPresent) {$intervalMin = $intervalMin * 0.9; $intervalMax = $intervalMax * 0.9}

# DTU burst level is randomized by applying a factor with min and max values 
$burstMinFactor = 0.6
$burstMaxFactor = 1.1

# Load factor skews the load on databases for intense single tenant usage scenarios.  
# Load factor impacts DTU levels and interval between bursts -> interval = interval/loadFactor (low load factor ==> longer intervals)

# Load factor for single tenant burst mode
$intenseLoadFactor = 4.00

# density load factor, decreases the database load with more tenants, allowing more interesting demos with small numbers of tenants
# It impacts the interval between bursts [interval = interval + (interval * densityLoadFactor * tenantsCount)]
# 0 removes the effect, 0.1 will double the typical interval for 10 tenants  
$densityLoadFactor = 0.11

$CatalogServerName = $config.CatalogServerNameStem + $WtpUser

$jobs = @{}

## Start job invocation loop

$start = Get-Date

$sleepCount = 0
$sleep = 10

$settings = "`nDuration: $DurationMinutes mins, Intensity: $intensity, LongerBursts: $LongerBursts, SingleTenant: $SingleTenant"

if($SingleTenant)
{
    if ($SingleTenantDatabaseName -ne "")
    {
        $settings += ", Tenant: $SingleTenantName"
    }
    $settings += ", DTU: $singleTenantDtu"
}

Write-Output $settings
Write-Output "`nInvoking a load generation job for each tenant. Will check for new tenants every $sleep seconds for $durationMinutes minutes."  
Write-Output "`nClose this session to stop all jobs."
Write-Output "`nYou can use Ctrl-C to stop invoking new jobs and then inspect and manage the jobs as follows:" 
Write-Output "  Get-Job to view status of all jobs" 
Write-Output "  Receive-Job <job id> -Keep to view output from an individual job to see the load applied to a specific tenant" 
Write-Output "  Stop-Job <job id> to stop a job.  Use Stop-Job * to stop all jobs (which can take a minute or more)"
Write-Output "  Remove-Job <job id> to remove a job.  Use Remove-Job * to remove all jobs.  Use -Force to stop and remove.`n"

while (1 -eq 1)
{
    $mappings = Get-Mappings -ShardMap $catalog.ShardMap

    # Array that will contain all tenants to be targeted
    $tenants = @()
    $loadFactor = 1.0

    #$ServerNames = @()
    foreach ($mapping in $mappings)
    {        
        $serverName = ($mapping.ShardLocation.Datasource.split(":",2)[1]).split(",",2)[0]
        $databaseName = $mapping.ShardLocation.Database

        # randomize the workload intensity for each tenant
        $burstLevel = Get-Random -Minimum $burstMinFactor -Maximum $burstMaxFactor 
        $burstDtu = [math]::Ceiling($burstLevel * $Intensity)

        # add tenant 
        $tenantProperties = @{
            ServerName=$serverName;
            DatabaseName=$databaseName;
            TenantKey=$mapping.Value; 
            BurstDtu=$burstDtu;
            LoadFactor=$loadFactor
            }
        $tenant = New-Object PSObject -Property $tenantProperties

        $tenants += $tenant

    }

    if ($SingleTenant.IsPresent -and $SingleTenantName -ne "")
    {
        $SingleTenantKey = Get-TenantKey $SingleTenantName

        #validate that the name is one of the database names about to be processed
        $tenantKeys = $tenants | select -ExpandProperty TenantKey

        if (-not ($tenantKeys -contains $SingleTenantKey))
        {
            throw "The single tenant name '$SingleTenantName' was not found.  Check the spelling and try again."
        }     
    }

    
    # spawn jobs to spin up load on each tenant
    # note there are limits to using PS jobs at scale; this should only be used for small scale demonstrations 

    # Set the end time for all jobs
    $endTime = [DateTime]::Now.AddMinutes($DurationMinutes)

    $scriptPath= $PSScriptRoot

    # Script block for job that executes the load generation stored procedure on each database 
    $scriptBlock = `
        {
            param($tenantKey,$server,$database, $AdminUser,$AdminPassword,$DurationMinutes,$intervalMin,$intervalMax,$burstMinDuration,$burstMaxDuration,$baseDtu,$loadFactor,$densityLoadFactor,$tenantsCount)

            Import-Module "$using:scriptPath\..\Common\CatalogAndDatabaseManagement" -Force

            Write-Output ("Tenant " + $tenantKey + " " + $database + "/" + $server + " Load factor: " + $loadFactor + " Density weighting: " + ($densityLoadFactor*$tenantsCount)) 

            $endTime = [DateTime]::Now.AddMinutes($DurationMinutes)

            $firstTime = $true

            While ([DateTime]::Now -lt $endTime)
            {
                # add variable delay before execution, this staggers bursts
                # load factor is applied to reduce interval for high or intense loads, and increase interval for low loads
                # density load factor extends interval for higher density pools to reduce overloading
                if($firstTime)
                {
                    $snooze = [math]::ceiling((Get-Random -Minimum 0 -Maximum ($intervalMax - $intervalMin)) / $loadFactor)
                    $snooze = $snooze + ($snooze * $densityLoadFactor * $tenantsCount)
                    $firstTime = $false
                }
                else
                {
                    $snooze = [math]::ceiling((Get-Random -Minimum $intervalMin -Maximum $intervalMax) / $loadFactor)
                    $snooze = $snooze + ($snooze * $densityLoadFactor * $tenantsCount)
                }
                Write-Output ("Snoozing for " + $snooze + " seconds")  
                Start-Sleep $snooze

                # vary each burst to add realism to the workload
            
                # vary burst duration
                $burstDuration = Get-Random -Minimum $burstMinDuration -Maximum $burstMaxDuration

                # Increase burst duration based on load factor.  Has marginal effect on low loadfactor databases.
                $burstDuration += ($loadFactor * 2)           

                # vary DTU 
                $dtuVariance = Get-Random -Minimum 0.9 -Maximum 1.1
                $burstDtu = [Math]::ceiling($baseDtu * $dtuVariance)

                # ensure burst DTU doesn't exceed 100 
                if($burstDtu -gt 100) 
                {
                    $burstDtu = 100
                }

                # configure and submit the SQL script to run the load generator
                $sqlScript = "EXEC sp_CpuLoadGenerator @duration_seconds = " + $burstDuration + ", @dtu_to_simulate = " + $burstDtu               
                try
                {
                    Invoke-SqlAzureWithRetry -ServerInstance $server `
                        -Database $database `
                        -Username $AdminUser `
                        -Password $AdminPassword `
                        -Query $sqlscript `
                        -QueryTimeout 36000         
                }
                catch
                {
                    write-error $_.Exception.Message
                    Write-Output ("Error connecting to tenant database " + $database + "/" + $server)
                }

                [string]$message = $([DateTime]::Now) 
                Write-Output ( $message + " Starting load: " + $burstDtu + " DTUs for " + $burstDuration + " seconds")  

                # exit loop if end time exceeded
                if ([DateTime]::Now -gt $endTime)
                {
                    break;
                }
            }
        }

    # Start a job for each tenant.  Each job runs for the specified session duration and triggers load periodically.
    # The base-line load level for each tenant is set by the entry in $tenants.  Burst duration, interval and DTU are randomized
    # slightly within each job to create a more realistic workload

    $randomTenantIndex = 0

    if ($SingleTenant -and $SingleTenantDatabaseName -eq "")
    {
        $randomTenantIndex = Get-Random -Minimum 1 -Maximum ($tenants.Count + 1)        
    }

    $i = 1

    foreach ($tenant in $tenants)
    {
        # skip further processing if job is already started for this tenant
        if ($jobs.ContainsKey($tenant.TenantKey.ToString()))
        {
            continue
        } 

        if($sleeping -eq $true)
        {
            $sleeping = $false
            # emit next job output on a new line
            Write-Output "`n"
        }


        # Customize the load applied for each tenant
        if ($SingleTenant)
        {
            if ($i -eq $randomTenantIndex) 
            {
                # this is the randomly selected database, so use the single-tenant factors
                $burstDtu = $SingleTenantDtu
                $loadFactor = $intenseLoadFactor 
            }        
            elseif ($randomTenantIndex -eq 0 -and $SingleTenantKey -eq $tenant.TenantKey) 
            {
                # this is the named database, so use the single-tenant factors
                $burstDtu = $SingleTenantDtu
                $loadFactor = $intenseLoadFactor 
            }
            else 
            {             
                # use normal tenant factors 
                $burstDtu = $tenant.BurstDtu
                $loadFactor = $tenant.LoadFactor
            }
        }
        else 
        {
            # use normal tenant factors
            $burstDtu = $tenant.BurstDtu
            $loadFactor = $tenant.LoadFactor
        }

        $outputText = " Starting load with load factor $loadFactor with baseline DTU $burstDtu"
    
        # start the load generation job for the current tenant
        
        $job = Start-Job `
            -ScriptBlock $scriptBlock `
            -Name ($tenant.TenantKey).ToString() `
            -ArgumentList $(`
                $tenant.TenantKey, $tenant.ServerName,$tenant.DatabaseName,`
                $TenantAdminUser,$TenantAdminPassword,`
                $DurationMinutes,$intervalMin,$intervalMax,`
                $burstMinDuration,$burstMaxDuration,$burstDtu,`
                $loadFactor,$densityLoadFactor,$tenants.Count)    

        # add job to dictionary of currently running jobs
        $jobs += @{$job.Name = $job}

        $outputText = ("Job $($job.Id) $($Job.Name) $outputText")
        write-output $outputText
    }

    $now = Get-Date
    $runtime = ($now - $start).TotalMinutes

    if ($runtime -ge $DurationMinutes -or $OneTime.isPresent)
    {
        Write-Output "`n`nLoad generation session stopping after $runtime minutes"
        exit
    }

    $sleepCount ++

    # displays rows of dots to show it's still working. A dot every 10 seconds, a new row every 10 minutes 
    if ($sleepCount -ge 60)
    {
        write-host "."
        $sleepCount = 0
    }
    else
    {
        write-host -NoNewline "."
    }

    $sleeping = $true
    
    Sleep $sleep
}