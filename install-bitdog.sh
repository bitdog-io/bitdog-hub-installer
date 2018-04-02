#!/bin/bash

#-----------------------------------------------------------------------------
#
#	install-bitdog.sh
#
#	Copyright (c) 2015-2017 Bitdog LLC.
#
#	SOFTWARE NOTICE AND LICENSE
#
#	This file is part of bitdog-hub.
#
#	bitdog-hub is free software: you can redistribute it and/or modify
#	it under the terms of the GNU General Public License as published
#	by the Free Software Foundation, either version 3 of the License,
#	or (at your option) any later version.
#
#	bitdog-hub is distributed in the hope that it will be useful,
#	but WITHOUT ANY WARRANTY; without even the implied warranty of
#	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#	GNU General Public License for more details.
#
#	You should have received a copy of the GNU General Public License
#	along with bitdog-hub.  If not, see <http://www.gnu.org/licenses/>.
#
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
#	install-bitdoghub -u <username> -p <passphrase> -n <nodename> [ -v ] [ -s ]
#
#   DESCRIPTION
#       This script will install the necessary packages and libraries for the
#       Bitdog Hub. It will also create the systemd scripts required for the hub
#       to start and stop automatically with any system reboot.
#
#		When the optional notification flag is included, this script will attempt
#       to send mobile notifications for each completed step.
#		
#   -u Bitdog cloud account username
#   -p Bitdog cloud passphrase used for hub to account pairing, this is not your password.
#   -n The name of this Bitdog Hub
#	-v Install video libraries and enable Bitdog Hub video for local Raspberry Pi camera
#   -s Send mobile notifications for each step of the install
#
#######################################################################################   

CONFIG=/boot/config.txt
NODEVERSION="v8.4.0"
BITDOGHUBBIN="node_modules/bitdog-hub/bin"

BITDOGHUB_USER="pi"
BITDOGHUB_GROUP="pi"

BITDOGHUB_HOME_DIR="/opt/bitdog"
BITDOG_HUB_INSTALLER_DIR=${BITDOGHUB_HOME_DIR}/installer
BITDOG_HUB_BIN_DIR=${BITDOGHUB_HOME_DIR}/bin
BITDOG_HUB_LOG_DIR=${BITDOGHUB_HOME_DIR}/logs
BITDOG_HUB_CONFIG_DIR=${BITDOGHUB_HOME_DIR}/config
BITDOG_HUB_DVR_DIR=${BITDOGHUB_HOME_DIR}/dvr

BITDOG_HUB_INSTALLER_URL="https://raw.githubusercontent.com/bitdog-io/bitdog-hub-installer/master/install-bitdog.sh"

VIDEO=0
NOTIFY=0

CPUCOUNT=$(grep -c "^processor" /proc/cpuinfo)
echo "This machine has ${CPUCOUNT} cores"

DISTRO=$(lsb_release -c -s)
echo "The distro is ${DISTRO}"

HARDWARE=$(uname -m)
echo "The hardware platform is ${HARDWARE}"

cd /tmp

while getopts u:n:p:vis option
  do
    case "${option}"
    in
      u) USERNAME=${OPTARG};;
      p) PASSPHRASE=${OPTARG};;
      n) HUBNAME=${OPTARG};;
      v) VIDEO=1;;
	  s) NOTIFY=1;;
   esac
done

### Video Setttings 

VIDEO_HEIGHT=480
VIDEO_WIDTH=640
VIDEO_STREAMER_PORT=9000
IPC_PORT=9001

if [ $CPUCOUNT -eq 1 ]
then
	# Low CPU count, reduce frame rate and use hardware based encoder that has lower quality 
	VIDEO_FRAME_RATE=15
	VIDEO_ENCODER="h264_omx"
else
	# High CPU count, increase frame rate and use software based encoder that has much better quality
	VIDEO_FRAME_RATE=30
    VIDEO_ENCODER="h264"
fi

if [ $VIDEO -eq 0 ]
then
	echo "No video selected, no video libraries will be installed"
	VIDEO_ENABLE="false"
else
	echo "Video option selected, video libraries will be installed"
	VIDEO_ENABLE="true"
fi



exists(){
  command -v "$1" >/dev/null 2>&1
}

do_notify() {
  echo "#########################################"
  echo "#                                        "
  echo "#   $1                                   "
  echo "#                                        "
  echo "#########################################"

  if [ $NOTIFY -eq 1 ]
  then
	curl -s -H "Accept: application/json" -H "Content-Type: application/json" -X POST -d "{ \"username\":\"${USERNAME}\", \"passphrase\": \"${PASSPHRASE}\", \"message\": \"$1\" }" https://bitdog.io/api/webhooks/installer/notify  | grep -q \"result\":true
  fi
}

do_set_camera_on() {
	raspi-config nonint do_camera 0
}

do_set_memory() {
	raspi-config nonint do_memory_split 128
}

do_add_package_repos() {

  curl -s "http://www.linux-projects.org/listing/uv4l_repo/lrkey.asc" | apt-key add - > /dev/null 
  echo "deb http://www.linux-projects.org/listing/uv4l_repo/raspbian/ ${DISTRO} main" > /etc/apt/sources.list.d/uv4l-sources.list

  echo "deb-src http://archive.raspbian.org/raspbian/ ${DISTRO} main contrib non-free rpi" > /etc/apt/sources.list.d/debsource-sources.list

}

do_upgrade() {

  do_add_package_repos
  apt-get -y remove nodejs
  apt-get -y remove triggerhappy
  apt-get -y update
  apt-get -y install raspberrypi-kernel-headers
  apt-get -y install libudev-dev
  apt-get -y install omxplayer
  apt-get -y install mplayer2

  if [ $VIDEO -eq 1 ]
  then

	apt-get -y install libavcodec-dev 
	apt-get -y install libavformat-dev 
	apt-get -y install libswscale-dev 
	apt-get -y install libv4l-dev 
	apt-get -y install libxvidcore-dev 
	apt-get -y install libx264-dev 
	apt-get -y install libjpeg-dev 
	apt-get -y install libtiff5-dev 
	apt-get -y install libjasper-dev 
	apt-get -y install libpng12-dev
    apt-get -y install motion 
	apt-get -y install fonts-dejavu
	apt-get -y install libfreetype6-dev 

  fi
  
  apt-get -y install gdebi-core
  apt-get -y install git

  apt-get -y dist-upgrade

}


