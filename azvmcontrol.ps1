<#PSScriptInfo

.DESCRIPTION Azure Automation Runbook Script to start or stop applications and VM's

.AUTHOR David Carter

.TAGS Azure Automation Runbook VM Applicaiton Start Stop SAP HANA

.PARAMETER
	-Group <[mandatory]string>
	String to identify VM's tagged by the autoGroup tag

	-Action <start|stop[|check]>
	Action to be performed on the VM's identified by -Group

	-Exclude <vm|app>
	Excludes either the VM or applications from processing

	-Ignore <Mo|Tu|We|Th|Fr|Sa|Su>
	Skip processing on specified day(s)

	-VMPriority0 | -VMP0 [switch]
	Instructs the runbook to process all VM's as Priority 0 i.e.: Start all VM's in parallel or Stop all VM's in parallel. Without this option VM's
	are processed in autoPriority order. This option can be useful when there is no dependency between VM's within a group. The applications can be started or
	stopped in AutoPriority order with the VM's being start/stopped as a group.

	-VMStatus <string> (Default: Start - 'VM running', Stop - 'VM deallocated')
	Set the desired VM return status. Used for -Action:Check to cause runbook to issue an error if desired status not received

	-AppStatus <string> (Default: Start - 'Running', Stop - 'Stopped')
	Set the desired App return status. Used for -Action:Check to cause runbook to issue an error if desired status not received

.AZURETAGS
	Tag VM's with following tags to be read by runbook

	autoGroup [string]
	Group related VM's

	autoPriority [int]
	Provide the VM with a priority within the group
	Action:Start - process in ascending autoPriority order
	Action:Stop - process in descending autoPriority order
	Example:
	DBHOST = autoPriority:1, AppHost1 = autoPriority:2, AppHost2 = autoPriority:2
	On Start DBHOST started and then AppHost1 and AppHost2 started in parallel
	On Stop AppHost1 and AppHost2 stopped and then DBHost stopped

	autoCommand [string]
	Provide a command to be called by the runbook to run on the local host. The runbook replaces $Action with the runbook book action, example:
	autoCommand = "C:\azscripts\azcontrol.ps1 $action"
	On Start the command "C:\azscripts\azcontrol.ps1 start" is called on the VM
	On Stop the command "C:\azscripts\azcontrol.ps1 stop" is called on the VM

.EXAMPLES
	% AzVMControl.ps1 -Group XYZ -Action Start
	Start all applications and VM's tagged with autoGroup:XYZ. Process in ascending autoPriority order

	% AzVMControl.ps1 -Group XYZ -Action Stop
	Stop all applications and VM's tagged with autoGroup:XYZ. Process in descending autoPriority order

	% AzVMControl.ps1 -Group XYZ -Action Start -Ignore Sa,Su
	Runbook scheduled daily, start VM's but don't start on Saturday or Sunday

	% AzVMControl.ps1 -Group XYZ -Action Start -Exclude App
	Start VM's tagged with autoGroup:XYZ but don't call local application control to start the applications, only VM's are started

	% AzVMControl.ps1 -Group XYZ -Action Stop -Exclude VM
	Stop applications on XYZ group VM's in descending autoPriority order, only applications are stopped

	% AzVMControl.ps1 -Group XYZ -Action check -Exclude VM -VMStatus 'VM deallocated'
	Check all XYZ VM's expect to see a return of 'VM deallocated' runbook error if not, result can be captured in alert

	% AzVMControl.ps1 -Group XYZ -Action check -VMStatus 'VM running' -AppStatus 'Running'
	Check all VM's and applications running, error if not

.LOCALCOMMANDS
	A local VM command identified by VM tag autoCommand is called by the runbook against that VM and is used to control the start/stop or check of applications
	and services running on that command.
	The command must at least take the option action as a parameter (start/stop/check) which is provided by the calling runbook via $action parameter substitution

	The results of the command are captured by the runbook, the string (Exit*:<status>) can be used within the local command output to provide the runbook with
	the command exit status

	The following exit statuses are recognised by the runbook:
	<Null>		No Exit code supplied
	0 or Success	The command completed successfully
	1 or Warning	The command completed with warnings
	2 or Error	The command completed with errors
	3 or Running	The command completed with a running status
	4 or Stopped	The command completed with a stopped status

	Example:
	>> Starting SAP Applications completed with (Exit-Code: Running)
	Instructs the runbook that all SAP applications are running. (Exit: 3) is equivalent

	>> Stopping SAP Applications completed with (Exit: Stopped)
	Instructs the runbook that all SAP applications are stopped. (Exit: 4) is equivalent

	>> An error has occured (Exit: 2)
	Instructs the runbook that an error has occured in the local VM command. (Exit: Error) is equivalent
