# Azure-Automation
Automate Start/Stop/Check of VM's and applications running in Azure

Schedule Runbook (azvmcontrol.ps1) to Start/Stop or Check VM's and applications running on the VM

The Runbook calls azcontrol.ps1 (azcontrol.sh) on VM host to Start/Stop/Check the application status

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
Local VM command to Start/Stop/Check applications running on that VM. The AzVMControl Runbook uses parameter substitution to instruct the local command which action to process.

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

	-VMStatus [String](Default - Start: ‘VM running’, Stop: ‘VM deallocated’, Check: No default)
	Provide the expected VM status, mainly used with the check action option to produce an error if the VM’s status does not return the expected status

	-AppStatus [String] (Default – Start: ‘Running’, Stop: ‘Stopped’, Check: No default)
	Provide the expected Application status, mainly used with the check action option to produce an error if the application status does not return the expected status

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


## Local Control Script
A local control script identified by VM tag AutoCommand is located on each VM and is called by the AzVMControl Runbook to process Applications and Services located on that VM.
The control script may be different on each host depending on what applications and services that host is running but each script should follow the same parameters and output criteria.

**Example:**
- Windows	C:\azscripts\azcontrol.ps1 $Action
- Linux		/azscripts/azcontrol.sh $Action

The control script reads a local configuration file which defines the applications and services on that host

### Parameters
	start|stop|(check|*)<br/>
	The AzVMControl Runbook substitutes the $Action for the required control action

### Output
	Any processing information is written to STDOUT or STDERR
	The RunBook checks the output for a string to derive the success or failure of the scripts:

- Include (Exit:3) or (Exit: Running) in the output to indicate that all applications are running successfully<br/>
Example: “All SAP systems successfully running. (Exit:3)”

- Include (Exit:4) or (Exit: Stopped) in the output to indicate that all application are stopped successfully<br/>
Example: “All SAP systems successfully stopped. (Exit: Stopped)”

The following exit codes can be used.(Exit:*)
-	'' No Exit code supplied
-	0 / Success	The command completed successfully
-	1 / Warning	The command completed with warnings
-	2 / Error	The command completed with errors
-	3 / Running	The command completed with a running status
-	4 / Stopped	The command completed with a stopped status

When called from an Azure Runbook the local scripts are ran as NT/SYSTEM user for Windows and root user for Linux.

### Supported applications and services

-	SAPInstance	SAP system instance
-	WINService		Windows service
-	WINCluster		local cluster
-	HANACluster	HANA Cluster

### Configuration file
The local control script reads a configuration file stored in the same directory as the script and called *hostname*.conf. This configuration file describes the applications and services running on this host.<br/>
*See example files*

## VM Prioritisation
VM Applications within a group can be grouped into Priority via the AutoPriority tag the Runbook will process each Priority group in parallel working in ascending Priority on Start and descending Priority order on Stop.

**Example 1**<br/>
A three tier BW SAP system can be defined as follows:
![image](https://github.com/user-attachments/assets/01aed82d-c0b3-4c61-9f43-c78826ab2b69)


This system group is identified by the AutoGroup tag “DEV”. 
Applications on the database and ASCS instance VM’s are started first simultaneously , followed by the the application instance host which are then started simultaneously.

A stop action performs the same process but in reverse Priority order

**Example 2**<br/>
Expanding on Example 1, a Business Objects and Business Objects Data Services systems are added to the landscape, these system are dependent on the BW system
![image](https://github.com/user-attachments/assets/6e830fd3-4814-4fd1-b545-e253ded07742)



In this example all the database applications are started first, followed by the BW application instance and finally the BO and BO dataservices instances.

A stop action performs the same process but in reverse SAPPriority order