do_set_camera() {
    do_set_memory
    do_set_camera_on
}


do_build_v412loopback() {
  if [ -e /tmp/v4l2loopback-master ]
  then
    rm -r -f /tmp/v4l2loopback-master
  fi

  curl -L -k https://github.com/umlaeute/v4l2loopback/archive/master.tar.gz | tar xz -C /tmp
  
  cat <<EOF > /tmp/v4l2loopback-master/run_run
#!/bin/bash  
make -j${CPUCOUNT} && make install
EOF

  chmod 755 /tmp/v4l2loopback-master/run_run
  cd /tmp/v4l2loopback-master
  ./run_run
}

do_build_openzwave() {
  if [ -e /tmp/open-zwave-master ]
  then
    rm -r -f /tmp/open-zwave-master
  fi

  curl -s -L -k https://github.com/bitdog-io/open-zwave/archive/master.tar.gz | tar xz -C /tmp

  cat <<EOF > /tmp/open-zwave-master/run_run
#!/bin/bash
make -j${CPUCOUNT} && make install
EOF

  chmod 755 /tmp/open-zwave-master/run_run
  cd /tmp/open-zwave-master
  ./run_run
}

do_install_node() {
  curl -s -L -k http://nodejs.org/dist/${NODEVERSION}/node-${NODEVERSION}-linux-${HARDWARE}.tar.gz | tar xz -C /usr/local --strip=1

  npm i -g npm
  npm install node-gyp -g

}

do_build_ffmpeg() {
  if [ -e /tmp/FFmpeg-master ]
  then
    rm -r -f /tmp/FFmpeg-master
  fi

  curl -s -L -k https://github.com/FFmpeg/FFmpeg/archive/master.tar.gz | tar xz -C /tmp

  cat <<EOF > /tmp/FFmpeg-master/run_run
#!/bin/bash
./configure --disable-doc --disable-ffplay --disable-ffprobe --arch=armel --target-os=linux --enable-gpl --enable-libx264 --enable-nonfree --enable-omx-rpi --enable-mmal --enable-libfreetype 
make -j${CPUCOUNT} && make install
EOF

  chmod 755 /tmp/FFmpeg-master/run_run
  cd /tmp/FFmpeg-master
  ./run_run
}

do_make_bitdog_diretory() {

  if [ ! -e ${BITDOGHUB_HOME_DIR} ]
  then
    sudo mkdir ${BITDOGHUB_HOME_DIR}
  fi

  sudo chmod 755 ${BITDOGHUB_HOME_DIR}

  if [ ! -e ${BITDOG_HUB_INSTALLER_DIR} ]
  then
    sudo mkdir ${BITDOG_HUB_INSTALLER_DIR}
  fi

  if [ ! -e ${BITDOG_HUB_BIN_DIR} ]
  then
    sudo mkdir ${BITDOG_HUB_BIN_DIR}
  fi

  if [ ! -e ${BITDOG_HUB_LOG_DIR} ]
  then
    sudo mkdir ${BITDOG_HUB_LOG_DIR}
  fi

  if [ ! -e ${BITDOG_HUB_CONFIG_DIR} ]
  then
    sudo mkdir ${BITDOG_HUB_CONFIG_DIR}
  fi

  if [ ! -e ${BITDOG_HUB_DVR_DIR} ]
  then
    sudo mkdir ${BITDOG_HUB_DVR_DIR}
  fi
  
  sudo curl -s ${BITDOG_HUB_INSTALLER_URL} -o  ${BITDOG_HUB_INSTALLER_DIR}/install.sh

  sudo chmod 755 ${BITDOG_HUB_INSTALLER_DIR}/install.sh
  sudo chmod 755 ${BITDOG_HUB_INSTALLER_DIR}

  sudo chown ${BITDOGHUB_USER}:${BITDOGHUB_GROUP} -R ${BITDOGHUB_HOME_DIR}

}

do_create_bitdog_hub_config() {



	if [ ! -e ${BITDOG_HUB_CONFIG_DIR}/config.json ]
	then
	cat <<EOF > ${BITDOG_HUB_CONFIG_DIR}/config.json
{
  "video": {
    "enabled": ${VIDEO_ENABLE},
	"streamerPort": ${VIDEO_STREAMER_PORT},
	"dvrPath": "${BITDOG_HUB_DVR_DIR}"
  },
  "zwave": {
    "connections": []
  },
  "logging": {
    "log_to_console": false
  },
  "ipc": {
	"port": ${IPC_PORT}
  }
}
EOF

	fi

  chmod 640 ${BITDOG_HUB_CONFIG_DIR}/config.json
  chown ${BITDOGHUB_USER}:${BITDOGHUB_GROUP} ${BITDOG_HUB_CONFIG_DIR}/config.json

}

do_install_bitdog() {

  cd ${BITDOGHUB_HOME_DIR}

  su ${BITDOGHUB_USER} -c "npm install git+https://github.com/bitdog-io/bitdog-hub.git#master"

  if [ -e ./bitdoghub ]
  then
    rm ./bitdoghub
  fi

cat <<EOF > ./bitdoghub
#!/bin/bash
cd ${BITDOGHUB_HOME_DIR}
${BITDOGHUB_HOME_DIR}/${BITDOGHUBBIN}/bitdoghub "\$@" 
EOF

  chmod 755 ./bitdoghub
  chown ${BITDOGHUB_USER}:${BITDOGHUB_GROUP} ./bitdoghub

  echo Install finished

}

do_register_hub() {
    su ${BITDOGHUB_USER} -c "${BITDOGHUB_HOME_DIR}/bitdoghub register -u \"${USERNAME}\" -p \"${PASSPHRASE}\" -n \"${HUBNAME}\" "
}

