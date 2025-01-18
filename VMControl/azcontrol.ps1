<#PSScriptInfo

.DESCRIPTION Start/Stop/Check local applications and resources on host

.AUTHOR David Carter

.PARAMETERS
	-Action (position 1) <start|stop[|check]>
	Action to perform on local host

	-Config <file>
	Path to local config file, default:script location\$(hostname).conf

	-NoLogging [switch]
	Don't log output to log file

	-LogDir <directory>
	Path to logging directory, default:script location\logs

.EXAMPLES
	% azcontrol.ps1 stop
	Stop all applications described in $hostname.conf file

	% azcontrol.ps1 check
	Check run status of all applications described in $hostname.conf file

	see example conf files for details of configuration file format
#>

[CmdletBinding()]
param (
	[string] $Action = "Check",
	[string] $Config = "$PSScriptRoot\$(hostname).conf",
	[switch] $NoLogging = $False,
	[string] $LogDir = "$PSScriptRoot\logs"
)

$VERSION = "1.0"

# Uncomment below to see Verbose output
#$VerbosePreference = "Continue"

<#
Control functions:
Start-<Type>	Start
Stop-<Type>	Stop
Check-<Type>	Check

Each function is called by the main processor and should provide the following return code:
2	- Error occurred
3	- All started and running
4	- All stopped

Implemented methods:
WINCluster <no additional parameters>
WINService -Name <Name of windows service>
SAPInstance -SAPControl <path to DIR_INSTANCE\sapcontrol.exe> -User <username> -Pass <password> [-Grace <shutdown grace period in seconds>]
#>

function Start-WINCluster {

	# Enable local service auto start
	Get-Service -Name "Cluster Service" | Set-Service -StartupType Automatic

	Write-Host "Cluster status is: $((Get-Service -Name "Cluster Service").Status)"

	if ((Get-Service -Name "Cluster Service").Status -eq "Stopped") {

		Write-Host "Starting Cluster ..."
		Start-Cluster -Verbose:$False -ErrorAction SilentlyContinue | Out-Null

		# Wait for start or timeout
		$End = $(Get-Date).AddSeconds(1200)
		While (((Get-Service -Name "Cluster Service").Status -ne "Running") -and ($(Get-Date) -lt $End)) {
			Start-Sleep 10
		}
	}

	Check-WINCluster @PSBoundParameters
}

function Stop-WINCluster {

	# Disable local service auto start
	Get-Service -Name "Cluster Service" | Set-Service -StartupType Manual

	Write-Host "Cluster status is: $((Get-Service -Name "Cluster Service").Status)"

	if ((Get-Service -Name "Cluster Service").Status -eq "Running") {

		Write-Host "Stopping Cluster ..."
		Stop-Cluster -Force -Verbose:$False -ErrorAction SilentlyContinue | Out-Null
	}

	Check-WINCluster @PSBoundParameters
}

function Check-WINCluster {

	Write-Host "Checking Cluster ..."

	if ((Get-Service -Name "Cluster Service").Status -eq "Running") {

		Get-ClusterNode -Verbose:$False | foreach { Write-Host "Cluster Node $($_.Name) $($_.State)" }
		Get-ClusterGroup -Verbose:$False | foreach { Write-Host "Cluster Resource '$($_.Name)' on $($_.OwnerNode) $($_.State)" }
		Write-Host "Local cluster running"
		Return 3
	}
	else {
		Write-Host "Local cluster stopped or unavailable"
		Return 4
	}
}

function Get-SAPNr {

	Param (
		[Parameter(Mandatory)][string] $SAPControl
	)

	$SAPControl -Replace '^.*sap.*(\d\d).*$', '$1'
}

function Start-SAPInstance {

	# Start SAP Instance
	Param (
		[Parameter(Mandatory)][string] $SAPControl,
		[Parameter(Mandatory)][string] $User,
		[Parameter(Mandatory)][string] $Pass,
		[int] $Grace = 0
	)

	$Nr = Get-SAPNr $SAPControl

	Write-Host "Starting SAP Instance $Nr"
	& $SAPControl -nr $Nr -user $User $Pass -function StartWait 1200 10 | Write-Verbose

	Check-SAPInstance @PSBoundParameters
}

