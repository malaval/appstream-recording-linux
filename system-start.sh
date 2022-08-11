#!/bin/bash -e

echo "Installing applications as root"
chmod +x /opt/appstream/SessionScripts/install-apps.sh
/opt/appstream/SessionScripts/install-apps.sh

COUNTER=0
echo "Waiting until the AppStream 2.0 session is ready"
while [ -z "$APPSTREAM_USERNAME" ] || [ -z "$DISPLAY" ]; do

	# List the active user sessions that run GNOME
	W_OUTPUT=$(PROCPS_USERLEN=30 w -h | grep gnome | grep -v grep)

	# Retrieve the username of the AS2 Linux user and the display number used by
	# the X server. These values are currently "as2-streaming-user" and ":0".
	# I retrieve them dynamically, altough I don't expect them to change in the future.
	APPSTREAM_USERNAME=$(echo $W_OUTPUT | awk '{print $1}')
	DISPLAY=$(echo $W_OUTPUT | awk '{print $3}')

	# Wait maximum 15 seconds for the session to start
	if [ $COUNTER -eq 15 ]; then
		exit 1
	fi

	# Wait one second if the session is not yet ready until the next iteration
	let COUNTER=COUNTER+1
	sleep 1

done

# Share the AppStream 2.0 user screen with root, such that root can record it with FFmpeg
echo "Sharing display $DISPLAY owned by $APPSTREAM_USERNAME with root"
su - $APPSTREAM_USERNAME -c "DISPLAY=$DISPLAY xhost +si:localuser:root"

# Move FFmpeg and make it executable
mv /opt/appstream/SessionScripts/ffmpeg /root/ffmpeg
chmod +x /root/ffmpeg

# Launch the long-running script
chmod +x /opt/appstream/SessionScripts/long-running.sh
nohup /opt/appstream/SessionScripts/long-running.sh > /root/long-running.log $DISPLAY 2>&1 &