do_install_motion_event_scripts () {

cat <<EOF > ${BITDOG_HUB_BIN_DIR}/eventstart
#!/bin/bash
curl -s -H "Accept: application/json" -H "Content-Type: application/json" -X POST -d "{ \"name\": \"motion-event-start\" }" http://127.0.0.1:${IPC_PORT} | grep -q \"result\":true
EOF


  chmod 755 ${BITDOG_HUB_BIN_DIR}/eventstart
  chown ${BITDOGHUB_USER}:${BITDOGHUB_GROUP} ${BITDOG_HUB_BIN_DIR}/eventstart

cat <<EOF > ${BITDOG_HUB_BIN_DIR}/eventend
#!/bin/bash
curl -s -H "Accept: application/json" -H "Content-Type: application/json" -X POST -d "{ \"name\": \"motion-event-end\" }" http://127.0.0.1:${IPC_PORT}  | grep -q \"result\":true
EOF


  chmod 755 ${BITDOG_HUB_BIN_DIR}/eventend
  chown ${BITDOGHUB_USER}:${BITDOGHUB_GROUP} ${BITDOG_HUB_BIN_DIR}/eventend

cat <<EOF > ${BITDOG_HUB_BIN_DIR}/eventpicture
#!/bin/bash
curl -s -H "Accept: application/json" -H "Content-Type: application/json" -X POST -d "{ \"name\": \"motion-image-captured\" , \"imagePath\": \"\${1}\" }" http://127.0.0.1:${IPC_PORT}  | grep -q \"result\":true
EOF


  chmod 755 ${BITDOG_HUB_BIN_DIR}/eventpicture
  chown ${BITDOGHUB_USER}:${BITDOGHUB_GROUP} ${BITDOG_HUB_BIN_DIR}/eventpicture
}

do_install_video_loopback() {
cat <<EOF > /etc/modprobe.d/v4l2loopback.conf
options v4l2loopback video_nr=1
EOF

cat <<EOF > /etc/modules-load.d/v4l2loopback.conf
v4l2loopback
EOF

  depmod -a
  modprobe v4l2loopback video_nr=1 --first-time
}

do_install_bcm2835-v4l2() {

cat <<EOF > /etc/modules-load.d/bcm2835-v4l2.conf
bcm2835-v4l2
EOF

  depmod -a
  modprobe bcm2835-v4l2 --first-time
}

do_install_ffmpeg_stream_startup_script() {

cat <<EOF > ${BITDOG_HUB_BIN_DIR}/startffmpegstream
#!/bin/bash
# lower frame rates not supported
/usr/local/bin/ffmpeg -r 30 -loglevel fatal -s ${VIDEO_WIDTH}x${VIDEO_HEIGHT} -f video4linux2 -i /dev/video1 -f mpeg1video -b 100k  http://127.0.0.1:${VIDEO_STREAMER_PORT} 
EOF

  chmod 755 ${BITDOG_HUB_BIN_DIR}/startffmpegstream
  chown ${BITDOGHUB_USER}:${BITDOGHUB_GROUP} ${BITDOG_HUB_BIN_DIR}/startffmpegstream

  cat <<EOF > /lib/systemd/system/ffmpegstream.service
[Unit]
Description=ffmpeg service to stream mpeg1 video to Bitdog Hub websocket client
After=multi-user.target
Requires=bitdoghub.service

[Service]
User=${BITDOGHUB_USER}
Group=${BITDOGHUB_GROUP}
EnvironmentFile=/etc/environment
Type=simple
ExecStart=${BITDOG_HUB_BIN_DIR}/startffmpegstream
Restart=on-failure
Restart=always
RestartSec=120


[Install]
WantedBy=multi-user.target
EOF

  systemctl enable ffmpegstream


}

do_install_ffmpeg_copy_startup_script() {

cat <<EOF > ${BITDOG_HUB_BIN_DIR}/startffmpegcopy
#!/bin/bash
/usr/bin/v4l2-ctl --overlay=0 --set-fmt-video=width=${VIDEO_WIDTH},height=${VIDEO_HEIGHT}
/usr/local/bin/ffmpeg  -r ${VIDEO_FRAME_RATE} -loglevel fatal -f video4linux2 -i /dev/video0 -vcodec copy -f v4l2 /dev/video1
EOF

  chmod 755 ${BITDOG_HUB_BIN_DIR}/startffmpegcopy
  chown ${BITDOGHUB_USER}:${BITDOGHUB_GROUP} ${BITDOG_HUB_BIN_DIR}/startffmpegcopy


cat <<EOF > /lib/systemd/system/ffmpegcopy.service
[Unit]
Description=ffmpeg copy service copies video from raspicam to loopback
After=multi-user.target

[Service]
User=${BITDOGHUB_USER}
Group=${BITDOGHUB_GROUP}
EnvironmentFile=/etc/environment
Type=simple
ExecStart=${BITDOG_HUB_BIN_DIR}/startffmpegcopy
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable ffmpegcopy
}


do_install_ffmpeg_dvr_startup_script() {

cat <<EOF > ${BITDOG_HUB_BIN_DIR}/startffmpegdvr
#!/bin/bash
/usr/local/bin/ffmpeg -r ${VIDEO_FRAME_RATE} -loglevel fatal  -s ${VIDEO_WIDTH}x${VIDEO_HEIGHT} -f video4linux2 -i /dev/video1 -vcodec ${VIDEO_ENCODER} -b 100k -f segment -segment_time 300 -strftime 1 -reset_timestamps 1  ${BITDOG_HUB_DVR_DIR}/%Y-%m-%d_%H-%M-%S.mp4
EOF

  chmod 755 ${BITDOG_HUB_BIN_DIR}/startffmpegdvr
  chown ${BITDOGHUB_USER}:${BITDOGHUB_GROUP} ${BITDOG_HUB_BIN_DIR}/startffmpegdvr


cat <<EOF > /lib/systemd/system/ffmpegdvr.service
[Unit]
Description=ffmpeg dvr service stores video files
After=multi-user.target

[Service]
User=${BITDOGHUB_USER}
Group=${BITDOGHUB_GROUP}
EnvironmentFile=/etc/environment
Type=simple
ExecStart=${BITDOG_HUB_BIN_DIR}/startffmpegdvr
Restart=on-failure
KillSignal=SIGINT

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable ffmpegdvr
}


do_install_bitdog_startup_script() {

if [ VIDEO -eq 1 ]
then
	REQUIRES="Requires=ffmpegcopy.service"
else
	REQUIRES=""
fi

cat <<EOF > /lib/systemd/system/bitdoghub.service
[Unit]
Description=Bitdog Hub Service
After=multi-user.target
${REQUIRES}

[Service]
User=${BITDOGHUB_USER}
Group=${BITDOGHUB_GROUP}
Type=forking
ExecStart=${BITDOGHUB_HOME_DIR}/bitdoghub start -p ${BITDOGHUB_HOME_DIR}/process.pid
ExecStop=${BITDOGHUB_HOME_DIR}/bitdoghub stop -p ${BITDOGHUB_HOME_DIR}/process.pid
TimeoutSec=90
PIDFile=${BITDOGHUB_HOME_DIR}/process.pid
Restart=always
RestartSec=120

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable bitdoghub
}