#>

Param (
	[Parameter(Mandatory)][string] $Group,
	[Parameter(Mandatory)][string] $Action,
	[ValidateSet('vm','app')][Alias('Skip')][string] $Exclude,
	[ValidateSet('Mo','Tu','We','Th','Fr','Sa','Su')][Alias('IgnoreDays')][string[]] $Ignore,
	[Alias('VMPriority0')][switch] $VMP0,
	[string] $VMStatus = $Null,
	[string] $AppStatus = $Null
)

$VERSION = "1.1"

# Disable general verbose - Verbose can be controlled from Azure Runbook settings
$VerbosePreference = "SilentlyContinue"

##
# Functions
###

function Expand-String {

	# Substitute $parameters in string
	Param(
		[string] $Text,
		[object] $Params
	)

	[regex]::Replace($Text, '\$(\S*)', { 
		$x = $Params[$ARGS[0].Groups[1].Value]
		if ($x) { $x } else { $ARGS[0].Value }
	})	
}

function Get-ExitValue {

	# Return exit value if code specified
	Param (
		[string] $Code = ""
	)

	Switch ($Code) {
		"" { "OK" }
		0 { "Success" }
		1 { "Warning" }
		2 { "Error" }
		3 { "Running" }
		4 { "Stopped" }
		Default { $Code } 
	}
}

function Get-Summary {

	# Summarise a property value
	Param (
		[Parameter(Mandatory)][string] $Property,
		[Parameter(Mandatory, ValueFromPipeline)][Object[]] $InputObject
	)

	# Piped input ?
	if ($MyInvocation.ExpectingInput) {
		$InputObject = @($Input)
	}

	(($InputObject).$Property | Group-Object).Name -Join '/' -Replace '^(.*?\/.*?\/).*$', '$1...'
}

function Get-VMStatus {

	# Return VM Status include wait if specified
	Param (
		[Parameter(Mandatory, ValueFromPipelineByPropertyName)][string] $Name,
		[Parameter(Mandatory, ValueFromPipelineByPropertyName)][string] $ResourceGroupName,
		[string] $WaitStatus = $Null,
		[int] $TimeOut = 600,
		[int] $Delay = 10
	)

	Begin {
		$End = $(Get-Date).AddSeconds($TimeOut)
	}

	Process {
		While ($True) {

			$VMStatus = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -Status).Statuses[1].DisplayStatus

			if (($WaitStatus -eq $Null) -Or ($VMStatus -Match $WaitStatus)) {
				Break
			}
			
			if ($(Get-Date) -ge $End) {
				Write-Error "$Name '$VMStatus' timeout! Status '$WaitStatus' not reached after $TimeOut seconds"
				Break
			}

			Start-Sleep $Delay
		}

		# Pass through
		[PSCustomObject] @{ Name = $Name; Status = $VMStatus }
	}
}

