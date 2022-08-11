# Record a video of the Amazon Linux 2 streaming instances screen in AppStream 2.0

These scripts let you record a video of the Amazon Linux 2 streaming instances screen in AppStream 2.0 using [FFmpeg](https://ffmpeg.org/). For more information, see the original AWS Security Blog Post [How to record a video of Amazon AppStream 2.0 streaming sessions](https://aws.amazon.com/fr/blogs/security/how-to-record-video-of-amazon-appstream-2-0-streaming-sessions/) for Windows streaming instances, and the more recent Medium blog post [How to record system operator activities on AWS using Amazon AppStream 2.0 and Session Manager](https://medium.com/@malavaln/762216cd66f0).

## The solution scripts

In this section, I go into the details of each of the Bash scripts that compose the solution.

### Before the streaming session begins (`system-start.sh`)

The solution runs the following script as root before streaming sessions start. We install the latest version of the AWS CLI and the Session Manager plugin for the AWS CLI.

```
cd /tmp

echo "Installing the last version of AWS CLI"
mkdir awscliv2
cd awscliv2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install
cd ..
rm -rf awscliv2

echo "Installing the Session Manager plugin"
mkdir session-manager-plugin
cd session-manager-plugin
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm" -o "session-manager-plugin.rpm"
yum install -y session-manager-plugin.rpm
cd ..
rm -rf session-manager-plugin
```

We wait until the streaming user session is active, i.e. when there is an active Linux session running GNOME. We retrieve dynamically the name of the Linux user used by the AppStream 2.0 user (currently `as2-streaming-user`) and the X server (Linux display server) to record (currently `:0`) although I don't except these values to change in the future.

```
COUNTER=0
echo "Waiting until the AppStream 2.0 session is ready"
while [ -z "$APPSTREAM_USERNAME" ] || [ -z "$DISPLAY" ]; do

	# List the active user sessions that run GNOME
	W_OUTPUT=$(PROCPS_USERLEN=30 w -h | grep gnome | grep -v grep)

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
```

We share the X server executed by the AppStream 2.0 user with the root user, so that the root user can run FFmpeg and record the session screen. By running FFmpeg as root, the AppStream 2.0 user is prevented from stopping or tampering with the solution, as long as it isn’t granted local administrator rights.

```
echo "Sharing display $DISPLAY owned by $APPSTREAM_USERNAME with root"
su - $APPSTREAM_USERNAME -c "DISPLAY=$DISPLAY xhost +si:localuser:root"
```

The script launches a second "long-running" script as root, shown following, that will run until the streaming session ends.

```
chmod +x /opt/appstream/SessionScripts/long-running.sh
nohup /opt/appstream/SessionScripts/long-running.sh > /root/long-running.log $DISPLAY 2>&1 &
```

### During the streaming session (`long-running.sh`)

AppStream 2.0 provides [metadata about users, sessions, and instances](https://docs.aws.amazon.com/appstream2/latest/developerguide/customize-fleets.html#customize-fleets-user-instance-metadata) in a file with environment variables that can be loaded with `source`. The script writes the metadata to a text file and uploads it to Amazon S3. We include the date, the system operator's username, and the session ID in the S3 prefix, so that you can easily find recordings.

```
source /opt/appstream/SessionScripts/variables.sh
source /etc/profile.d/appstream_user_vars.sh
source /etc/profile.d/appstream_system_vars.sh

CURRENT_DATE=$(date '+%Y/%m/%d')
S3_PATH_PREFIX="s3://${BUCKET_NAME}/${BUCKET_PREFIX}${CURRENT_DATE}/${AppStream_UserName}/${AppStream_Session_ID}/"
echo "Files will be uploaded to ${S3_PATH_PREFIX}"

echo "Logging session metadata into S3"
cat > /root/metadata.txt <<EOF
{
    "StackName": "${AppStream_Stack_Name}",
    "UserAccessMode": "${AppStream_User_Access_Mode}",
    "SessionReservationDateTime": "${AppStream_Session_Reservation_DateTime}",
    "UserName": "${AppStream_UserName}",
    "SessionId": "${AppStream_Session_ID}",
    "InstanceType": "${AppStream_Instance_Type}",
    "FleetName": "${AppStream_Resource_Name}"
}
EOF
aws s3 cp /root/metadata.txt ${S3_PATH_PREFIX} --region ${BUCKET_REGION} --profile=appstream_machine_role
```

The script then repeats the following set of commands every second, in an infinite loop.

```
while true; do

	# Check if FFmpeg is running
	if [ -z "$FFMPEG_PID" ]; then
		FFMPEG_RUNNING="false"
	else
		ps -p $FFMPEG_PID > /dev/null && FFMPEG_RUNNING="true" || FFMPEG_RUNNING="false"
	fi

	# Launch FFmpeg in the background if it is not running
	if [ "$FFMPEG_RUNNING" == "false" ]; then
		start_recording
	fi

	# Stop FFmpeg if the resolution changed
	CURRENT_RESOLUTION=$(xdpyinfo | awk '/dimensions/ {print $2}')
	if [ "$(get_screen_resolution)" != "$RECORDED_RESOLUTION" ]; then
		stop_recording
	fi

	# Upload the completed videos to S3
	upload_videos_to_s3

	# Exit gracefully if a signal SIGINT is received
	if [ "$SESSION_IS_CLOSING" == "true" ]; then

		stop_recording

		# Wait until FFmpeg closes
		while ps -p $FFMPEG_PID > /dev/null; do
			sleep 1
		done

		# Reset the video number to upload the last recorded video
		VIDEO_NUMBER=0
		upload_videos_to_s3

		exit 0

	fi

	# Wait one second until the next iteration
	sleep 1

done
```

During each loop iteration, these actions happen:

* The script launches FFmpeg if no FFmpeg process exists, or if it has exited. We configure FFmpeg to capture FRAME_RATE frames per second, and to produce one video file every VIDEO_MAX_DURATION seconds. The default value are, respectively, 5 frames per second and 300 seconds. You can adapt these values to your own needs. The file name is `video-{N}.mp4` with the `{N}` the index of the video file.

```
start_recording() {

	let VIDEO_NUMBER=VIDEO_NUMBER+1

	RECORDED_RESOLUTION="$(get_screen_resolution)"

	/root/ffmpeg \
		-framerate $FRAME_RATE -t $VIDEO_MAX_DURATION -f x11grab -y -i $DISPLAY \
		-vcodec libx264 -pix_fmt yuv420p /root/video-${VIDEO_NUMBER}.mp4 \
		> /root/ffmpeg-${VIDEO_NUMBER}.log 2>&1 &

	# Get PID of the FFmpeg executable launched in background
	FFMPEG_PID=$!

	echo "Launched FFmpeg - PID ${FFMPEG_PID} - Resolution ${RECORDED_RESOLUTION}"

}
```

* We check whether the screen resolution changed. When FFmpeg starts recording, it captures the area covered by the desktop at that time. If the resolution changes, a portion of the desktop might be outside the recorded region. In that case, we stop FFmpeg by sending a SIGTERM signal. FFmpeg will be restarted during the next loop iteration.

```
stop_recording() {

	echo "Stopping FFmpeg - PID ${FFMPEG_PID}"
	kill $FFMPEG_PID

}
```

* The script uploads the video files that exist in the local disk to S3, except the video file that is being written by the current FFmpeg process. Once the upload succeeds, we remove the video files from the local disk.

```
upload_videos_to_s3() {

	# Upload all videos except the video currently being recorded
	aws s3 cp /root/video-*.mp4 ${S3_PATH_PREFIX} --exclude /root/video-${VIDEO_NUMBER}.mp4 \
	--region ${BUCKET_REGION} --profile=appstream_machine_role

	# Delete the uploaded files if the upload succeeds
	if [ $? -eq 0 ]; then
		find /root/ -name "video-*.mp4" | grep -v "video-${VIDEO_NUMBER}.mp4" | xargs rm -f
	fi

}
```

* The last command in the loop is discussed in the next section.

### After the streaming session ends (`system-stop.sh`)

AppStream 2.0 runs a third script as root after the streaming sessions ends. This script sends a SIGTERM signal to the second script, to notify it that the session ended. Then, the third script waits until the second script closes.

```
# Send a signal to the long-running script so it can exit gracefully
LR_PID=$(ps ax | grep "long-running.sh" | grep -v grep | awk '{print $1}')
kill $LR_PID

# Wait until the long-running script terminates
while ps -p $LR_PID > /dev/null; do
	sleep 1
done
```

The second script catches the signal and exits gracefully, i.e. it closes FFmpeg and it uploads the last video to S3.

```
trap catch_signal SIGTERM

catch_signal () {

	echo "Received termination signal"
	SESSION_IS_CLOSING="true"

}
```
