#!/bin/bash

echo "Waiting 5 seconds for the session to be ready to avoid recording a black screen"
sleep 5

# Load the environment variables
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

export DISPLAY=$1 # Retrieve the display from the command argument
VIDEO_NUMBER=0 # Index of the current video file (video-[VIDEO_NUMBER].mp4)

get_screen_resolution() {

	xdpyinfo | awk '/dimensions/ {print $2}'

}

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

stop_recording() {

	echo "Stopping FFmpeg - PID ${FFMPEG_PID}"
	kill $FFMPEG_PID

}

upload_videos_to_s3() {

	# Upload all videos except the video currently being recorded
	aws s3 cp /root/video-*.mp4 ${S3_PATH_PREFIX} --exclude /root/video-${VIDEO_NUMBER}.mp4 \
	--region ${BUCKET_REGION} --profile=appstream_machine_role

	# Delete the uploaded files if the upload succeeds
	if [ $? -eq 0 ]; then
		find /root/ -name "video-*.mp4" | grep -v "video-${VIDEO_NUMBER}.mp4" | xargs rm -f
	fi

}

# Catch the SIGTERM and exit gracefully
trap catch_signal SIGTERM

catch_signal () {

	echo "Received termination signal"
	SESSION_IS_CLOSING="true"

}

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

	# Exit gracefully if a signal SIGTERM is received
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