function Invoke-VMCmdGroup {

	# Submit remote commands in parallel
	Param(
		[Parameter(Mandatory, ValueFromPipelineByPropertyName)][string] $Name,
		[Parameter(Mandatory, ValueFromPipelineByPropertyName)][string] $ResourceGroupName,
		[Parameter(Mandatory, ValueFromPipelineByPropertyName)][string] $Command
	)

	Begin {
		$jobdb = @{}
		$jobs = @()
	}

	Process {

		# Build run command
		$VMOSType = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name).StorageProfile.OSDisk.OSType
		$CmdId = $VMOSType -eq "Windows" ? "RunPowerShellScript" : "RunShellScript"

		# Submit remote command job
		$j = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $Name -CommandId $CmdId -ScriptString $Command -AsJob

		# Store job details
		$jobs += $j
		$jobdb[$j.Id] = [PSCustomObject] @{
			Name = $Name
			State = $Null
			ExitValue = $Null
			Duration = 0
			Command = $Command
		}
	}

	End {
		# Wait for jobs to finish
		$jobs | Wait-Job | Out-Null

		# Process completed jobs
		foreach ($j in $jobs) {

			Try {
				# Store job run status and duration
				$jobdb[$j.Id].State = $j.State
				$jobdb[$j.Id].Duration = [math]::Round(($j.PSEndTime - $j.PSBeginTime).TotalSeconds, 2)

				# Receive job output. Stop on error
				$o = Receive-Job -Id $j.Id -ErrorAction Stop

				# Get stdout
				$stdout = $o.Value[0].Message

				# Get value from stdout
				$ExitValue = Get-ExitValue(([regex]::Match($stdout, "\(Exit.*?:\s*(?<Exit>\S*?)\)").Groups['Exit'].Value))

				# Write stdout
				Switch ($ExitValue) {
					"Warning" { Write-Warning "$($jobdb[$j.Id].Name):`n$stdout" }
					"Error" { Write-Error "$($jobdb[$j.Id].Name):`n$stdout" }
					Default { Write-Verbose "$($jobdb[$j.Id].Name):`n$stdout" -Verbose }
				}

				# Write stderr
				if ($o.Value[1].Message) {
					Write-Error "$($jobdb[$j.Id].Name):`n$($o.Value[1].Message)"
					$ExitValue = "Error"
				}
			}
			Catch {
				Write-Error "$($jobdb[$j.Id].Name):`n$($_.Exception.Message)"
				$ExitValue = "Error"
			}

			$jobdb[$j.Id].ExitValue = $ExitValue
		}

		# Clean up jobs
		$jobs | Remove-Job -Force | Out-Null

		Return $jobdb.Values
	}
}


##
# Main
###

$RunStart = Get-Date
Write-Output "[$RunStart] Running option $Action on $Group VM's (Version $VERSION):"

# Exit if today is to be ignored
if ($Ignore -Contains ([string](Get-Date).DayOfWeek).Substring(0,2)) {
	Write-Output "No processing on $((Get-Date).DayOfWeek). Skipping!!"
	Exit
}

Try {
	# Connect to Azure with system-assigned managed server identity
	Disable-AzContextAutosave -Scope Process | Out-Null
	$AzureContext = (Connect-AzAccount -Identity -ErrorAction Stop).context
	$AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext -ErrorAction Stop
}
Catch {
	Write-Output "Azure login failed - see Exceptions"
	Throw "Azure loging failed: $($_.Exception.Message)"
}

# Get all VM's belonging to this group, sometimes this doesn't work first time so try 3 times
$Attempts = 0
While ($True) {

	# Obtain a list of VM's select just the object properties we are interested in
	# VMObject:
	#	Name:			VM Name
	#	ResourceGroupName:	Resource group name
	#	Priority:		VM Priority
	#	Command:		Command to execute on remote host

	$VMList = Get-AzResource -ResourceType "Microsoft.Compute/virtualMachines" -Tag @{"AutoGroup" = $Group} | 
		Select-Object -Property Name,
			ResourceGroupName,
			@{L="Priority"; E={[int]$_.Tags.AutoPriority}},
			@{L="Command"; E={$(Expand-String -Text $_.Tags.AutoCommand -Params @{Action = $Action})}}

	if ($VMList -ne $Null) {
		Break
	}

	if ($Attempts -ge 3) {
		Write-Output "Failed to get VM's in group $Group after 3 attempts - see Exceptions"
		Throw "Failed to get VM list: $($_.Exception.Message)"
	}

	Start-Sleep 5
	$Attempts++
}

# Display VM's found include their Status as well
$VMList | Sort-Object -Property Priority | Select-Object -Property Priority, Name, Command | Out-String