function Stop-SAPInstance {

	# Stop SAP Instance
	Param (
		[Parameter(Mandatory)][string] $SAPControl,
		[Parameter(Mandatory)][string] $User,
		[Parameter(Mandatory)][string] $Pass,
		[int] $Grace = 0
	)

	$Nr = Get-SAPNr $SAPControl

	Write-Host "Stopping SAP Instance $Nr"
	& $SAPControl -nr $Nr -user $User $Pass -function Stop $Grace | Write-Verbose
	& $SAPControl -nr $Nr -user $User $Pass -function WaitforStopped 1200 10 | Write-Verbose

	Check-SAPInstance @PSBoundParameters
}

function Check-SAPInstance {

	# Get SAP Instance status
	Param (
		[Parameter(Mandatory)][string] $SAPControl,
		[Parameter(Mandatory)][string] $User,
		[Parameter(Mandatory)][string] $Pass,
		[int] $Grace = 0
	)

	$Nr = Get-SAPNr $SAPControl

	& $SAPControl -nr $Nr -user $User $Pass -function GetProcessList | Write-Verbose

	Switch ($LASTEXITCODE) {
		3 { Write-Host "Checking SAP Instance $Nr completed with status: Running" }
		4 { Write-Host "Checking SAP Instance $Nr completed with status: Stopped" }
		Default { Write-Host "Checking SAP Instance $Nr completed with status: Error" }
	}

	Return $LASTEXITCODE
}

function Start-WINService {

	# Start a Service
	Param (
		[Parameter(Mandatory)][string] $Name
	)

	Write-Host "Starting Service '$Name'"
	Start-Service -Name $Name -WarningAction SilentlyContinue -ErrorAction Stop | Write-Verbose

	Check-WINService @PSBoundParameters
}

function Stop-WINService {

	# Stop a Service
	Param (
		[Parameter(Mandatory)][string] $Name
	)

	Write-Host "Stopping Service '$Name'"
	Stop-Service -Name $Name -WarningAction SilentlyContinue -ErrorAction Stop | Write-Verbose

	Check-WINService @PSBoundParameters
}

function Check-WINService {

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


##############################
# Local
##############################
function Exit-Script {

	# Stop transcript and exit script
	Try {
		Stop-Transcript | Out-Null
	}
	Catch {
		# Not logging
	}
	Finally {
		Exit
	}
}

function Invoke-Action {

	Param (
		[Parameter(Mandatory)][string] $Command
	)

	try {
		$Command | Invoke-Expression
	}
	catch {
		Write-Error "Error calling function:`n$Command`n$_"
	}
}

##############################
# Main
##############################

$ScriptName = $MyInvocation.MyCommand.Name -Replace '\..*',''

# Start log transcript
if (!$NoLogging) {
	try {
		Start-Transcript -Path "$LogDir\$($ScriptName)_$(Get-Date -Format FileDate).log" -Append | Out-Null
		Get-ChildItem -Path $LogDir -Filter "$ScriptName*.log" -ErrorAction Stop |
			Where {$_.LastWriteTime -lt (Get-Date).AddDays(-7)} |
			Remove-Item
	}
	catch {
		Write-Verbose $_
		Write-Host "Error Starting log transcript (Exit-Code:2)"
		Exit-Script
	}
}

# Read configuration file
try {
	$CmdList = [string[]] (Get-Content -Path $Config -ErrorAction Stop | Where {$_ -notmatch '^#.*' -and $_ -notmatch '^\s*$'})
}
catch {
	Write-Verbose $_
	Write-Host "Error reading configuration file: $Config (Exit-Code:2)"
	Exit-Script
}

# Perform actions
Write-Host "[$(Get-Date) $(hostname) $PSCommandPath $Action (Version $VERSION)]"

$rc = 0
Switch ($Action) {

	"Start" {
		for ($i = 0; $i -lt $CmdList.Count; $i++) {
			$rc += Invoke-Action "Start-$($CmdList[$i])"
		}
	}

	"Stop" {
		for ($i = $CmdList.Count-1; $i -ge 0; $i--) {
			$rc += Invoke-Action "Stop-$($CmdList[$i])"
		}
	}

	Default {
		for ($i = 0; $i -lt $CmdList.Count; $i++) {
			$rc += Invoke-Action "Check-$($CmdList[$i])"
		}
	}
}

# Finalize results of check
Switch ($($rc / $CmdList.Count)) {
	3 { Write-Host "(Exit-Code:3)" }
	4 { Write-Host "(Exit-Code:4)" }
	Default { Write-Host "(Exit-Code:2)" }
}

Exit-Script
