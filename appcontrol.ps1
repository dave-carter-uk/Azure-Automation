<#PSScriptInfo

.DESCRIPTION Start/Stop/Check local applications and resources on host

.AUTHOR David Carter

.PARAMETERS
	-Action (position 1) <start|stop[|check]>
	Action to perform on local host

.EXAMPLES
	% appcontrol.ps1 stop
	Stop all applications described in $hostname.conf file

	% appcontrol.ps1 check
	Check run status of all applications described in $hostname.conf file

	see example conf files for details of configuration file format
#>

[CmdletBinding()]
param (
	[string] $Action = "Check"
)

$VERSION = "1.4"

##
#### Local help functions (functions called by the action handlers)
######

##
#### Action handlers (<Start|Stop|Check>--Function [params])
######

function Start--WINCluster {

	Param (
		[Alias('Role')][string[]] $Roles
	)

	Write-Host "Cluster status is: $((Get-Service -Name "Cluster Service").Status)"

	# Enable local service auto start
	Get-Service -Name "Cluster Service" | Set-Service -StartupType Automatic

	if ((Get-Service -Name "Cluster Service").Status -eq "Stopped") {

		Write-Host "Starting Cluster ..."
		Start-Cluster -Verbose:$False -ErrorAction SilentlyContinue | Out-Null
	}

	# Wait for Cluster and roles
	$End = $(Get-Date).AddSeconds(600)
	While (((Get-Service -Name "Cluster Service").Status -ne "Running") -And ($(Get-Date) -lt $End)) {
		Start-Sleep 10
	}

	foreach ($r in $Roles) {
		While (((Get-ClusterGroup -Name $r -Verbose:$False -ErrorAction SilentlyContinue).State -ne "Online") -And ($(Get-Date) -lt $End)) {
			Start-Sleep 10
		}
	}

	Check--WINCluster @PSBoundParameters
}

function Stop--WINCluster {

	Param (
		[Alias('Role')][string[]] $Roles
	)

	Write-Host "Cluster status is: $((Get-Service -Name "Cluster Service").Status)"

	# Disable local service auto start
	Get-Service -Name "Cluster Service" | Set-Service -StartupType Manual

	if ((Get-Service -Name "Cluster Service").Status -eq "Running") {

		Write-Host "Stopping Cluster ..."
		Stop-Cluster -Force -Verbose:$False -ErrorAction SilentlyContinue | Out-Null
	}

	Check--WINCluster @PSBoundParameters
}

function Check--WINCluster {

	Param (
		[Alias('Role')][string[]] $Roles
	)

	Write-Host "Checking Cluster ..."
	if ((Get-Service -Name "Cluster Service").Status -eq "Running") {

		Get-ClusterNode -Verbose:$False | foreach { Write-Host "Cluster node $($_.Name) $($_.State)" }
		Get-ClusterGroup -Verbose:$False | foreach { Write-Host "Cluster role '$($_.Name)' on $($_.OwnerNode) $($_.State)" }

		# Validate roles
		$rc = 3
		foreach ($r in $Roles) {
			if ((Get-ClusterGroup -Name $r -Verbose:$False -ErrorAction SilentlyContinue).State -ne "Online") {
				Write-Host "Error role '$r' not online"
				$rc =2
			}
		}
		Return $rc
	}
	else {
		Write-Host "Local cluster stopped or unavailable"
		Return 4
	}
}

function Start--SAPInstance {

	# Start SAP Instance
	Param (
		[Parameter(Mandatory)][Alias('DIR_INSTANCE','Instance')][string] $Dir,
		[Parameter(Mandatory)][string] $User,
		[Parameter(Mandatory)][string] $Pass,
		[int] $Grace = 0
	)

	$nr = $Dir.Substring($Dir.Length -2)

	Write-Host "Starting SAP Instance $nr"
	& $Dir\exe\sapcontrol.exe -nr $nr -user $User $Pass -function StartWait 600 10 | Write-Verbose

	Check--SAPInstance @PSBoundParameters
}