##
# Main
###
$Error.Clear()
Switch ($Action) {

	"Start" {

		$VMStatus = if ($VMStatus) { $VMStatus } else { 'VM running' }
		$AppStatus = if ($AppStatus) { $AppStatus } else { 'Running' }

		if ($VMP0) {
			Write-Output "Starting all VM's ..."
			$VMList | Start-AzVM -NoWait | Out-Null
			$vout = $VMList | Get-VMStatus -WaitStatus $VMStatus

			$vsum = $vout | Get-Summary Status
			Write-Output "All VM's start summary: $vsum"
			$vout | Format-Table | Out-String

			if ($vsum -ne $VMStatus) {
				Write-Error "All VM's Start failed - some VM's did not return status: $VMStatus"
			}
		}

		$VMList | Group-Object -Property Priority | Sort-Object -Property Name | Foreach {

			if (!$VMP0 -And ($Exclude -ne "vm")) {

				Write-Output "Group:$($_.Name) Starting VM's ..."
				$_.Group | Start-AzVM -NoWait | Out-Null
				$vout = $_.Group | Get-VMStatus -WaitStatus $VMStatus

				$vsum = $vout | Get-Summary Status
				Write-Output "Group:$($_.Name) VM's start summary: $vsum"
				$vout | Format-Table | Out-String

				if ($vsum -ne $VMStatus) {
					Write-Error "Group:$($_.Name) Start failed - some VM's did not return status: $VMStatus"
				}
			}

			if ($Exclude -ne "app") {

				Write-Output "Group:$($_.Name) Starting applications ..."
				$aout = $_.Group | Where-Object { $_.Command } | Invoke-VMCmdGroup
				if ($aout.Count -eq 0) {
					Write-Output "No apps to start"
					Return
				}

				$asum = $aout | Get-Summary ExitValue
				Write-Output "Group:$($_.Name) Application start summary: $asum"
				$aout | Format-Table | Out-String

				if ($asum -ne $AppStatus) {
					Write-Error "Group:$($_.Name) Start failed - some applications did not return status: $AppStatus"
				}
			}
		}	
	}

	"Stop" {

		$VMStatus = if ($VMStatus) { $VMStatus } else { 'VM deallocated' }
		$AppStatus = if ($AppStatus) { $AppStatus } else { 'Stopped' }

		$VMList | Group-Object -Property Priority | Sort-Object -Property Name -Descending | Foreach {

			if ($Exclude -ne "app") {

				Write-Output "Group:$($_.Name) Stopping applications ..."
				$aout = $_.Group | Where-Object { $_.Command } | Invoke-VMCmdGroup
				if ($aout.Count -eq 0) {
					Write-Output "No apps to stop"
					Return
				}

				$asum = $aout | Get-Summary ExitValue
				Write-Output "Group:$($_.Name) Application stop summary: $asum"
				$aout | Format-Table | Out-String

				if ($asum -ne $AppStatus) {
					Write-Error "Group:$($_.Name) Stop failed - some applications did not return status: $AppStatus"
				}
			}

			if (!$VMP0 -And ($Exclude -ne "vm")) {

				Write-Output "Group:$($_.Name) Stopping VM's ..."
				$_.Group | Stop-AzVM -NoWait -Force | Out-Null
				$vout = $_.Group | Get-VMStatus -WaitStatus $VMStatus

				$vsum = $vout | Get-Summary Status
				Write-Output "Group:$($_.Name) VM's stop summary: $vsum"
				$vout | Format-Table | Out-String

				if ($vsum -ne $VMStatus) {
					Write-Error "Group:$($_.Name) Stop failed - some VM's did not return status: $VMStatus"
				}
			}
		}

		if ($VMP0) {
			Write-Output "Stopping all VM's ..."
			$VMList | Stop-AzVM -NoWait -Force | Out-Null
			$vout = $VMList | Get-VMStatus -WaitStatus $VMStatus

			$vsum = $vout | Get-Summary Status
			Write-Output "All VM's stop summary: $vsum"
			$vout | Format-Table | Out-String

			if ($vsum -ne $VMStatus) {
				Write-Error "All VM's Stop failed - some VM's did not return status: $VMStatus"
			}
		}
	}

	"Check" {

		if ($Exclude -ne "vm") {

			Write-Output "Checking VM's ..."
			$vout = $VMList | Get-VMStatus
			$vsum = $vout | Get-Summary Status
			Write-Output "VM's Check summary: $vsum"
			$vout | Format-Table | Out-String

			if ($VMStatus -And ($vsum -ne $VMStatus)) {
				Write-Error "Check failed - some VM's did not return status: $VMStatus"
			}
		}

		if ($Exclude -ne "app") {

			Write-Output "Checking applications ..."
			$aout = $VMList | Where-Object { $_.Command } | Invoke-VMCmdGroup
			if ($aout.Count -eq 0) {
				Write-Output "No apps to check"
				Break
			}

			$asum = $aout | Get-Summary ExitValue
			Write-Output "Application check summary: $asum"
			$aout | Format-Table | Out-String

			if ($AppStatus -And ($asum -ne $AppStatus)) {
				Write-Error "Check failed - some applications did not return status: $AppStatus"
			}
		}
	}

	Default {
		Write-Output "Action: $Action not implemented"
	}
}

Write-Output "Running $Action on $Group VM's Completed. Elapsed Time: $([math]::Round(((Get-Date) - $RunStart).TotalSeconds,2)) seconds"

if ($Error) {
	Throw "Runbook fail see error log for details"
}

Exit
