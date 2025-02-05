#!/usr/bin/bash

# appcontrol.sh wrapper

$(dirname $0)/appcontrol.sh $* 2>&1 | tee -a $(dirname $0)/logs/azcontrol_$(date +'%Y%m%d').log

# Delete old log files
find $(dirname $0)/logs -name azcontrol*.log -mtime +7 -type f -delete
