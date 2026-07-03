#!/bin/bash
#
# Launcher invoked by the MQ queue manager as a SERVICE definition.
# The queue manager name is passed as $1.

qMgr=$1

# Pick up libmqm.so etc - try local qmgr first, fall back to client mode.
. /opt/mqm/bin/setmqenv -m "$qMgr" -k >/dev/null 2>&1 \
  || . /opt/mqm/bin/setmqenv -s -k

ARGS="-ibmmq.queueManager=$qMgr"
ARGS="$ARGS -rediscoverInterval=1h"
ARGS="$ARGS -ibmmq.useStatus=true"
ARGS="$ARGS -log.level=error"
ARGS="$ARGS -ibmmq.httpListenPort=9158"

# files containing the queue / channel patterns to watch
mqprom_etc=/etc/mq-prometheus
ARGS="$ARGS -ibmmq.monitoredQueuesFile=$mqprom_etc/monitored-queues"
ARGS="$ARGS -ibmmq.monitoredChannelsFile=$mqprom_etc/monitored-channels"

# help Go produce useful stack traces on SEGV
export MQS_NO_SYNC_SIGNAL_HANDLING=true

# exec so the qmgr can track the pid through MQ_SERVER_PID
exec /usr/local/bin/mq_prometheus $ARGS
