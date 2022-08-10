#!/bin/bash

# Send a signal to the long-running script so it can exit gracefully
LR_PID=$(ps ax | grep "long-running.sh" | grep -v grep | awk '{print $1}')
kill $LR_PID

# Wait until the long-running script terminates
while ps -p $LR_PID > /dev/null; do
	sleep 1
done
