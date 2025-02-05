#!/usr/bin/bash

VERSION="1.4"

# DESCRIPTION Start/Stop/Check local applications and resources on host
#
# AUTHOR David Carter
#
# PARAMETERS
#       <start|stop[|check]>
#       Action to perform on local host
#
# EXAMPLES
#       root> appcontrol.ps1 stop
#       Stop all applications described in $hostname.conf file
#
#       root> appcontrol.ps1 check
#       Check run status of all applications described in $hostname.conf file
#
#       see example conf files for details of configuration file format

##
#### Local help functions (functions called by the action handlers)
######

get-exitaverage () {

	# Evaluate average exit code
	local total=${1:-0}
	local count=${2:-1}
	local ec=$(awk "BEGIN {print $total/$count}")
	[[ $ec =~ ^[0-9]+$ ]] && echo $ec || echo 2
}

get-exitstatus () {

	case $1 in
		3) echo "Running" ;;
		4) echo "Stopped" ;;
		*) echo "Error" ;;
	esac
}

get-sapstatus () {

	# Return SAP system status
	local nr=${1:0-2}
	local sid=$(echo $1 | cut -d'/' -f4)
	local sidadm="${sid,,}adm"
	local host=${2:+"-host $2"}

	su -l $sidadm -c "$1/exe/sapcontrol $host -nr $nr -function GetProcessList" > /dev/null
	echo $?
}

get-HANAdetails () {

	# Return HANA cluster details
	/usr/sbin/SAPHanaSR-showAttr --format=script --cib=/var/lib/pacemaker/cib/cib.xml
}

get-HANAprimary () {

	# Return HANA primary host
	local primarysite=$(get-HANAdetails | sed -n 's/^Sites\/\(.*\)\/.*PRIM.*$/\1/p')
	get-HANAdetails | sed -n 's/^Hosts\/\(.*\)\/.*'$primarysite'.*$/\1/p'
}

get-HANAhosts () {

	# Return all HANA hosts
	get-HANAdetails | sed -n 's/^Hosts\/\(.*\)\/site.*$/\1/p'
}

##
#### Action handlers (<Start|Stop|Check>--Function [params])
######

start--SAPInstance () {

	# Start SAP system
	local nr=${1:0-2}
	local sid=$(echo $1 | cut -d'/' -f4)
	local sidadm="${sid,,}adm"

	echo "Starting SAP Instance $nr"
	su -l $sidadm -c "$1/exe/sapcontrol -nr $nr -function StartWait 1200 10" > /dev/null

	check--SAPInstance $@
}

stop--SAPInstance () {

	# Stop SAP
	local nr=${1:0-2}
	local sid=$(echo $1 | cut -d'/' -f4)
	local sidadm="${sid,,}adm"

	echo "Stopping SAP Instance $nr"
	su -l $sidadm -c "$1/exe/sapcontrol -nr $nr -function StopWait 1200 10" > /dev/null

	check--SAPInstance $@
}

check--SAPInstance () {

	# Check SAP system
	local nr=${1:0-2}
	local status=$(get-sapstatus $1)
	echo "Checking SAP Instance $nr completed with status: $(get-exitstatus $status)"
	return $status
}

start--HANACluster () {

	local primary=$(get-HANAprimary)
	if [ $primary != $(hostname) ]; then
		echo "Start to be ran on primary host: $primary"
		return 3
	fi

	echo "Starting HANA Cluster..."

	echo "[$primary] Start primary cluster node..."
	systemctl enable pacemaker &> /dev/null
	crm cluster start

	local HANAhosts=()
	readarray -t HANAhosts < <(get-HANAhosts)
	for host in "${HANAhosts[@]}"; do
		[[ $host == $primary ]] && continue
		echo "[$host] Start standby cluster node..."
		ssh $host systemctl enable pacemaker &> /dev/null
		ssh $host crm cluster start
	done

	# Wait fo SAP instances to start (can't use sapcontrol waitforstarted incase hdbdaemon not yet running)
	local waitend=$(( $(date +%s) + 1200 ))
	for host in "${HANAhosts[@]}"; do
		while [[ $(get-sapstatus $1 $host) -ne 3 && $(date +%s) -lt $waitend ]]; do
			sleep 15
		done
	done

	check--HANACluster $@
}

stop--HANACluster () {

	local primary=$(get-HANAprimary)
	if [ $primary != $(hostname) ]; then
		echo "Stop to be ran on primary host: $primary"
		return 4
	fi

	echo "Stopping HANA Cluster..."
	local HANAhosts=()
	readarray -t HANAhosts < <(get-HANAhosts)
	for host in "${HANAhosts[@]}"; do
		[[ $host == $primary ]] && continue
		echo "[$host] Stop standby cluster node..."
		ssh $host systemctl disable pacemaker &> /dev/null
		ssh $host crm cluster stop
	done

	echo "[$primary] Stop primary cluster node..."
	systemctl disable pacemaker &> /dev/null
	crm cluster stop

	check--HANACluster $@
}

check--HANACluster () {

	# Get cluster status
	local status
	case $(crm status simple 2>&1) in
		"CLUSTER OK"*) status=3 ;;
		*"rc=2"*) status=4 ;;
		*) status=2 ;;
	esac
	echo "HANA Cluster: $(get-exitstatus $status)"

	# Get HANA instance(s) status
	get-HANAhosts | while read -r host; do
		echo "$host HANA Instance $(get-exitstatus $(get-sapstatus $1 $host))"
	done

	return $status
}

##
#### Main
######
#o

if [ $(whoami) != "root" ]; then
	echo "This script should be ran as root user (Exit-Code:2)"
	exit
fi

config="$(dirname $0)/$(hostname).conf"
if [ ! -f $config ]; then
	echo "Config file: $config not found (Exit-Code:2)"
	exit
fi

action=$(echo $1 | tr '[:upper:]' '[:lower:]')
echo "[$(date) $(hostname) Script: $0 $* (Version $VERSION)]"
echo "[$(date) $(hostname) Config: $config]"

rc=0
readarray -t clist < <(grep -v "^#\|^\s*$" $config)
case $action in
	start)
		for (( i=0; i<${#clist[@]}; i++ )); do
			eval "start--${clist[$i]}"
			rc=$((rc + $?))
		done
	;;
	stop)
		for (( i=${#clist[@]}-1; i>=0; i-- )); do
			eval "stop--${clist[$i]}"
			rc=$((rc + $?))
		done
	;;
	*)
		for (( i=0; i<${#clist[@]}; i++ )); do
			eval "check--${clist[$i]}"
			rc=$((rc + $?))
		done
	;;
esac

# Finalise results
echo "(Exit-Code:$(get-exitaverage $rc ${#clist[@]}))"