do_install_installer_restart_script() {
sudo bash -c "cat > /lib/systemd/system/bitdoghubinstaller.service"<<EOF 
[Unit]
Description=Bitdog Hub Installer
After=multi-user.target

[Service]
Type=idle
ExecStart=${BITDOG_HUB_INSTALLER_DIR}/install.sh

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl enable bitdoghubinstaller
}

do_remove_installer_restart_script() {

if [ -e /lib/systemd/system/bitdoghubinstaller.service ]
then
  systemctl disable bitdoghubinstaller
  rm /lib/systemd/system/bitdoghubinstaller.service
fi

  if [ -e ${BITDOG_HUB_INSTALLER_DIR}/nextsteps.sh ]
  then
    rm ${BITDOG_HUB_INSTALLER_DIR}/nextsteps.sh 
  fi
}

do_make_next_steps_2() {
cat <<EOF > ${BITDOG_HUB_INSTALLER_DIR}/nextsteps.sh

do_next_steps() {
	exec 2>&1 >>${BITDOG_HUB_INSTALLER_DIR}/install.log

	USERNAME="${USERNAME}"
	PASSPHRASE="${PASSPHRASE}"
	HUBNAME="${HUBNAME}"
	VIDEO=${VIDEO}
	NOTIFY=${NOTIFY}
	VIDEO_ENABLE="${VIDEO_ENABLE}"
	IPC_PORT="${IPC_PORT}"


    do_remove_installer_restart_script

	do_notify "Reboot successful, continuing with Bitdog Hub install"
	do_notify "Building OpenZWave libraries"
	do_build_openzwave

	if [[ $VIDEO -eq 1 ]] 
	then
		do_notify "Building video libraries"
		do_set_camera
		do_build_v412loopback
		do_install_bcm2835-v4l2
		do_install_video_loopback
		do_notify "Building ffmpeg, this will take a very long time"
		do_build_ffmpeg
		do_notify "Preparing video startup scripts"
		do_install_ffmpeg_copy_startup_script
		do_install_ffmpeg_stream_startup_script
		do_install_ffmpeg_dvr_startup_script
		do_install_motion_conf
		do_install_motion_event_scripts
		do_install_motion_startup_script
	fi

	do_notify "Installing Node.js with npm"
	do_install_node
	do_notify "Installing Bitdog Hub software"
	do_install_bitdog
	do_create_bitdog_hub_config
    do_notify "Registering Bitdog Hub"
	do_register_hub

	if [ $? -eq 1 ]
	then 
		do_notify "Hub registration failed"
		exit 1
    fi

	do_notify "Preparing Bitdog startup scripts"
	do_install_bitdog_startup_script
	do_notify "Install complete, rebooting system and starting Bitdog Hub"
	reboot
}

EOF

  chmod 755 ${BITDOG_HUB_INSTALLER_DIR}/nextsteps.sh
  chown ${BITDOGHUB_USER}:${BITDOGHUB_GROUP} ${BITDOG_HUB_INSTALLER_DIR}/nextsteps.sh

}

do_make_next_steps_1() {
sudo cat <<EOF > ${BITDOG_HUB_INSTALLER_DIR}/nextsteps.sh

do_next_steps() {
	exec 2>&1 >>${BITDOG_HUB_INSTALLER_DIR}/install.log

	USERNAME="${USERNAME}"
	PASSPHRASE="${PASSPHRASE}"
	HUBNAME="${HUBNAME}"
	VIDEO=${VIDEO}
	NOTIFY=${NOTIFY}
	VIDEO_ENABLE="${VIDEO_ENABLE}"
	IPC_PORT="${IPC_PORT}"


	do_notify "Reboot successful, installing and updating packages"
	do_upgrade
	do_notify "Package update complete, rebooting system to continue"
	do_make_next_steps_2
	reboot
}

EOF

  sudo chmod 755 ${BITDOG_HUB_INSTALLER_DIR}/nextsteps.sh
  sudo chown ${BITDOGHUB_USER}:${BITDOGHUB_GROUP} ${BITDOG_HUB_INSTALLER_DIR}/nextsteps.sh

}

do_first_steps() {

	do_notify "Starting install" 

	if [ $? -eq 1 ]
	then
		echo "Cannot validate username and passphrase, exiting"
		exit 1
	fi

	if [ -z "$HUBNAME" ]
	then
		echo "Hub name not provided, exiting"
		exit 1
    fi

	if [ -e ${BITDOG_HUB_INSTALLER_DIR}/install.log ]
	then
		sudo rm ${BITDOG_HUB_INSTALLER_DIR}/install.log
    fi

	do_make_bitdog_diretory
	do_make_next_steps_1
	do_install_installer_restart_script

	do_notify "Rebooting to continue headless install"
	sudo reboot
}


do_install_motion_startup_script() {

	if [ -e /etc/init.d/motion ]
	then
		rm /etc/init.d/motion
	fi

cat <<EOF > ${BITDOG_HUB_BIN_DIR}/startmotion
#!/bin/bash
/usr/bin/motion -c ${BITDOG_HUB_CONFIG_DIR}/motion.conf
EOF

  chmod 755 ${BITDOG_HUB_BIN_DIR}/startmotion
  chown ${BITDOGHUB_USER}:${BITDOGHUB_GROUP} ${BITDOG_HUB_BIN_DIR}/startmotion

cat <<EOF > /lib/systemd/system/motion.service
[Unit]
Description=Motion detection service
After=multi-user.target
Requires=ffmpegcopy.service

[Service]
User=${BITDOGHUB_USER}
Group=${BITDOGHUB_GROUP}
EnvironmentFile=/etc/environment
Type=simple
ExecStart=${BITDOG_HUB_BIN_DIR}/startmotion
Restart=on-failure
PIDFile=/var/run/motion/motion.pid

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable motion
}