function Stop--SAPInstance {

	# Stop SAP Instance
	Param (
		[Parameter(Mandatory)][Alias('DIR_INSTANCE','Instance')][string] $Dir,
		[Parameter(Mandatory)][string] $User,
		[Parameter(Mandatory)][string] $Pass,
		[int] $Grace = 0
	)

	$nr = $Dir.Substring($Dir.Length -2)

	Write-Host "Stopping SAP Instance $nr"
	& $Dir\exe\sapcontrol.exe -nr $nr -user $User $Pass -function Stop $Grace | Write-Verbose
	& $Dir\exe\sapcontrol.exe -nr $nr -user $User $Pass -function WaitforStopped 600 10 | Write-Verbose

	Check--SAPInstance @PSBoundParameters
}

function Check--SAPInstance {

	# Get SAP Instance status
	Param (
		[Parameter(Mandatory)][Alias('DIR_INSTANCE','Instance')][string] $Dir,
		[Parameter(Mandatory)][string] $User,
		[Parameter(Mandatory)][string] $Pass,
		[int] $Grace = 0
	)

	$nr = $Dir.Substring($Dir.Length -2)

	& $Dir\exe\sapcontrol.exe -nr $nr -user $User $Pass -function GetProcessList | Write-Verbose

	Write-Host "Checking SAP Instance $nr completed with status: $(Get-ExitStatus $LASTEXITCODE)"
	Return $LASTEXITCODE
}

function Start--WINService {

	# Start a Service
	Param (
		[Parameter(Mandatory)][string] $Name
	)

	Write-Host "Starting Service '$Name'"
	Start-Service -Name $Name -WarningAction SilentlyContinue -ErrorAction Stop | Write-Verbose

	Check--WINService @PSBoundParameters
}

function Stop--WINService {

	# Stop a Service
	Param (
		[Parameter(Mandatory)][string] $Name
	)

	Write-Host "Stopping Service '$Name'"
	Stop-Service -Name $Name -WarningAction SilentlyContinue -ErrorAction Stop | Write-Verbose

	Check--WINService @PSBoundParameters
}

function Check--WINService {

	# Check if Service is Running / Stopped
	Param (
		[Parameter(Mandatory)][string] $Name
	)

	[string]$Status = (Get-Service -Name $Name -ErrorAction Stop).Status
	Write-Host "Checking Service '$Name' completed with status: $Status"

	Switch ($Status) {
		'Running' { Return 3 }
		'Stopped' { Return 4 }
		Default { Return 2 }
	}
}

##
#### Main
######

function Get-ExitAverage {

	# Return the exit average, or 2 (Error) if average not a whole number
	Param (
		[Parameter(Mandatory)][int] $Total,
		[int] $Count
	)

	$rc = $Total / $Count
	if ($rc -is [int]) { $rc } else { 2 }
}

function Get-ExitStatus {

	# Return code status
	Param (
		[string] $Code = ""
	)

	Switch ($Code) {
		3 { "Running" }
		4 { "Stopped" }
		Default { "Error" } 
	}
}

function Invoke {

	Param (
		[Parameter(Mandatory)][string] $Action,
		[Parameter(Mandatory)][string] $Target
	)

	try {
		"$Action--$Target" | Invoke-Expression
	}
	catch {
		Write-Error "Error calling action: $Action--$Target`n$_"
	}
}

# Read configuration file
$Config = "$PSScriptRoot\$(hostname).conf"
try {
	$CmdList = [string[]] (Get-Content -Path $Config -ErrorAction Stop | Where {$_ -notmatch '^#.*' -and $_ -notmatch '^\s*$'})
}
catch {
	Write-Verbose $_
	Write-Host "Error reading configuration file: $Config (Exit-Code:2)"
	Exit
}

# Perform actions
Write-Host "[$(Get-Date) $(hostname) Script: $PSCommandPath $Args (Version $VERSION)]"
Write-Host "[$(Get-Date) $(hostname) Config: $Config]"

$rc = 0
Switch ($Action) {

	"Start" {
		for ($i = 0; $i -lt $CmdList.Count; $i++) {
			$rc += Invoke -Action Start -Target $CmdList[$i]
		}
	}

	"Stop" {
		for ($i = $CmdList.Count-1; $i -ge 0; $i--) {
			$rc += Invoke -Action Stop -Target $CmdList[$i]
		}
	}

	Default {
		for ($i = 0; $i -lt $CmdList.Count; $i++) {
			$rc += Invoke -Action Check -Target $CmdList[$i]
		}
	}
}

# Finalize results of check
Write-Host "(Exit-Code:$(Get-ExitAverage -Total $rc -Count $CmdList.Count))"

Exit
