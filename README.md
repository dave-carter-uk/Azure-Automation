# Azure-Automation
Automate Start/Stop/Check of VM's and applications running in Azure

Schedule Runbook (azvmcontrol.ps1) to Start/Stop or Check VM's and applications running on the VM

The Runbook calls a local host command if specified on each VM to either Start/Stop or Check the applications on that host

![image](https://github.com/user-attachments/assets/9eef6b4b-244c-419d-80f1-68c38a95de78)

## VM Tags
The following tags are added to each VM within Azure and are used by the Runbook to identify VM’s related to a system group.

**AutoGroup**<br/>
Used to group related VM’s. The AzVMControl.ps1 RunBook uses this tag to identify all VM’s belonging to a system group.

**AutoPriority**<br/>
Used to group the order in which Applications are processed:<br/>
On start: VM’s / Applications are processed in ascending AutoPriority order<br/>
On stop: VM’s / Applications are processed in descending AutoPriority order

**AutoCommand**<br/>
Local VM command to Start/Stop/Check applications running on that VM. The AzVMControl Runbook calls this local command with parameter option: start/stop or check according to the Runbook action

## RunBook
The RunBook is provided as a PowerShell script called AzVMControl.ps1, the RunBook can parameterised and scheduled to control the start and stop of systems according to a defined schedule.

The RunBook will identify all VM’s matching the AutoGroup tag. It will process each VM in order as assigned by the AutoPriority tag by calling a local control script on that VM to either start, stop or check the applications and services on that VM, the Runbook will also Stop/Start the VM.

### Dependent Azure Modules
* Az.Account
* Az.Compute
* Az.Automation
* Az.Resources

### Parameters
	-Group <string>
	[Mandatory] Match VM’s belonging to the AutoGroup tag

	-Action [start|stop|check]
	RunBook action

	-Exclude [vm|app]
	Instructs the Runbook to exclude either VM’s or Applications from processing

	-Ignore [Mo,Tu,We,Th,Fr,Sa,Su]
	Azure runbooks can be scheduled for either: Daily, Weekly or Monthly. There is no option to specify specific days. The Skip parameter can be used to run a schedule daily but skip processing on certain days

	-VMPriority0 | -VMP0
	A switch instructs the Runbook to process all VM’s as a Priority 0 group. With this switch present all VM’s are started and stopped as a group, applications are still processed in priority order

	-VMStatus <string>(Default - Start: ‘VM running’, Stop: ‘VM deallocated’, Check: No default)
	Provide the expected VM status, mainly used with the check action option to produce an error if the VM’s status does not return the expected status

	-AppStatus <string> (Default – Start: ‘Running’, Stop: ‘Stopped’, Check: No default)
	Provide the expected Application status, mainly used with the check action option to produce an error if the application status does not return the expected status

 	-SubscriptionId <string>
  	Subscription ID. If not specified, the current subscription of automation account is used instead

**Output**<br/>
Output written to the Output windows of the Azure job Portal

### Examples
	AzVMControl.ps1 -Group DEV -Action start -Ignore Sa,Su
	Start all VM’s and Applications belonging to group DEV. Skip all processing on both Saturday and Sunday

	AzVMControl.ps1 -Group XYZ -Action stop
	Stop all VM’s and Applications on the VM’s belonging to SID group XYZ

	AzVmControl.ps1 -Group TRN -Action check -VMStatus ‘VM running’ -AppStatus ‘Running’
	Check the status of VM’s and applications for systems belonging to group TRN. Return an error if either the VM’s are not running or the Applications are not running

	AzVMControl.ps1 -Group XYZ -Action start -Exclude APP -VMP0
	Start only the VM’s, all VM’s are started in parallel

	AzVMControl.ps1 -Group XYZ -Action stop -VMP0
	Stop all applications in priority order, once the applications are stopped stop all VM’s in parallel

	AzVMControl.ps1 -Group XYZ -Action check -Exclude VM -VMStatus 'VM deallocated'
	Check all XYZ VM's expect to see a return of 'VM deallocated' runbook error if not, result can be captured in alert
 
	AzVMControl.ps1 -Group XYZ -Action check -VMStatus 'VM running' -AppStatus 'Running'
	Check all VM's and applications running, error if not

## VM Prioritisation
VM's are grouped by tag AutoGroup and given a priority via the AutoPriority tag, the Runbook will process each Priority group in parallel working in ascending AutoPriority order on Start and descending AutoPriority order on Stop.

**Example 1**<br/>
A three tier BW SAP system can be defined as follows:

|VM|Usage|AutoGroup|AutoPriority|
|--|-----|---------|------------|
|BWDBHOST|BW Database Host|DEV|1|
|BWASCSHOST|BW ASCS Host|DEV|1|
|BWAPPHOST1|BW Instance|DEV|2|
|BWAPPHOST2|BW Instance|DEV|2|
|BWAPPHOST3|BW Instance|DEV|2|

This system group is identified by the AutoGroup tag “DEV”. 
The database and ASCS instance VM’s are started first simultaneously, followed by the the application instance hosts which are then started simultaneously.

A stop action performs the same process but in reverse Priority order

**Example 2**<br/>
Expanding on Example 1, a Business Objects and Business Objects Data Services systems are added to the landscape, these system are dependent on the BW system
We have also added an AutoCommand to be called as part of the start or stop process

|VM|Usage|AutoGroup|AutoPriority|AutoCommand|
|--|-----|---------|------------|-----------|
|BWDBHOST|BW Database Host|DEV|1|/usr/sap/azcontrol.sh $action|
|BODBHOST|BO Database Host|DEV|1|C:\usr\sap\azcontrol.ps1 $action|
|DSDBHOST|DS Database Host|DEV|1|C:\usr\sap\azcontrol.ps1 $action|
|BWASCSHOST|BW ASCS Host|DEV|1|C:\usr\sap\azcontrol.ps1 $action|
|BWDAPPHOST1|BW Instance Host|DEV|2|C:\usr\sap\azcontrol.ps1 $action|
|BWDAPPHOST2|BW Instance Host|DEV|2|C:\usr\sap\azcontrol.ps1 $action|
|BWDAPPHOST2|BW Instance Host|DEV|2|C:\usr\sap\azcontrol.ps1 $action|
|BOAPPHOST|BO SIA+WEB|DEV|3||
|DSAPPHOST|DS SIA+WEB|DEV|3||

*No AutoCommand is set for BOAPPHOST and DSAPPHOST because the BO services are configured to auto start*

In this example all the database servers are started first, followed by the BW application instance servers and finally the BO and BO dataservices instances.

A stop action performs the same process but in reverse autoPriority order

## AutoCommand
Runbook calls the command identified by tag:AutoCommand and provides parameter start,stop or check.

The command can be any script to be ran on the host VM to perform the required action.

Scripts are ran as NT/SYSTEM user for Windows and root user for Linux.


**Example:**
- Windows	Tag:autoCommand = C:\azscripts\azcontrol.ps1 $Action
- Linux		Tag:autoCommand = /azscripts/azcontrol.sh $Action

Runbook will substitue the term '$Action' with either start, stop or check.

### Script Output
The Runbook identifies the output from the AutoCommand script by looking for the string (Exit*:*)

For example:

- Include (Exit:3) or (Exit: Running) in the output to indicate that all applications are running successfully<br/>
Example: “All SAP systems successfully running. (Exit:3)”

- Include (Exit-Code:4) or (Exit-Code: Stopped) in the output to indicate that all application are stopped successfully<br/>
Example: “All SAP systems successfully stopped. (Exit-Code: Stopped)”

The following exit codes can be used.(Exit*:*)
-	'' No Exit code supplied
-	0 / Success	The command completed successfully
-	1 / Warning	The command completed with warnings
-	2 / Error	The command completed with errors
-	3 / Running	The command completed with a running status
-	4 / Stopped	The command completed with a stopped status


https://github.com/dave-carter-uk/Apps-Stop-Start-Control provides some example scripts