do_install_motion_conf() {

cat <<EOF > ${BITDOG_HUB_CONFIG_DIR}/motion.conf
#
# This config file was orginally generated by motion 3.2.12+git20140228


############################################################
# Daemon
############################################################

# Start in daemon (background) mode and release terminal (default: off)
daemon off

# File to store the process ID, also called pid file. (default: not defined)
process_id_file /var/run/motion/motion.pid

############################################################
# Basic Setup Mode
############################################################

# Start in Setup-Mode, daemon disabled. (default: off)
setup_mode off


# Use a file to save logs messages, if not defined stderr and syslog is used. (default: not defined)
;logfile /tmp/motion.log

# Level of log messages [1..9] (EMR, ALR, CRT, ERR, WRN, NTC, INF, DBG, ALL). (default: 6 / NTC)
log_level 6

# Filter to log messages by type (COR, STR, ENC, NET, DBL, EVT, TRK, VID, ALL). (default: ALL)
log_type all

###########################################################
# Capture device options
############################################################

# Videodevice to be used for capturing  (default /dev/video0)
# for FreeBSD default is /dev/bktr0
videodevice /dev/video1

# v4l2_palette allows to choose preferable palette to be use by motion
# to capture from those supported by your videodevice. (default: 17)
# E.g. if your videodevice supports both V4L2_PIX_FMT_SBGGR8 and
# V4L2_PIX_FMT_MJPEG then motion will by default use V4L2_PIX_FMT_MJPEG.
# Setting v4l2_palette to 2 forces motion to use V4L2_PIX_FMT_SBGGR8
# instead.
#
# Values :
# V4L2_PIX_FMT_SN9C10X : 0  'S910'
# V4L2_PIX_FMT_SBGGR16 : 1  'BYR2'
# V4L2_PIX_FMT_SBGGR8  : 2  'BA81'
# V4L2_PIX_FMT_SPCA561 : 3  'S561'
# V4L2_PIX_FMT_SGBRG8  : 4  'GBRG'
# V4L2_PIX_FMT_SGRBG8  : 5  'GRBG'
# V4L2_PIX_FMT_PAC207  : 6  'P207'
# V4L2_PIX_FMT_PJPG    : 7  'PJPG'
# V4L2_PIX_FMT_MJPEG   : 8  'MJPEG'
# V4L2_PIX_FMT_JPEG    : 9  'JPEG'
# V4L2_PIX_FMT_RGB24   : 10 'RGB3'
# V4L2_PIX_FMT_SPCA501 : 11 'S501'
# V4L2_PIX_FMT_SPCA505 : 12 'S505'
# V4L2_PIX_FMT_SPCA508 : 13 'S508'
# V4L2_PIX_FMT_UYVY    : 14 'UYVY'
# V4L2_PIX_FMT_YUYV    : 15 'YUYV'
# V4L2_PIX_FMT_YUV422P : 16 '422P'
# V4L2_PIX_FMT_YUV420  : 17 'YU12'
#
v4l2_palette 17

# Tuner device to be used for capturing using tuner as source (default /dev/tuner0)
# This is ONLY used for FreeBSD. Leave it commented out for Linux
; tunerdevice /dev/tuner0

# The video input to be used (default: -1)
# Should normally be set to 0 or 1 for video/TV cards, and -1 for USB cameras
input -1

# The video norm to use (only for video capture and TV tuner cards)
# Values: 0 (PAL), 1 (NTSC), 2 (SECAM), 3 (PAL NC no colour). Default: 0 (PAL)
norm 0

# The frequency to set the tuner to (kHz) (only for TV tuner cards) (default: 0)
frequency 0

# Rotate image this number of degrees. The rotation affects all saved images as
# well as movies. Valid values: 0 (default = no rotation), 90, 180 and 270.
rotate 0

# Image width (pixels). Valid range: Camera dependent, default: 352
width ${VIDEO_WIDTH}

# Image height (pixels). Valid range: Camera dependent, default: 288
height ${VIDEO_HEIGHT}

# Maximum number of frames to be captured per second.
# Valid range: 2-100. Default: 100 (almost no limit).
framerate ${VIDEO_FRAME_RATE}

# Minimum time in seconds between capturing picture frames from the camera.
# Default: 0 = disabled - the capture rate is given by the camera framerate.
# This option is used when you want to capture images at a rate lower than 2 per second.
minimum_frame_time 0

# URL to use if you are using a network camera, size will be autodetected (incl http:// ftp:// mjpg:// rstp:// or file:///)
# Must be a URL that returns single jpeg pictures or a raw mjpeg stream. Default: Not defined
; netcam_url value

# Username and password for network camera (only if required). Default: not defined
# Syntax is user:password
; netcam_userpass value

# The setting for keep-alive of network socket, should improve performance on compatible net cameras.
# off:   The historical implementation using HTTP/1.0, closing the socket after each http request.
# force: Use HTTP/1.0 requests with keep alive header to reuse the same connection.
# on:    Use HTTP/1.1 requests that support keep alive as default.
# Default: off
netcam_keepalive off

# URL to use for a netcam proxy server, if required, e.g. "http://myproxy".
# If a port number other than 80 is needed, use "http://myproxy:1234".
# Default: not defined
; netcam_proxy value

# Set less strict jpeg checks for network cameras with a poor/buggy firmware.
# Default: off
netcam_tolerant_check off

# Let motion regulate the brightness of a video device (default: off).
# The auto_brightness feature uses the brightness option as its target value.
# If brightness is zero auto_brightness will adjust to average brightness value 128.
# Only recommended for cameras without auto brightness
auto_brightness off

# Set the initial brightness of a video device.
# If auto_brightness is enabled, this value defines the average brightness level
# which Motion will try and adjust to.
# Valid range 0-255, default 0 = disabled
brightness 0

# Set the contrast of a video device.
# Valid range 0-255, default 0 = disabled
contrast 0

# Set the saturation of a video device.
# Valid range 0-255, default 0 = disabled
saturation 0

# Set the hue of a video device (NTSC feature).
# Valid range 0-255, default 0 = disabled
hue 0


############################################################
# Round Robin (multiple inputs on same video device name)
############################################################

# Number of frames to capture in each roundrobin step (default: 1)
roundrobin_frames 1

# Number of frames to skip before each roundrobin step (default: 1)
roundrobin_skip 1

# Try to filter out noise generated by roundrobin (default: off)
switchfilter off


############################################################
# Motion Detection Settings:
############################################################

# Threshold for number of changed pixels in an image that
# triggers motion detection (default: 1500)
threshold 1500

# Automatically tune the threshold down if possible (default: off)
threshold_tune off

# Noise threshold for the motion detection (default: 32)
noise_level 32

# Automatically tune the noise threshold (default: on)
noise_tune on

# Despeckle motion image using (e)rode or (d)ilate or (l)abel (Default: not defined)
# Recommended value is EedDl. Any combination (and number of) of E, e, d, and D is valid.
# (l)abeling must only be used once and the 'l' must be the last letter.
# Comment out to disable
despeckle_filter EedDl

# Detect motion in predefined areas (1 - 9). Areas are numbered like that:  1 2 3
# A script (on_area_detected) is started immediately when motion is         4 5 6
# detected in one of the given areas, but only once during an event.        7 8 9
# One or more areas can be specified with this option. Take care: This option
# does NOT restrict detection to these areas! (Default: not defined)
; area_detect value

# PGM file to use as a sensitivity mask.
# Full path name to. (Default: not defined)
; mask_file value

# Dynamically create a mask file during operation (default: 0)
# Adjust speed of mask changes from 0 (off) to 10 (fast)
smart_mask_speed 0

# Ignore sudden massive light intensity changes given as a percentage of the picture
# area that changed intensity. Valid range: 0 - 100 , default: 0 = disabled
lightswitch 50

# Picture frames must contain motion at least the specified number of frames
# in a row before they are detected as true motion. At the default of 1, all
# motion is detected. Valid range: 1 to thousands, recommended 1-5
minimum_motion_frames 5

# Specifies the number of pre-captured (buffered) pictures from before motion
# was detected that will be output at motion detection.
# Recommended range: 0 to 5 (default: 0)
# Do not use large values! Large values will cause Motion to skip video frames and
# cause unsmooth movies. To smooth movies use larger values of post_capture instead.
pre_capture 0

# Number of frames to capture after motion is no longer detected (default: 0)
post_capture 0

# Event Gap is the seconds of no motion detection that triggers the end of an event.
# An event is defined as a series of motion images taken within a short timeframe.
# Recommended value is 60 seconds (Default). The value -1 is allowed and disables
# events causing all Motion to be written to one single movie file and no pre_capture.
# If set to 0, motion is running in gapless mode. Movies don't have gaps anymore. An
# event ends right after no more motion is detected and post_capture is over.
event_gap 60

# Maximum length in seconds of a movie
# When value is exceeded a new movie file is created. (Default: 0 = infinite)
max_movie_time 0

# Always save images even if there was no motion (default: off)
emulate_motion off


############################################################
# Image File Output
############################################################

# Output 'normal' pictures when motion is detected (default: on)
# Valid values: on, off, first, best, center
# When set to 'first', only the first picture of an event is saved.
# Picture with most motion of an event is saved when set to 'best'.
# Picture with motion nearest center of picture is saved when set to 'center'.
# Can be used as preview shot for the corresponding movie.
output_pictures best

# Output pictures with only the pixels moving object (ghost images) (default: off)
output_debug_pictures off

# The quality (in percent) to be used by the jpeg compression (default: 75)
quality 75

# Type of output images
# Valid values: jpeg, ppm (default: jpeg)
picture_type jpeg

############################################################
# FFMPEG related options
# Film (movies) file output, and deinterlacing of the video input
# The options movie_filename and timelapse_filename are also used
# by the ffmpeg feature
############################################################

# Use ffmpeg to encode movies in realtime (default: off)
ffmpeg_output_movies off

# Use ffmpeg to make movies with only the pixels moving
# object (ghost images) (default: off)
ffmpeg_output_debug_movies off

# Use ffmpeg to encode a timelapse movie
# Default value 0 = off - else save frame every Nth second
ffmpeg_timelapse 0

# The file rollover mode of the timelapse video
# Valid values: hourly, daily (default), weekly-sunday, weekly-monday, monthly, manual
ffmpeg_timelapse_mode daily

# Bitrate to be used by the ffmpeg encoder (default: 400000)
# This option is ignored if ffmpeg_variable_bitrate is not 0 (disabled)
ffmpeg_bps 500000

# Enables and defines variable bitrate for the ffmpeg encoder.
# ffmpeg_bps is ignored if variable bitrate is enabled.
# Valid values: 0 (default) = fixed bitrate defined by ffmpeg_bps,
# or the range 2 - 31 where 2 means best quality and 31 is worst.
ffmpeg_variable_bitrate 0

# Codec to used by ffmpeg for the video compression.
# Timelapse mpegs are always made in mpeg1 format independent from this option.
# Supported formats are: mpeg1 (ffmpeg-0.4.8 only), mpeg4 (default), and msmpeg4.
# mpeg1 - gives you files with extension .mpg
# mpeg4 or msmpeg4 - gives you files with extension .avi
# msmpeg4 is recommended for use with Windows Media Player because
# it requires no installation of codec on the Windows client.
# swf - gives you a flash film with extension .swf
# flv - gives you a flash video with extension .flv
# ffv1 - FF video codec 1 for Lossless Encoding ( experimental )
# mov - QuickTime ( testing )
# ogg - Ogg/Theora ( testing )
ffmpeg_video_codec mpeg4

# Use ffmpeg to deinterlace video. Necessary if you use an analog camera
# and see horizontal combing on moving objects in video or pictures.
# (default: off)
ffmpeg_deinterlace off

############################################################
# SDL Window
############################################################

# Number of motion thread to show in SDL Window (default: 0 = disabled)
;sdl_threadnr 0

############################################################
# External pipe to video encoder
# Replacement for FFMPEG builtin encoder for ffmpeg_output_movies only.
# The options movie_filename and timelapse_filename are also used
# by the ffmpeg feature
#############################################################

# Bool to enable or disable extpipe (default: off)
use_extpipe off

# External program (full path and opts) to pipe raw video to
# Generally, use '-' for STDIN...
;extpipe mencoder -demuxer rawvideo -rawvideo w=320:h=240:i420 -ovc x264 -x264encopts bframes=4:frameref=1:subq=1:scenecut=-1:nob_adapt:threads=1:keyint=1000:8x8dct:vbv_bufsize=4000:crf=24:partitions=i8x8,i4x4:vbv_maxrate=800:no-chroma-me -vf denoise3d=16:12:48:4,pp=lb -of   avi -o %f.avi - -fps %fps



############################################################
# Snapshots (Traditional Periodic Webcam File Output)
############################################################

# Make automated snapshot every N seconds (default: 0 = disabled)
snapshot_interval 0


############################################################
# Text Display
# %Y = year, %m = month, %d = date,
# %H = hour, %M = minute, %S = second, %T = HH:MM:SS,
# %v = event, %q = frame number, %t = thread (camera) number,
# %D = changed pixels, %N = noise level, \n = new line,
# %i and %J = width and height of motion area,
# %K and %L = X and Y coordinates of motion center
# %C = value defined by text_event - do not use with text_event!
# You can put quotation marks around the text to allow
# leading spaces
############################################################

# Locate and draw a box around the moving object.
# Valid values: on, off, preview (default: off)
# Set to 'preview' will only draw a box in preview_shot pictures.
locate_motion_mode on

# Set the look and style of the locate box if enabled.
# Valid values: box, redbox, cross, redcross (default: box)
# Set to 'box' will draw the traditional box.
# Set to 'redbox' will draw a red box.
# Set to 'cross' will draw a little cross to mark center.
# Set to 'redcross' will draw a little red cross to mark center.
locate_motion_style box

# Draws the timestamp using same options as C function strftime(3)
# Default: %Y-%m-%d\n%T = date in ISO format and time in 24 hour clock
# Text is placed in lower right corner
text_right %Y-%m-%d\n%T-%q

# Draw a user defined text on the images using same options as C function strftime(3)
# Default: Not defined = no text
# Text is placed in lower left corner
; text_left CAMERA %t

# Draw the number of changed pixed on the images (default: off)
# Will normally be set to off except when you setup and adjust the motion settings
# Text is placed in upper right corner
text_changes off

# This option defines the value of the special event conversion specifier %C
# You can use any conversion specifier in this option except %C. Date and time
# values are from the timestamp of the first image in the current event.
# Default: %Y%m%d%H%M%S
# The idea is that %C can be used filenames and text_left/right for creating
# a unique identifier for each event.
text_event %Y%m%d%H%M%S

# Draw characters at twice normal size on images. (default: off)
text_double off


# Text to include in a JPEG EXIF comment
# May be any text, including conversion specifiers.
# The EXIF timestamp is included independent of this text.
;exif_text %i%J/%K%L

############################################################
# Target Directories and filenames For Images And Films
# For the options snapshot_, picture_, movie_ and timelapse_filename
# you can use conversion specifiers
# %Y = year, %m = month, %d = date,
# %H = hour, %M = minute, %S = second,
# %v = event, %q = frame number, %t = thread (camera) number,
# %D = changed pixels, %N = noise level,
# %i and %J = width and height of motion area,
# %K and %L = X and Y coordinates of motion center
# %C = value defined by text_event
# Quotation marks round string are allowed.
############################################################

# Target base directory for pictures and films
# Recommended to use absolute path. (Default: current working directory)
target_dir ${BITDOG_HUB_DVR_DIR}

# File path for snapshots (jpeg or ppm) relative to target_dir
# Default: %v-%Y%m%d%H%M%S-snapshot
# Default value is equivalent to legacy oldlayout option
# For Motion 3.0 compatible mode choose: %Y/%m/%d/%H/%M/%S-snapshot
# File extension .jpg or .ppm is automatically added so do not include this.
# Note: A symbolic link called lastsnap.jpg created in the target_dir will always
# point to the latest snapshot, unless snapshot_filename is exactly 'lastsnap'
snapshot_filename %v-%Y%m%d%H%M%S-snapshot

# File path for motion triggered images (jpeg or ppm) relative to target_dir
# Default: %v-%Y%m%d%H%M%S-%q
# Default value is equivalent to legacy oldlayout option
# For Motion 3.0 compatible mode choose: %Y/%m/%d/%H/%M/%S-%q
# File extension .jpg or .ppm is automatically added so do not include this
# Set to 'preview' together with best-preview feature enables special naming
# convention for preview shots. See motion guide for details
picture_filename %Y-%m-%d_%H-%M-%S_%t-%v-%q

# File path for motion triggered ffmpeg films (movies) relative to target_dir
# Default: %v-%Y%m%d%H%M%S
# Default value is equivalent to legacy oldlayout option
# For Motion 3.0 compatible mode choose: %Y/%m/%d/%H%M%S
# File extension .mpg or .avi is automatically added so do not include this
# This option was previously called ffmpeg_filename
movie_filename %v-%Y%m%d%H%M%S

# File path for timelapse movies relative to target_dir
# Default: %Y%m%d-timelapse
# Default value is near equivalent to legacy oldlayout option
# For Motion 3.0 compatible mode choose: %Y/%m/%d-timelapse
# File extension .mpg is automatically added so do not include this
timelapse_filename %Y%m%d-timelapse

############################################################
# Global Network Options
############################################################
# Enable or disable IPV6 for http control and stream (default: off )
ipv6_enabled off

############################################################
# Live Stream Server
############################################################

# The mini-http server listens to this port for requests (default: 0 = disabled)
;stream_port 8081

# Quality of the jpeg (in percent) images produced (default: 50)
stream_quality 50

# Output frames at 1 fps when no motion is detected and increase to the
# rate given by stream_maxrate when motion is detected (default: off)
stream_motion off

# Maximum framerate for stream streams (default: 1)
stream_maxrate 1

# Restrict stream connections to localhost only (default: on)
stream_localhost on

# Limits the number of images per connection (default: 0 = unlimited)
# Number can be defined by multiplying actual stream rate by desired number of seconds
# Actual stream rate is the smallest of the numbers framerate and stream_maxrate
stream_limit 0

# Set the authentication method (default: 0)
# 0 = disabled
# 1 = Basic authentication
# 2 = MD5 digest (the safer authentication)
stream_auth_method 0

# Authentication for the stream. Syntax username:password
# Default: not defined (Disabled)
; stream_authentication username:password


############################################################
# HTTP Based Control
############################################################

# TCP/IP port for the http server to listen on (default: 0 = disabled)
;webcontrol_port 8080

# Restrict control connections to localhost only (default: on)
webcontrol_localhost on

# Output for http server, select off to choose raw text plain (default: on)
webcontrol_html_output on

# Authentication for the http based control. Syntax username:password
# Default: not defined (Disabled)
; webcontrol_authentication username:password


############################################################
# Tracking (Pan/Tilt)
#############################################################

# Type of tracker (0=none (default), 1=stepper, 2=iomojo, 3=pwc, 4=generic, 5=uvcvideo, 6=servo)
# The generic type enables the definition of motion center and motion size to
# be used with the conversion specifiers for options like on_motion_detected
track_type 0

# Enable auto tracking (default: off)
track_auto off

# Serial port of motor (default: none)
;track_port /dev/ttyS0

# Motor number for x-axis (default: 0)
;track_motorx 0

# Set motorx reverse (default: 0)
;track_motorx_reverse 0

# Motor number for y-axis (default: 0)
;track_motory 1

# Set motory reverse (default: 0)
;track_motory_reverse 0

# Maximum value on x-axis (default: 0)
;track_maxx 200

# Minimum value on x-axis (default: 0)
;track_minx 50

# Maximum value on y-axis (default: 0)
;track_maxy 200

# Minimum value on y-axis (default: 0)
;track_miny 50

# Center value on x-axis (default: 0)
;track_homex 128

# Center value on y-axis (default: 0)
;track_homey 128

# ID of an iomojo camera if used (default: 0)
track_iomojo_id 0

# Angle in degrees the camera moves per step on the X-axis
# with auto-track (default: 10)
# Currently only used with pwc type cameras
track_step_angle_x 10

# Angle in degrees the camera moves per step on the Y-axis
# with auto-track (default: 10)
# Currently only used with pwc type cameras
track_step_angle_y 10

# Delay to wait for after tracking movement as number
# of picture frames (default: 10)
track_move_wait 10

# Speed to set the motor to (stepper motor option) (default: 255)
track_speed 255

# Number of steps to make (stepper motor option) (default: 40)
track_stepsize 40


############################################################
# External Commands, Warnings and Logging:
# You can use conversion specifiers for the on_xxxx commands
# %Y = year, %m = month, %d = date,
# %H = hour, %M = minute, %S = second,
# %v = event, %q = frame number, %t = thread (camera) number,
# %D = changed pixels, %N = noise level,
# %i and %J = width and height of motion area,
# %K and %L = X and Y coordinates of motion center
# %C = value defined by text_event
# %f = filename with full path
# %n = number indicating filetype
# Both %f and %n are only defined for on_picture_save,
# on_movie_start and on_movie_end
# Quotation marks round string are allowed.
############################################################

# Do not sound beeps when detecting motion (default: on)
# Note: Motion never beeps when running in daemon mode.
quiet on

# Command to be executed when an event starts. (default: none)
# An event starts at first motion detected after a period of no motion defined by event_gap
on_event_start ${BITDOG_HUB_BIN_DIR}/eventstart 

# Command to be executed when an event ends after a period of no motion
# (default: none). The period of no motion is defined by option event_gap.
on_event_end ${BITDOG_HUB_BIN_DIR}/eventend

# Command to be executed when a picture (.ppm|.jpg) is saved (default: none)
# To give the filename as an argument to a command append it with %f
on_picture_save ${BITDOG_HUB_BIN_DIR}/eventpicture %f

# Command to be executed when a motion frame is detected (default: none)
; on_motion_detected value

# Command to be executed when motion in a predefined area is detected
# Check option 'area_detect'.   (default: none)
; on_area_detected value

# Command to be executed when a movie file (.mpg|.avi) is created. (default: none)
# To give the filename as an argument to a command append it with %f
; on_movie_start value

# Command to be executed when a movie file (.mpg|.avi) is closed. (default: none)
# To give the filename as an argument to a command append it with %f
; on_movie_end value

# Command to be executed when a camera can't be opened or if it is lost
# NOTE: There is situations when motion don't detect a lost camera!
# It depends on the driver, some drivers dosn't detect a lost camera at all
# Some hangs the motion thread. Some even hangs the PC! (default: none)
; on_camera_lost value

#####################################################################
# Common Options for database features.
# Options require database options to be active also.
#####################################################################

# Log to the database when creating motion triggered picture file  (default: on)
; sql_log_picture on

# Log to the database when creating a snapshot image file (default: on)
; sql_log_snapshot on

# Log to the database when creating motion triggered movie file (default: off)
; sql_log_movie off

# Log to the database when creating timelapse movies file (default: off)
; sql_log_timelapse off

# SQL query string that is sent to the database
# Use same conversion specifiers has for text features
# Additional special conversion specifiers are
# %n = the number representing the file_type
# %f = filename with full path
# Default value:
# Create tables :
## 
# Mysql
# CREATE TABLE security (camera int, filename char(80) not null, frame int, file_type int, time_stamp timestamp(14), event_time_stamp timestamp(14));
#
# Postgresql
# CREATE TABLE security (camera int, filename char(80) not null, frame int, file_type int, time_stamp timestamp without time zone, event_time_stamp timestamp without time zone);
#
# insert into security(camera, filename, frame, file_type, time_stamp, text_event) values('%t', '%f', '%q', '%n', '%Y-%m-%d %T', '%C')
; sql_query insert into security(camera, filename, frame, file_type, time_stamp, event_time_stamp) values('%t', '%f', '%q', '%n', '%Y-%m-%d %T', '%C')


############################################################
# Database Options
############################################################

# database type : mysql, postgresql, sqlite3 (default : not defined)
; database_type value

# database to log to (default: not defined)
; database_dbname value

# The host on which the database is located (default: localhost)
; database_host value

# User account name for database (default: not defined)
; database_user value

# User password for database (default: not defined)
; database_password value

# Port on which the database is located
#  mysql 3306 , postgresql 5432 (default: not defined)
; database_port value

############################################################
# Database Options For SQLite3
############################################################

# SQLite3 database (file path) (default: not defined)
; sqlite3_db value



############################################################
# Video Loopback Device (vloopback project)
############################################################

# Output images to a video4linux loopback device
# The value '-' means next available (default: not defined)
; video_pipe value

# Output motion images to a video4linux loopback device
# The value '-' means next available (default: not defined)
; motion_video_pipe value


##############################################################
# Thread config files - One for each camera.
# Except if only one camera - You only need this config file.
# If you have more than one camera you MUST define one thread
# config file for each camera in addition to this config file.
##############################################################

# Remember: If you have more than one camera you must have one
# thread file for each camera. E.g. 2 cameras requires 3 files:
# This motion.conf file AND thread1.conf and thread2.conf.
# Only put the options that are unique to each camera in the
# thread config files.
; thread /etc/motion/thread1.conf
; thread /etc/motion/thread2.conf
; thread /etc/motion/thread3.conf
; thread /etc/motion/thread4.conf
EOF

  chmod 644 ${BITDOG_HUB_CONFIG_DIR}/motion.conf
  chown ${BITDOGHUB_USER}:${BITDOGHUB_GROUP} ${BITDOG_HUB_CONFIG_DIR}/motion.conf

}


if [ -e ${BITDOG_HUB_INSTALLER_DIR}/nextsteps.sh ]
then    
    . ${BITDOG_HUB_INSTALLER_DIR}/nextsteps.sh
	do_next_steps
else
	do_first_steps

fi



