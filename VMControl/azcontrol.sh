#!/usr/bin/bash

VERSION="1.0"

##############################
# Control functions:
# Start-<Type>  Start
# Stop-<Type>   Stop
# Check-<Type>  Check
#
# Each function is called by the main processor and should return either:
# 2 / Error     - Error occurred
# 3 / Running   - All started and running
# 4 / Stopped   - All stopped
##############################

##############################
#
# Implementation:
# SAPInstance
# HANACluster
#
##############################
get-sapnr () {

	# Return SAP Instance number from path
	echo $(echo ${1:13} | grep -o -E '[0-9]+')
}

get-sidadm () {

	# Return SID adm user from path
	tolower "${1:9:3}adm"
}

tolower () {

	echo $1 | tr '[:upper:]' '[:lower:]'
}

toupper () {

	echo $1 | tr '[:lower:]' '[:upper:]'
}

get-exitValue () {

	case $1 in
		3) echo "Running" ;;
		4) echo "Stopped" ;;
		*) echo "Error" ;;
	esac
}

start-SAPInstance () {

	# Start SAP system
	local sapcontrol=$1

	local nr=$(get-sapnr $sapcontrol)
	local sidadm=$(get-sidadm $sapcontrol)

	echo "Starting SAP Instance $nr"
	su -l $sidadm -c "$sapcontrol -nr $nr -function StartWait 1200 10" > /dev/null

	check-SAPInstance $@
}

stop-SAPInstance () {

	# Stop SAP
	local sapcontrol=$1

	local nr=$(get-sapnr $sapcontrol)
	local sidadm=$(get-sidadm $sapcontrol)

	echo "Stopping SAP Instance $nr"
	su -l $sidadm -c "$sapcontrol -nr $nr -function StopWait 1200 10" > /dev/null

	check-SAPInstance $@
}

check-SAPInstance () {

	# Check SAP system
	local sapcontrol=$1

	local nr=$(get-sapnr $sapcontrol)
	local sidadm=$(get-sidadm $sapcontrol)

	su -l $sidadm -c "$sapcontrol -nr $nr -function GetProcessList" > /dev/null
	local status=$?
	echo "Checking SAP Instance $nr completed with status: $(get-exitValue $status)"

	return $status
}

get-cluster () {

	# Return cluster details
	/usr/sbin/SAPHanaSR-showAttr --format=script --cib=/var/lib/pacemaker/cib/cib.xml
}


get-primaryHost () {

	# Get cluster primary host
	local primarySite=$(get-cluster | sed -n 's/^Sites\/\(.*\)\/.*PRIM.*$/\1/p')
	get-cluster | sed -n 's/^Hosts\/\(.*\)\/.*'$primarySite'.*$/\1/p'
}

get-standbyHosts () {

	# Return standby hosts
	local primaryHost=$(get-primaryHost)
	get-cluster | sed -n 's/^Hosts\/\(.*\)\/site.*$/\1/p' | grep -v $primaryHost
}

start-HANACluster () {

	local sapcontrol=$1

	local primary=$(get-primaryHost)
	if [ $primary != $(hostname) ]; then
		echo "Start should be ran on primary host: $primary"
		return 3
	fi

	echo "[$(hostname)] Enable pacemaker on primary host (allow start on reboot)"
	systemctl enable pacemaker

	echo "[$(hostname)] Start Cluster on primary host"
	crm cluster start

	readarray -t standbys < <(get-standbyHosts)
	for s in $standbys; do
		echo "[$s] Enable pacemaker on standby host (allow start on reboot)"
		ssh $s systemctl enable pacemaker
		echo "[$s] Start cluster on standby host"
		ssh $s crm cluster start
	done

	# Return Clustered SAP instances status
	(echo $primary; IFS=$'\n'; echo $standbys) | wait-SAPInstance $sapcontrol 3
}

stop-HANACluster () {

	local sapcontrol=$1

	local primary=$(get-primaryHost)
	if [ $primary != $(hostname) ]; then
		echo "Stop should be ran on primary host: $primary"
		return 4
	fi

	readarray -t standbys < <(get-standbyHosts)
	for s in $standbys; do
		echo "[$s] Disable pacemaker on standby host (prevent start on reboot)"
		ssh $s systemctl disable pacemaker
		echo "[$s] Stop cluster on standby host"
		ssh $s crm cluster stop
	done

	echo "[$primary] Disable pacemaker on primary host (prevent start on reboot)"
	systemctl disable pacemaker
	echo "[$primary] stop cluster on primary host"
	crm cluster stop

	# Return Clustered SAP instances status
	(echo $primary; IFS=$'\n'; echo $standbys) | wait-SAPInstance $sapcontrol 4
}

wait-SAPInstance () {

	# Wait for SAP Instances to start/stop or timeout - can't use sapcontrol waitfor.. because HDB daemon might not be running

	local sapcontrol=$1
	local status=$2

	local nr=$(get-sapnr $sapcontrol)
	local sidadm=$(get-sidadm $sapcontrol)
	local end=$(( $(date +%s) + 1200 ))

	while read -r host; do
		while true; do
			if [ $(date +%s) -ge $end ]; then
				echo "$host SAP Instance $nr status: Timeout!"
				status=2
				break
			fi

			su -l $sidadm -c "$sapcontrol -host $host -nr $nr -function GetProcessList" > /dev/null
			if [ $? -eq $status ]; then
				echo "$host SAP Instance $nr status: $(get-exitValue $status)"
				break
			fi

			sleep 10
		done
	done

	return $status
}

check-HANACluster () {

	echo "Primary: $(get-primaryHost)"
	echo "Standbys: $(get-standbyHosts)"

	local status
	case $(crm status simple 2>&1) in
		"CLUSTER OK"*) status=3 ;;
		*"rc=2"*) status=4 ;;
		*) status=2 ;;
	esac

	echo "Cluster status: $(get-exitValue $status)"
	return $status
}

##############################
# Main
##############################
#

config="$(dirname $0)/$(hostname).conf"
action=$(tolower ${1:-check})

# Duplicate stdout & stderr to file
exec &> >(tee $(dirname $0)/logs/$action.log)

echo "$(hostname) Applications $action [$(date)] Version $VERSION"

if [ $(whoami) != "root" ]; then
	echo "This script should be ran as root user (Exit-Code:2)"
	exit
fi

if [ ! -f $config ]; then
	echo "Config file: $config not found (Exit-Code:2)"
	exit
fi

# Process
rc=0
readarray -t clist < <(grep -v "^#\|^\s*$" $config)
case $action in
	start)
		for (( i=0; i<${#clist[@]}; i++ )); do
			eval "start-${clist[$i]}"
			rc=$((rc + $?))
		done
	;;
	stop)
		for (( i=${#clist[@]}-1; i>=0; i-- )); do
			eval "stop-${clist[$i]}"
			rc=$((rc + $?))
		done
	;;
	*)
		for (( i=0; i<${#clist[@]}; i++ )); do
			eval "check-${clist[$i]}"
			rc=$((rc + $?))
		done
	;;
esac

# Finalise results
case $(awk "BEGIN {print $rc/${#clist[@]}}") in
	3) echo "(Exit-Code:3)" ;;
	4) echo "(Exit-Code:4)" ;;
	*) echo "(Exit-Code:2)" ;;
esac
