#!/bin/sh

# Script 'spdopenwrt.sh' written by Jeffrey Young
# Used to run Ookla's CLI speedtest function and store the results to a local sql database
#
# Many of the functions within this script are based off the work of Jack Yaz in his work with the
# script SpdMerlin for AsusWRT-Merlin custom software for Asus Routers.  For more information on Jack's$
# various projects, see his Github page at;
#
#      https://github.com/jackyaz/spdMerlin
#
# The script has been built for OpenWRT 21.02 running on a Raspberry Pi 4 B
#
# The following binary modules must be downloaded and installed first from Ookla for the Raspberry Pi.  The script
# will attempt to download this package on first start.
#
#	wget -c https://install.speedtest.net/app/cli/ookla-speedtest-1.0.0-aarch64-linux.tgz
#	
# Change into the directory of choice and extract the archile (tar xvfz).
#
# On first run, Ooklawill may ask for aceptance of the end user licence agreement
#
# The script will attempt to find where the speedtest program is located.  Do not change the name of the binary.
#
# Configuration file 'spdopenwrt.conf" must be in the same directory as this script, and can have the following parameters;
#		SPEEDTESTSERVERNO=					Speedtest server to use.  If blank or absent, auto server select is used
#		SPEEDTESTSERVERNAME=				Name of Selected Server
#		SCRIPT_STORAGE_DIR=					Location where the sql database is stored.  If missing, /opt/var is used
#		DAYSTOKEEP=							Number of days to keep stats.  Default is 30 if parameter is missing
#		IFACE=								Interface to bind too.  Default is eth0
#		STORERESULTURL=						Specifies rather or not to store URL results in the database.  Default is 'false'
#		CSV_OUTPUT_DIR=						Directory for where csv export file is to be written to
#		AUTOMATED=							Does script add/check an entry in crontabs for scheduled tests
#		SCHDAYS=							If scheduled tests, which days of the week
#		SCHHOURS=							If scheduled tests, which hours of the day
#		SCHMINS=							If scheduled tests, which minutes of the hour
#		SQLITE3_PATH						Path to SQLITE3 Binary
#		JQBINARY							Path to the Json Parser Binary

readonly VERSION="1.00"
readonly PROC_NAME="speedtest"			# Filename of Ookla's speedtest binary
readonly SCRIPT_NAME="SpdOpenWRT"
readonly SCRIPT_FILENAME="$(basename $(echo $0))"
readonly SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
readonly CONFFILE="$SCRIPTPATH"/spdopenwrt.conf
readonly CRONFILE="/etc/crontabs/$(id | sed 's/.*(\(.*\))/\1/')"
readonly DNSMASQNTPCHECK="/var/state/dnsmasqsec"
IP=$(echo $(uci show network.lan.ipaddr) | sed s/\'//g)
readonly LOCALLANIP=${IP:19:15}
SCRIPT_INTERFACES="/tmp/spd-openwrt.interfaces"

### Start of output format variables ###
readonly CRIT="\\e[41m"
readonly ERR="\\e[31m"
readonly WARN="\\e[33m"
readonly PASS="\\e[32m"
readonly BOLD="\\e[1m"
readonly SETTING="${BOLD}\\e[36m"
readonly CLEARFORMAT="\\e[0m"
### End of output format variables ###

# Begin subroutines

NTP_Ready(){
	if [ ! -f "$DNSMASQNTPCHECK" ]; then
		ntpwaitcount=0
		while [ ! -f "$DNSMASQNTPCHECK" ] && [ "$ntpwaitcount" -lt 600 ]; do
			ntpwaitcount="$((ntpwaitcount + 30))"
			Print_Output true "Waiting for NTP to sync..." "$WARN"
			sleep 30
			done
		if [ "$ntpwaitcount" -ge 600 ]; then
			Print_Output true "NTP failed to sync after 10 minutes. Please resolve!" "$CRIT"
			exit 1
		else
			Print_Output true "NTP synced, $SCRIPT_NAME will now continue" "$PASS"
		fi
	fi
}

Check_Lock(){
### Code for these functions inspired by https://github.com/Adamm00 - credit to @Adamm ###
	if [ -f "/tmp/$SCRIPT_NAME.lock" ]; then
		ageoflock=$(($(date +%s) - $(date +%s -r /tmp/$SCRIPT_NAME.lock)))
		if [ "$ageoflock" -gt 600 ]; then
			Print_Output true "Stale lock file found (>600 seconds old) - purging lock" "$ERR"
			kill "$(sed -n '1p' /tmp/$SCRIPT_NAME.lock)" >/dev/null 2>&1
			Clear_Lock
			echo "$$" > "/tmp/$SCRIPT_NAME.lock"
			return 0
		else
			Print_Output true "Lock file found (age: $ageoflock seconds) - stopping to prevent duplicate runs" "$ERR"
			return 1
		fi
	else
		echo "$$" > "/tmp/$SCRIPT_NAME.lock"
		return 0
	fi
}

Clear_Lock(){
	rm -f "/tmp/$SCRIPT_NAME.lock" 2>/dev/null
	return 0
}

PressEnter(){
	while true; do
		printf "Press enter to continue..."
		read -r key
		case "$key" in
			*)
				break
			;;
		esac
	done
	return 0
}

GetVariables() {
	
	if [ -f "$CONFFILE" ]; then
		sed -i 's/\r//' "$CONFFILE"
		chmod 0644 "$CONFFILE"
		sed -i -e 's/"//g' "$CONFFILE"
		if grep -q "SCHEDULESTART" "$CONFFILE"; then
			{
				echo "SCHDAYS=*";
				echo "SCHHOURS=*";
				echo "SCHMINS=12,42";
			} >> "$CONFFILE"
			sed -i '/SCHEDULESTART/d;/SCHEDULEEND/d;/MINUTE/d;/TESTFREQUENCY/d' "$CONFFILE"
			if AutomaticMode check; then
				Auto_Cron delete 2>/dev/null
				Auto_Cron create 2>/dev/null
			else
				Auto_Cron delete 2>/dev/null
			fi
		fi
		
		STORERESULTURL="$(StoreResultURL check)"
		IFACE=$(grep "IFACE" "$CONFFILE" | cut -f2 -d"=")
		DAYSTOKEEP=$(grep "DAYSTOKEEP" "$CONFFILE" | cut -f2 -d"=")
		SCRIPT_STORAGE_DIR=$(grep "SCRIPT_STORAGE_DIR" "$CONFFILE" | cut -f2 -d"=")
		SPEEDTESTSERVERNO=$(grep "SPEEDTESTSERVERNO" "$CONFFILE" | cut -f2 -d"=")
		SPEEDTESTSERVERNAME=$(grep "SPEEDTESTSERVERNAME" "$CONFFILE" | cut -f2 -d"=")
		CSV_OUTPUT_DIR=$(grep "CSV_OUTPUT_DIR" "$CONFFILE" | cut -f2 -d"=")
		AUTOMATED=$(grep "AUTOMATED" "$CONFFILE" | cut -f2 -d"=")
		SCHDAYS=$(grep "SCHDAYS" "$CONFFILE" | cut -f2 -d"=")
		SCHHOURS=$(grep "SCHHOURS" "$CONFFILE" | cut -f2 -d"=")
		SCHMINS=$(grep "SCHMINS" "$CONFFILE" | cut -f2 -d"=")		
		SQLITE3_PATH=$(grep "SQLITE3_PATH" "$CONFFILE" | cut -f2 -d"=")
		JQBINARY=$(grep "JQBINARY" "$CONFFILE" | cut -f2 -d"=")
		SPEEDTEST_BINARY=$(grep "SPEEDTEST_BINARY" "$CONFFILE" | cut -f2 -d"=")
		
		CheckReqSoftware
		
	else
		
		ScriptHeader
		
		SQLITE3_PATH=""
		JQBINARY=""
		SPEEDTEST_BINARY=""
		
		printf "\\n\\nOpenWRT SpeedTest and statistics keeping script\n"
		printf "\\n${WARN}Can not find config file, proceeding with initial setup${CLEARFORMAT}\\n"
		printf "\\nBy continuing to use this script, you are agreeing the Ookla's EULA, TOS, Privacy policy and\\n"
		printf "\\nYou may only use this Speedtest software and information generated from it for personal, non-commercial\n"
		printf "use, through a command line interface on a personal computer. Your use of this software is subject\\n"
		printf "to the End User License Agreement, Terms of Use and Privacy Policy at these URLs:\\n"
		printf "\\nhttps://www.speedtest.net/about/eula \\nhttps://www.speedtest.net/about/terms\\nhttps://www.speedtest.net/about/privacy"
		printf "\\n\\n"
		printf "Do you agree to Ookla's Terms (YES/NO): "
		
		read -r answer
		
		if [ ! "$answer" = "YES" ] && [ ! "$answer" = "yes" ]; then
			printf "\\n${ERR}Agreeing to Ookla's term is mandatory to use this script\\n${CLEARFORMAT}"
			printf "\\n${ERR}Exiting.....\\n\\n${CLEARFORMAT}"
			exit 1
		fi
		
		printf "\\n${WARN}Will now ask some questions to setup configuration file${CLEARFORMAT}\\n"
		printf "${WARN}Pressing CTRL C now will break from the script${CLEARFORMAT}\\n\\n"
				
		PressEnter
			
		printf "${PASS}Writing default values to config file: $CONFFILE\n${CLEARFORMAT}"
		
		{
			echo "#Default System Parameters written by script init routine"
			echo ""	
			echo "STORERESULTURL=false"
			echo "IFACE="
			echo "DAYSTOKEEP=30"
			echo "SCRIPT_STORAGE_DIR=/opt/var/data"
			echo "SPEEDTESTSERVERNO=0"
			echo "SPEEDTESTSERVERNAME=Automatic"
			echo "CSV_OUTPUT_DIR="
			echo "AUTOMATED=false"
			echo "SCHDAYS=*"
			echo "SCHHOURS=*"
			echo "SCHMINS=12,42"
		} > "$CONFFILE"
		
		STORERESULTURL="false"
		DAYSTOKEEP="30"
		SCRIPT_STORAGE_DIR="/opt/var/data"
		SPEEDTESTSERVERNO=""
		SPEEDTESTSERVERNAME=""
		CSV_OUTPUT_DIR=""
		AUTOMATED="false"
		
		CheckReqSoftware
		Generate_Interface_List
		GenerateServerList
		dbStorageLoc
		DaysKeep update
		PrintToCSVMenu init
	fi
	
	mkdir -p "$SCRIPT_STORAGE_DIR"
}

AutomaticMode(){
	case "$1" in
		enable)
			sed -i 's/^AUTOMATED.*$/AUTOMATED=true/' "$CONFFILE"
			Auto_Cron create 2>/dev/null
		;;
		disable)
			sed -i 's/^AUTOMATED.*$/AUTOMATED=false/' "$CONFFILE"
			Auto_Cron delete 2>/dev/null
		;;
		check)
			AUTOMATED=$(grep "AUTOMATED" "$CONFFILE" | cut -f2 -d"=")
			if [ "$AUTOMATED" = "true" ]; then return 0; else return 1; fi
		;;
	esac
}

Menu_EditSchedule(){
	exitmenu=""
	formattype=""
	crudays=""
	crudaysvalidated=""
	cruhours=""
	crumins=""
	
	ScriptHeader
	
	while true; do
		printf "\\n${BOLD}Please choose which day(s) to run speedtest (0-6 - 0 = Sunday, * for every day, or comma separated days):${CLEARFORMAT}  "
		read -r day_choice
		
		if [ "$day_choice" = "e" ]; then
			exitmenu="exit"
			break
		elif [ "$day_choice" = "*" ]; then
			crudays="$day_choice"
			printf "\\n"
			break
		elif [ -z "$day_choice" ]; then
			printf "\\n\\e[31mPlease enter a valid number (0-6) or comma separated values${CLEARFORMAT}\\n"
		else
			crudaystmp="$(echo "$day_choice" | sed "s/,/ /g")"
			crudaysvalidated="true"
			for i in $crudaystmp; do
				if echo "$i" | grep -q "-"; then
					if [ "$i" = "-" ]; then
						printf "\\n\\e[31mPlease enter a valid number (0-6)${CLEARFORMAT}\\n"
						crudaysvalidated="false"
						break
					fi
					crudaystmp2="$(echo "$i" | sed "s/-/ /")"
					for i2 in $crudaystmp2; do
						if ! Validate_Number "$i2"; then
							printf "\\n\\e[31mPlease enter a valid number (0-6)${CLEARFORMAT}\\n"
							crudaysvalidated="false"
							break
						elif [ "$i2" -lt 0 ] || [ "$i2" -gt 6 ]; then
							printf "\\n\\e[31mPlease enter a number between 0 and 6${CLEARFORMAT}\\n"
							crudaysvalidated="false"
							break
						fi
					done
				elif ! Validate_Number "$i"; then
					printf "\\n\\e[31mPlease enter a valid number (0-6) or comma separated values${CLEARFORMAT}\\n"
					crudaysvalidated="false"
					break
				else
					if [ "$i" -lt 0 ] || [ "$i" -gt 6 ]; then
						printf "\\n\\e[31mPlease enter a number between 0 and 6 or comma separated values${CLEARFORMAT}\\n"
						crudaysvalidated="false"
						break
					fi
				fi
			done
			if [ "$crudaysvalidated" = "true" ]; then
				crudays="$day_choice"
				printf "\\n"
				break
			fi
		fi
	done
	
	if [ "$exitmenu" != "exit" ]; then
		while true; do
			printf "\\n${BOLD}Please choose the format to specify the hour/minute(s) to run speedtest:${CLEARFORMAT}\\n"
			printf "    1. Every X hours/minutes\\n"
			printf "    2. Custom\\n\\n"
			printf "Choose an option:  "
			read -r formatmenu
			
			case "$formatmenu" in
				1)
					formattype="everyx"
					printf "\\n"
					break
				;;
				2)
					formattype="custom"
					printf "\\n"
					break
				;;
				e)
					exitmenu="exit"
					break
				;;
				*)
					printf "\\n\\e[31mPlease enter a valid choice (1-2)${CLEARFORMAT}\\n"
				;;
			esac
		done
	fi
	
	if [ "$exitmenu" != "exit" ]; then
		if [ "$formattype" = "everyx" ]; then
			while true; do
				printf "\\n${BOLD}Please choose whether to specify every X hours or every X minutes to run speedtest:${CLEARFORMAT}\\n"
				printf "    1. Hours\\n"
				printf "    2. Minutes\\n\\n"
				printf "Choose an option:  "
				read -r formatmenu
				
				case "$formatmenu" in
					1)
						formattype="hours"
						printf "\\n"
						break
					;;
					2)
						formattype="mins"
						printf "\\n"
						break
					;;
					e)
						exitmenu="exit"
						break
					;;
					*)
						printf "\\n\\e[31mPlease enter a valid choice (1-2)${CLEARFORMAT}\\n"
					;;
				esac
			done
		fi
	fi
	
	if [ "$exitmenu" != "exit" ]; then
		if [ "$formattype" = "hours" ]; then
			while true; do
				printf "\\n${BOLD}Please choose how often to run speedtest (every X hours, where X is 1-24):${CLEARFORMAT}  "
				read -r hour_choice
				
				if [ "$hour_choice" = "e" ]; then
					exitmenu="exit"
					break
				elif ! Validate_Number "$hour_choice"; then
						printf "\\n\\e[31mPlease enter a valid number (1-24)${CLEARFORMAT}\\n"
				elif [ "$hour_choice" -lt 1 ] || [ "$hour_choice" -gt 24 ]; then
					printf "\\n\\e[31mPlease enter a number between 1 and 24${CLEARFORMAT}\\n"
				elif [ "$hour_choice" -eq 24 ]; then
					cruhours=0
					crumins=0
					printf "\\n"
					break
				else
					cruhours="*/$hour_choice"
					crumins=0
					printf "\\n"
					break
				fi
			done
		elif [ "$formattype" = "mins" ]; then
			while true; do
				printf "\\n${BOLD}Please choose how often to run speedtest (every X minutes, where X is 1-30):${CLEARFORMAT}  "
				read -r min_choice
				
				if [ "$min_choice" = "e" ]; then
					exitmenu="exit"
					break
				elif ! Validate_Number "$min_choice"; then
						printf "\\n\\e[31mPlease enter a valid number (1-30)${CLEARFORMAT}\\n"
				elif [ "$min_choice" -lt 1 ] || [ "$min_choice" -gt 30 ]; then
					printf "\\n\\e[31mPlease enter a number between 1 and 30${CLEARFORMAT}\\n"
				else
					crumins="*/$min_choice"
					cruhours="*"
					printf "\\n"
					break
				fi
			done
		fi
	fi
	
	if [ "$exitmenu" != "exit" ]; then
		if [ "$formattype" = "custom" ]; then
			while true; do
				printf "\\n${BOLD}Please choose which hour(s) to run speedtest (0-23, * for every hour, or comma separated hours):${CLEARFORMAT}  "
				read -r hour_choice
				
				if [ "$hour_choice" = "e" ]; then
					exitmenu="exit"
					break
				elif [ "$hour_choice" = "*" ]; then
					cruhours="$hour_choice"
					printf "\\n"
					break
				else
					cruhourstmp="$(echo "$hour_choice" | sed "s/,/ /g")"
					cruhoursvalidated="true"
					for i in $cruhourstmp; do
						if echo "$i" | grep -q "-"; then
							if [ "$i" = "-" ]; then
								printf "\\n\\e[31mPlease enter a valid number (0-23)${CLEARFORMAT}\\n"
								cruhoursvalidated="false"
								break
							fi
							cruhourstmp2="$(echo "$i" | sed "s/-/ /")"
							for i2 in $cruhourstmp2; do
								if ! Validate_Number "$i2"; then
									printf "\\n\\e[31mPlease enter a valid number (0-23)${CLEARFORMAT}\\n"
									cruhoursvalidated="false"
									break
								elif [ "$i2" -lt 0 ] || [ "$i2" -gt 23 ]; then
									printf "\\n\\e[31mPlease enter a number between 0 and 23${CLEARFORMAT}\\n"
									cruhoursvalidated="false"
									break
								fi
							done
						elif echo "$i" | grep -q "/"; then
							cruhourstmp3="$(echo "$i" | sed "s/\*\///")"
							if ! Validate_Number "$cruhourstmp3"; then
								printf "\\n\\e[31mPlease enter a valid number (0-23)${CLEARFORMAT}\\n"
								cruhoursvalidated="false"
								break
							elif [ "$cruhourstmp3" -lt 0 ] || [ "$cruhourstmp3" -gt 23 ]; then
								printf "\\n\\e[31mPlease enter a number between 0 and 23${CLEARFORMAT}\\n"
								cruhoursvalidated="false"
								break
							fi
						elif ! Validate_Number "$i"; then
							printf "\\n\\e[31mPlease enter a valid number (0-23) or comma separated values${CLEARFORMAT}\\n"
							cruhoursvalidated="false"
							break
						elif [ "$i" -lt 0 ] || [ "$i" -gt 23 ]; then
							printf "\\n\\e[31mPlease enter a number between 0 and 23 or comma separated values${CLEARFORMAT}\\n"
							cruhoursvalidated="false"
							break
						fi
					done
					if [ "$cruhoursvalidated" = "true" ]; then
						if echo "$hour_choice" | grep -q "-"; then
							cruhours1="$(echo "$hour_choice" | cut -f1 -d'-')"
							cruhours2="$(echo "$hour_choice" | cut -f2 -d'-')"
							if [ "$cruhours1" -lt "$cruhours2" ]; then
								cruhours="$hour_choice"
							elif [ "$cruhours2" -lt "$cruhours1" ]; then
								cruhours="$cruhours1-23,0-$cruhours2"
							fi
						else
							cruhours="$hour_choice"
						fi
						printf "\\n"
						break
					fi
				fi
			done
		fi
	fi
	
	if [ "$exitmenu" != "exit" ]; then
		if [ "$formattype" = "custom" ]; then
			while true; do
				printf "\\n${BOLD}Please choose which minutes(s) to run speedtest (0-59, * for every minute, or comma separated minutes):${CLEARFORMAT}  "
				read -r min_choice
				
				if [ "$min_choice" = "e" ]; then
					exitmenu="exit"
					break
				elif [ "$min_choice" = "*" ]; then
					crumins="$min_choice"
					printf "\\n"
					break
				else
					cruminstmp="$(echo "$min_choice" | sed "s/,/ /g")"
					cruminsvalidated="true"
					for i in $cruminstmp; do
						if echo "$i" | grep -q "-"; then
							if [ "$i" = "-" ]; then
								printf "\\n\\e[31mPlease enter a valid number (0-23)${CLEARFORMAT}\\n"
								cruminsvalidated="false"
								break
							fi
							cruminstmp2="$(echo "$i" | sed "s/-/ /")"
							for i2 in $cruminstmp2; do
								if ! Validate_Number "$i2"; then
									printf "\\n\\e[31mPlease enter a valid number (0-59)${CLEARFORMAT}\\n"
									cruminsvalidated="false"
									break
								elif [ "$i2" -lt 0 ] || [ "$i2" -gt 59 ]; then
									printf "\\n\\e[31mPlease enter a number between 0 and 59${CLEARFORMAT}\\n"
									cruminsvalidated="false"
									break
								fi
							done
						elif echo "$i" | grep -q "/"; then
							cruminstmp3="$(echo "$i" | sed "s/\*\///")"
							if ! Validate_Number "$cruminstmp3"; then
								printf "\\n\\e[31mPlease enter a valid number (0-30)${CLEARFORMAT}\\n"
								cruminsvalidated="false"
								break
							elif [ "$cruminstmp3" -lt 0 ] || [ "$cruminstmp3" -gt 30 ]; then
								printf "\\n\\e[31mPlease enter a number between 0 and 30${CLEARFORMAT}\\n"
								cruminsvalidated="false"
								break
							fi
						elif ! Validate_Number "$i"; then
							printf "\\n\\e[31mPlease enter a valid number (0-59) or comma separated values${CLEARFORMAT}\\n"
							cruminsvalidated="false"
							break
						elif [ "$i" -lt 0 ] || [ "$i" -gt 59 ]; then
							printf "\\n\\e[31mPlease enter a number between 0 and 59 or comma separated values${CLEARFORMAT}\\n"
							cruminsvalidated="false"
							break
						fi
					done
					
					if [ "$cruminsvalidated" = "true" ]; then
						if echo "$min_choice" | grep -q "-"; then
							crumins1="$(echo "$min_choice" | cut -f1 -d'-')"
							crumins2="$(echo "$min_choice" | cut -f2 -d'-')"
							if [ "$crumins1" -lt "$crumins2" ]; then
								crumins="$min_choice"
							elif [ "$crumins2" -lt "$crumins1" ]; then
								crumins="$crumins1-59,0-$crumins2"
							fi
						else
							crumins="$min_choice"
						fi
						printf "\\n"
						break
					fi
				fi
			done
		fi
	fi
	
	if [ "$exitmenu" != "exit" ]; then
		TestSchedule update "$crudays" "$cruhours" "$crumins"
		return 0
	else
		return 1
	fi
}

TestSchedule(){
	case "$1" in
		update)
			sed -i 's/^SCHDAYS.*$/SCHDAYS='"$(echo "$2" | sed 's/0/Sun/;s/1/Mon/;s/2/Tues/;s/3/Wed/;s/4/Thurs/;s/5/Fri/;s/6/Sat/;')"'/' "$CONFFILE"
			sed -i 's~^SCHHOURS.*$~SCHHOURS='"$3"'~' "$CONFFILE"
			sed -i 's~^SCHMINS.*$~SCHMINS='"$4"'~' "$CONFFILE"
			Auto_Cron delete 2>/dev/null
			Auto_Cron create 2>/dev/null
		;;
		check)
			SCHDAYS=$(grep "SCHDAYS" "$CONFFILE" | cut -f2 -d"=")
			SCHHOURS=$(grep "SCHHOURS" "$CONFFILE" | cut -f2 -d"=")
			SCHMINS=$(grep "SCHMINS" "$CONFFILE" | cut -f2 -d"=")
			echo "$SCHDAYS|$SCHHOURS|$SCHMINS"
		;;
	esac
}

Auto_Cron(){
	case $1 in
		create)
			if [ ! -f "$CRONFILE" ]; then touch "$CRONFILE"; fi 
			STARTUPLINECOUNT=$(crontab -l | grep -c "$SCRIPT_FILENAME")
			
			if [ "$STARTUPLINECOUNT" -eq 0 ]; then
				CRU_DAYNUMBERS="$(grep "SCHDAYS" "$CONFFILE" | cut -f2 -d"=" | sed 's/Sun/0/;s/Mon/1/;s/Tues/2/;s/Wed/3/;s/Thurs/4/;s/Fri/5/;s/Sat/6/;')"
				CRU_HOURS="$(grep "SCHHOURS" "$CONFFILE" | cut -f2 -d"=")"
				CRU_MINUTES="$(grep "SCHMINS" "$CONFFILE" | cut -f2 -d"=")"
				echo "${CRU_MINUTES} ${CRU_HOURS} * * ${CRU_DAYNUMBERS} ${SCRIPTPATH}/${SCRIPT_FILENAME} generate" >> $CRONFILE
				/etc/init.d/cron restart
			fi
		;;
		delete)
			if [ -f "$CRONFILE" ];then
				STARTUPLINECOUNT=$(crontab -l | grep -c "$SCRIPT_FILENAME")

				if [ "$STARTUPLINECOUNT" -gt 0 ]; then
					grep -v "$SCRIPT_FILENAME" "$CRONFILE" > /tmp/cronfile-spdopenwrt.tmp 2>/dev/null
					mv -f /tmp/cronfile-spdopenwrt.tmp "${CRONFILE}"
					/etc/init.d/cron restart
				fi
			fi
		;;
	esac
}

CheckReqSoftware() {
	
	printf "\n${PASS}Checking to see if SQLITE3 is installed...... ${CLEARFORMAT}\n"
	if [ -x "$SQLITE3_PATH" ]; then
		Print_Output true "SQlite3 found, proceeding....\\n" "${PASS}"
	else
		SQLITE3_PATH=$(find / -type f -name "sqlite3") >>/dev/null 2>&1
		if [ -z "$SQLITE3_PATH" ]; then
			Print_Output true "\nSQLite3 is not installed, pressing enter will proceed to install packages\n" "${WARN}"
			Print_Output true "Breaking out of the script now (CTRL C) will cancel script\n" "${WARN}"
			PressEnter
			
			opkg update
			opkg install sqlite3-cli
			SQLITE3_PATH=$(find / -type f -name "sqlite3") >>/dev/null 2>&1

			if [ -z "$SQLITE3_PATH" ];then
				Print_Output true "\\nCan not determine where sqlite3 is - Exiting program\\n" "${CRIT}" 
				exit 1
			fi
		fi
		[ `grep -c "SQLITE3_PATH" "$CONFFILE"` -ne 0 ] && sed -i s/^SQLITE3_PATH.*$/SQLITE3_PATH="$SQLITE3_PATH"/ "$CONFFILE" || echo "SQLITE3_PATH=${SQLITE3_PATH}" >> "$CONFFILE"
	fi

	Print_Output "\\nChecking to see if JSON processor (jq) is installed...... \\n" "${PASS}"
	if [ -x "$JQBINARY" ]; then
		Print_Output true "jq found, proceeding....\\n" "${PASS}"
	else	
		JQBINARY=$(find / -type f -name jq) >>/dev/null 2>&1
		if [ -z "$JQBINARY" ]; then
			Print_Output true "\\nJSON processor (jq) is not installed, pressing enter will proceed to install packages\\n" "${WARN}"
			Print_Output true "Breaking out of the script now (CTRL C) will cancel script\\n" "${WARN}"
			PressEnter
			opkg update
			opkg install jq
			JQBINARY=$(find / -type f -name "jq") >>/dev/null 2>&1
			
			if [ -z "$JQBINARY" ];then
				Print_Output true "\\nCan not determine where jq (JSON processor) is - Exiting program\\n" "${CRIT}" 
				exit 1
			fi
		fi
		
		[ `grep -c "JQBINARY" "$CONFFILE"` -ne 0 ] && sed -i s/^JQBINARY.*$/JQBINARY="$JQBINARY"/ "$CONFFILE" || echo "JQBINARY=${JQBINARY}" >> "$CONFFILE"
	fi

	Print_Output true "\\nChecking to see if Ookla Speedtest is installed...... \\n" "${PASS}"
	if [ -x "$SPEEDTEST_BINARY" ];then
		Print_Output true "Ookla's Speedtest program found, proceeding....\\n" "${PASS}"
	else
		SPEEDTEST_BINARY=$(find / -type f -name "speedtest") >>/dev/null 2>&1
		if [ -z "$SPEEDTEST_BINARY" ];then	
		
			PLATFORM=$(uname -m)
			case "$PLATFORM" in
				aarch64)
					GETPATH="https://install.speedtest.net/app/cli/ookla-speedtest-1.0.0-aarch64-linux.tgz"
				;;
				x86_64)
					GETPATH="https://install.speedtest.net/app/cli/ookla-speedtest-1.0.0-x86_64-linux.tgz"
				;;
				arm)
					GETPATH="https://install.speedtest.net/app/cli/ookla-speedtest-1.0.0-arm-linux.tgz"
				;;
				armhf)
					GETPATH="https://install.speedtest.net/app/cli/ookla-speedtest-1.0.0-armhf-linux.tgz"
				;;
				i386)
					GETPATH="https://install.speedtest.net/app/cli/ookla-speedtest-1.0.0-i386-linux.tgz"
				;;
				*)
					Print_Output true "\\nCan not find the speedtest program\\n" "${CRIT}"
					Print_Output true "\\nUnable to locate a Ookla package for platform ${PLATFORM}\\n" "${CRIT}"
					Print_Output true "\\nYou must download and install the Speedtest CLI from Ookla's website before continuing\n\n" "${CRIT}"
					exit 1
			esac
			
			FN=$(basename "$GETPATH")
			SPDDIR="/opt/lib/speedtest"
			Print_Output true "\\nSpeedTest binary not found\\n" "${WARN}"
			Print_Output true "\\n${SETTING}aarch64${PASS} hardware system detected\\n" "${PASS}"
			Print_Output true "\\nDirectory that Ookla SpeedTest will be installed to: ${SETTING}${SPDDIR}" "${PASS}"
			Print_Output true "\\n\\nDo you wish to change the location (Y/N): " "${PASS}"
				
			read -r answer
			if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
				printf "\\n${PASS}Enter full path of Directory to install Ookla Speedtest: ${CLEARFORMAT}"
				read -r SPDDIR
			fi
					
			mkdir -p "$SPDDIR"
			
			if ! [ -d "$SPDDIR" ]; then
				Print_Output true "\\nUnable to find/create directory ${SPDDIR}\\n" "${CRIT}"
				Print_Output true "\\nExiting the script.  Please trouble shoot and re-run this script.\\n" "${CRIT}"
				exit 1
			fi				
				
			wget -c -q -P "$SPDDIR" "$GETPATH"
			if [ "$?" -ne 0 ]; then
				Print_Output true "\\nFailed to download Ookla SpeedTest Package!\\n" "${CRIT}"
				Print_Output true "\\nExiting script\\n" "${CRIT}"
				exit 1
			else
				Print_Output true "\\nDownloaded Ookla SpeedTest Package OK\\n" "${PASS}"
			fi
				
			tar x -z -f "${SPDDIR}"/"${FN}" -C "${SPDDIR}"
			if [ "$?" -ne 0 ]; then
				Print_Output true "\\nFailed to extract Ookla SpeedTest Package!!\\n" "${CRIT}"
				Print_Output true "\\nExiting Script!\\n" "${CRIT}"
				exit 1
			else	
				Print_Output "Finished extracting Ookla SpeedTest Binary files\\n" "${PASS}"
			fi
				
			SPEEDTEST_BINARY="$SPDDIR""/speedtest"
		fi
		
		[ `grep -c "SPEEDTEST_BINARY" "$CONFFILE"` -ne 0 ] && sed -i s/^SPEEDTEST_BINARY.*$/SPEEDTEST_BINARY="$SPEEDTEST_BINARY"/ "$CONFFILE" || echo "SPEEDTEST_BINARY=${SPEEDTEST_BINARY}" >> "$CONFFILE"
	fi
}

StoreResultURL(){
	case "$1" in
	enable)
		sed -i 's/^STORERESULTURL.*$/STORERESULTURL=true/' "$CONFFILE"
	;;
	disable)
		sed -i 's/^STORERESULTURL.*$/STORERESULTURL=false/' "$CONFFILE"
	;;
	check)
		STORERESULTURL=$(grep "STORERESULTURL" "$CONFFILE" | cut -f2 -d"=")
		echo "$STORERESULTURL"
	;;
	esac
}

Validate_Bandwidth(){
	if echo "$1" | /bin/grep -oq "^[0-9]*\.\?[0-9]*$"; then
		return 0
	else
		return 1
	fi
}

Print_Output(){
	if [ "$1" = "true" ]; then
		logger -t "$SCRIPT_NAME" "$2"
	fi
	text=$(echo $2 | sed s~%~%%~g)
	printf "${3}${text}${CLEARFORMAT}\\n"
}

Reset_DB(){
# Initlize Database

	ScriptHeader
	
	if ! [ -f "$SCRIPT_STORAGE_DIR/spdstats.db" ]; then
		Print_Output true "No database file exists, nothing to reset\\n\\n" "${WARN}"
		return 0
	fi
	
	Print_Output true "***WARNING*** This action will delete the current database!" "${WARN}"
	Print_Output true "\\n\\nAre you sure you want to continue?  Type 'YES' to proceed: " "${WARN}"
	
	read -r answer
	
	if [ "$answer" = "YES" ]; then
		SIZEAVAIL="$(df -P -k "$SCRIPT_STORAGE_DIR" | awk '{print $4}' | tail -n 1)"
		SIZEDB="$(ls -l "$SCRIPT_STORAGE_DIR/spdstats.db" | awk '{print $5}')"
		if [ "$SIZEDB" -gt "$((SIZEAVAIL*1024))" ]; then
			Print_Output true "Database size exceeds available space. $(ls -lh "$SCRIPT_STORAGE_DIR/spdstats.db" | awk '{print $5}')B is required to create backup.\\n" "${ERR}"
			return 1
		else
			Print_Output true "\\nSufficient free space to back up database, proceeding...\\n\\n" "${PASS}" 
			if ! cp -a "$SCRIPT_STORAGE_DIR/spdstats.db" "$SCRIPT_STORAGE_DIR/spdstats.db.bak"; then
				printf "${ERR}Database backup failed, please check storage device${CLEARFORMAT}\\n"
			fi
		
			rm "$SCRIPT_STORAGE_DIR/spdstats.db"
		
			Print_Output true "\\nDatabase reset complete\\n" "${WARN}"
		fi
	else
		Print_Output true "\\nOperation has been aborted\\n" "${WARN}"
	fi
}

Validate_Number(){
	if [ "$1" -eq "$1" ] 2>/dev/null; then
		return 0
	else
		return 1
	fi
}

Generate_Interface_List(){

	TMPINTERFACES="/tmp/interfaces.tmp"
	SA="no"
	
	while true
	do
		if [ -f "$TMPINTERFACES" ]; then
			rm "$TMPINTERFACES"
		fi
	
		if [ -f "$SCRIPT_INTERFACES" ]; then
			rm "$SCRIPT_INTERFACES"
		fi
		
		ScriptHeader
	
		printf "Please select the interface(s) that you want to toggle on/off for speedtest to run when scheduled calls\\n"
		printf "are made\\n\\n"
		printf "\\n${PASS}Current interface(s) being tested is: ${SETTING}${IFACE}${CLEARFORMAT}\n\n"
		printf "Retrieving list of interfaces...\\n\\n"

		ip a > "$TMPINTERFACES"
	
		for i in $(ip link show | grep -i "^[1-9]" | cut -d ":" -f 2 | cut -c 2-)
		do
			if ! [ "$i" = "lo" ]; then
				I2=$(cat "$TMPINTERFACES" | grep -A2 "$i": | tail -n 1 | cut -d " " -f 5)
				if [ "$I2" = "inet" ]; then
					IP=$(cat "$TMPINTERFACES" | grep -A2 "$i": | tail -n 1 | cut -d " " -f 6)
				else
					IP=""
				fi
				if [ ! ${IP%/*} = "$LOCALLANIP" ]; then
					printf "%-15s         IP: %s\\n" "$i" "$IP" >> "$SCRIPT_INTERFACES"
				fi
				if [ "$SA" = "yes" ]; then
					if [ -z "$IP" ]; then
						echo "$i" >> "$SCRIPT_INTERFACES"
					fi
				fi
			fi
		done
	
		interfacecount="$(wc -l < "$SCRIPT_INTERFACES")"

		COUNTER=1
		until [ $COUNTER -gt "$interfacecount" ]; do
			interfaceline="$(sed "$COUNTER!d" "$SCRIPT_INTERFACES")"
			printf "%s) %s\\n" "$COUNTER" "$interfaceline"
			COUNTER=$((COUNTER + 1))
		done
	
		printf "\\ne)  Return to menu    s)  Toggle list all interfaces or interfaces with an IP Address\\n"
		printf ""
		printf "\\n${BOLD}Please select an interface to toggle running SpeedTest on %s (1-%s):${CLEARFORMAT}  " "$SCRIPT_NAME" "$interfacecount"
		read -r interface

		if [ "$interface" = "e" ] || [ "$interface" = "E" ]; then
			break
		fi
		if [ "$interface" = "s" ] || [ "$interface" = "s" ]; then
			if [ "$SA" = "yes" ]; then
				SA="no"
			else
				SA="yes"
			fi
			continue
		fi
		if ! Validate_Number "$interface"; then
			printf "\\n\\e[31mPlease enter a valid number (1-%s)${CLEARFORMAT}\\n" "$interfacecount"

		else
			if [ "$interface" -lt 1 ] || [ "$interface" -gt "$interfacecount" ]; then
				printf "\\n\\e[31mPlease enter a number between 1 and %s${CLEARFORMAT}\\n" "$interfacecount"
			else
				interfaceline="$(sed "$interface!d" "$SCRIPT_INTERFACES" | awk '{$1=$1};1' | cut -d " " -f 1)"
				if [ -z $(echo "$IFACE" | grep "$interfaceline") ]; then
					IFACE="${IFACE},${interfaceline}"
				else
					IFACE=$(echo ${IFACE} | sed s/${interfaceline}//g)	
				fi

				IFACE=$(echo ${IFACE} | sed s/,,/,/g)
				if [ "${IFACE:0:1}" = "," ]; then
					IFACE="${IFACE:1}"
				fi
				if [ "${IFACE: -1}" = "," ]; then
					IFACE="${IFACE::-1}"
				fi
				
				sed -i s/^IFACE.*$/IFACE="$IFACE"/ "$CONFFILE"
			fi
		fi
	done

	Print_Output true "\\nThe interface that SpeedTest will test is: ${SETTING}${IFACE}\\n" ${PASS}
	[ -f "$TMPINTERFACES" ] && rm "$TMPINTERFACES"
	[ -f "$SCRIPT_INTERFACES" ] && rm "$SCRIPT_INTERFACES"
}

ScriptHeader() {
	clear
	
	printf "\\n"
	printf "${BOLD}SpdOpenWRT - Ookla powered SpeedTest & results database storage script${CLEARFORMAT}\\n"
	printf "${BOLD}                           Version: ${VERSION}${CLEARFORMAT}"
	printf "\\n\\n"

}

GenerateServerList(){

	ScriptHeader
		
	printf "Please select a server from the following list if you want to control which server Speedtest will\n"
	printf "will use each time a test is done.  You may also select a server manually if you know the\n"
	printf "server number.  You may also choose to have a server chosen automatically each time Speedtest runs\n\n"
	printf "\n${PASS}Generating list of closest servers for %s...${CLEARFORMAT}\\n\\n" "$1"

	LICENSE_STRING="--accept-license --accept-gdpr"
	serverlist="$("$SPEEDTEST_BINARY" $CONFIG_STRING --interface="$IFACE" --servers --format="json" $LICENSE_STRING)" 2>/dev/null

	if [ -z "$serverlist" ]; then
		Print_Output true "Error retrieving server list for for $1" "$CRIT"
		serverno="exit"
		return 1
	fi
	servercount="$(echo "$serverlist" | jq '.servers | length')"
	COUNTER=1
	until [ $COUNTER -gt "$servercount" ]; do
		serverdetails="$(echo "$serverlist" | jq -r --argjson index "$((COUNTER-1))" '.servers[$index] | .id')|$(echo "$serverlist" | jq -r --argjson index "$((COUNTER-1))" '.servers[$index] | .name + " (" + .location + ", " + .country + ")"')"
		
		if [ "$COUNTER" -lt 10 ]; then
			printf "%s)  %s\\n" "$COUNTER" "$serverdetails"
		elif [ "$COUNTER" -ge 10 ]; then
			printf "%s) %s\\n" "$COUNTER" "$serverdetails"
		fi
		COUNTER=$((COUNTER + 1))
	done

	printf "\\ne)  Go back\\n"
	
	while true; do
		printf "\\n$Please select a server from the list above (1-%s):\\n" "$servercount"
		printf "\\nOr press ${BOLD}'c'${CLEARFORMAT} to enter a known server ID or ${BOLD}'a'${CLEARFORMAT} for automatic selection each time Speedtest runs\\n"
		printf "Enter answer:  "
		read -r server
		
		if [ "$server" = "e" ]; then
			return
		elif [ "$server" = "a" ]; then
			sed -i s/^SPEEDTESTSERVERNO.*$/SPEEDTESTSERVERNO="0"/ "$CONFFILE"
			sed -i s/^SPEEDTESTSERVERNAME.*$/SPEEDTESTSERVERNAME="Automatic"/ "$CONFFILE"
			SPEEDTESTSERVERNO="0"
			SPEEDTESTSERVERNAME="Automatic"
			Print_Output true "\\nServer Selection is set to automatic. SpeedTest will choose the server.\\n" "${PASS}"
			return
		elif [ "$server" = "c" ]; then
				while true; do
					printf "\\n${BOLD}Please enter server ID (WARNING: this is not validated) or e to go back${CLEARFORMAT}  "
					read -r customserver
					if [ "$customserver" = "e" ]; then
						break
					elif ! Validate_Number "$customserver"; then
						printf "\\n\\e[31mPlease enter a valid number${CLEARFORMAT}\\n"
					else
						serverno="$customserver"
						while true; do
							printf "\\n${BOLD}Would you like to enter a name for this server? (default: Custom) (y/n)?${CLEARFORMAT}  "
							read -r servername_select
							
							if [ "$servername_select" = "n" ] || [ "$servername_select" = "N" ]; then
								servername="Custom"
								break
							elif [ "$servername_select" = "y" ] || [ "$servername_select" = "Y" ]; then
								printf "\\n${BOLD}Please enter the name for this server:${CLEARFORMAT}  "
								read -r servername
								printf "\\n${BOLD}%s${CLEARFORMAT}\\n" "$servername"
								printf "\\n${BOLD}Is that correct (y/n)?${CLEARFORMAT}  "
								read -r servername_confirm
								if [ "$servername_confirm" = "y" ] || [ "$servername_confirm" = "Y" ]; then
									break
								else
									printf "\\n\\e[31mPlease enter y or n${CLEARFORMAT}\\n"
								fi
							else
								printf "\\n\\e[31mPlease enter y or n${CLEARFORMAT}\\n"
							fi
						done
					fi
					
					sed -i s/^SPEEDTESTSERVERNO.*$/SPEEDTESTSERVERNO="$serverno"/ "$CONFFILE"
					sed -i s/^SPEEDTESTSERVERNAME.*$/SPEEDTESTSERVERNAME="$servername"/ "$CONFFILE"
					
					SPEEDTESTSERVERNO="$serverno"
					SPEEDTESTSERVERNAME="$servername"
					
					Print_Output true "\\nThe server that will be used is: ${SETTING}${serverno}  (${servername})\\n" "${PASS}"
					Print_Output true "Note that this server has not been varified!!\n\n" "${WARN}"
					return
				done
				
		elif ! Validate_Number "$server"; then
			printf "\\n\\e[31mPlease enter a valid number (1-%s)${CLEARFORMAT}\\n" "$servercount"
		else
			if [ "$server" -lt 1 ] || [ "$server" -gt "$servercount" ]; then
				printf "\\n\\e[31mPlease enter a number between 1 and %s${CLEARFORMAT}\\n" "$servercount"
			else
				serverno="$(echo "$serverlist" | jq -r --argjson index "$((server-1))" '.servers[$index] | .id')"
				servername="$(echo "$serverlist" | jq -r --argjson index "$((server-1))" '.servers[$index] | .name + " (" + .location + ", " + .country + ")"')"
				printf "\\n"
				break
			fi
		fi
	done

	sed -i s/^SPEEDTESTSERVERNO.*$/SPEEDTESTSERVERNO="$serverno"/ "$CONFFILE"
	sed -i s/^SPEEDTESTSERVERNAME.*$/SPEEDTESTSERVERNAME="$servername"/ "$CONFFILE"
	
	SPEEDTESTSERVERNO="$serverno"
	SPEEDTESTSERVERNAME="$servername"
	
	Print_Output true "\\nThe perferred server that SpeedTest will use is now: ${SETTING}${servername}\\n" "${PASS}"
}

dbStorageLoc() {

	ScriptHeader

	currentloc="$SCRIPT_STORAGE_DIR"
	printf "\n${CLEARFORMAT}Select where you want the script to store the speedtest results database file\n\n"
	printf "\nCurrent storage location for the Speedtest database is: ${SETTING}$SCRIPT_STORAGE_DIR${CLEARFORMAT}\n\n"
	printf "Do you wish to change the storage location (y/n)? "
	read answer
	
	if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
		printf "\n\n${CLEARFORMAT}Please enter a directory where the spdstats.db file will be stored\n"
		printf "If the directory does not exist, it will be created\n"
		
		printf "\\n${BOLD}Please enter the directory for the statistics file:${CLEARFORMAT}  "
		read stat_location
		
		if ! [ -d "$stat_location" ]; then
			mkdir -p "$stat_location"
		fi
		
		if ! [ -d "$stat_location" ]; then
			printf "${CRIT}Unable to create the directory $stat_location"
			PressEnter
			return 1
		else
			printf "${CLEARFORMAT}Changing statistics storage directory from ${SETTING}$currentloc${CLEARFORMAT} to ${SETTING}$stat_location${CLEARFORMAT}\\n"
			printf "\\n${BOLD}Proceed (y/n)?${CLEARFORMAT} "
			read answer
			if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
				pwdesc=$(echo $stat_location | sed 's_/_\\/_g')
				sed -i s/^SCRIPT_STORAGE_DIR.*$/SCRIPT_STORAGE_DIR="$pwdesc"/ "$CONFFILE"
				SCRIPT_STORAGE_DIR="$stat_location"
				
				printf "\\n\\n${PASS}Storage Directory changed${CLEARFORMAT}\\n"
			else
				printf "\\n${WARN}Storage Directory has not been changed${CLEARFORMAT}\\n"
			fi
		fi
	else
		printf "\\n${WARN}Storage Directory has not been changed${CLEARFORMAT}\\n"
	fi
}

DaysKeep(){
	case "$1" in
		update)
		
			ScriptHeader
		
			Print_Output true "\nNumber of days that Speedtest data is currently kept for is: ${SETTING}$DAYSTOKEEP${CLEARFORMAT} days\n" "${CLEARFORMAT}"
			
			daystokeep=30
			exitmenu=""
			while true; do
				printf "\\n${BOLD}Please enter the desired number of days to keep speed test data for (30-365 days):${CLEARFORMAT}  "
				read -r daystokeep_choice
				
				if [ "$daystokeep_choice" = "e" ]; then
					exitmenu="exit"
					break
				elif ! Validate_Number "$daystokeep_choice"; then
					printf "\\n${ERR}Please enter a valid number (30-365)${CLEARFORMAT}\\n"
				elif [ "$daystokeep_choice" -lt 30 ] || [ "$daystokeep_choice" -gt 365 ]; then
						printf "\\n${ERR}Please enter a number between 30 and 365${CLEARFORMAT}\\n"
				else
					daystokeep="$daystokeep_choice"
					printf "\\n"
					break
				fi
			done
			
			if [ "$exitmenu" != "exit" ]; then
				sed -i 's/^DAYSTOKEEP.*$/DAYSTOKEEP='"$daystokeep"'/' "$CONFFILE"
				DAYSTOKEEP="$daystokeep"
				
				Print_Output true "\n\nThe number of days which speedtest data will be retained is now: ${SETTING}$daystokeep${PASS} days\n" "${PASS}"
				return 0
			else
				printf "\\n"
				return 1
			fi
		;;
		check)
			DAYSTOKEEP=$(grep "DAYSTOKEEP" "$SCRIPT_CONF" | cut -f2 -d"=")
			echo "$DAYSTOKEEP"
		;;
	esac
}

TableSelect() {
# Sub must set variable $TABLE to pass to PrintOutScreen() and CreateExportDir()
# $1 = screen or CSV
# TABLE="-1" on exit returns to main menu

	tablelistfile="/tmp/tablelist.txt"
	LOOP="false"
	
	ScriptHeader
	[ "$1" = "screen" ] && printf "${PASS}Display SpeedTest Results on screen${CLEARFORMAT}\\n" || printf "${PASS}Export SpeedTest Results to CSV File(s)${CLEARFORMAT}\\n"
	
	"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" ".tables" > "$tablelistfile"
	TABLELIST="$(cat "$tablelistfile")"
	TABLECOUNT=$(wc -w < "$tablelistfile")

	if [ "$TABLECOUNT" -eq 1 ];then
		TABLE=$TABLELIST
		printf "\\n"
		return
	elif [ "$TABLECOUNT" -eq 0 ];then
		printf "\\n${ERR}No data found in the database!${CLEARFORMAT}\\n\\n"
		TABLE="-1"
		return
	else
		printf "\\n${CLEARFORMAT}Data for multiple interfaces found in the database.\\n\\n"
		c=1	
		for n in $TABLELIST
		do
			n2=$(echo "$n" | cut -d "_" -f 2-)
			printf "   %s)    %s\\n" "$c" "$n2"
			let "c=c+1"
		done
		[ "$1" = "csv" ] && printf "\\n   a)    Export data for all interfaces\\n"
		let "c=c-1"
		
		[ "$1" = "screen" ] && printf "\\nPlease select an interface to display (e to exit) (1-%s): " "$c"
		[ "$1" = "csv" ] && printf "\\nPlease select an interface to export (e to exit, a for all) (1-%s): " "$c"
		
		while true
		do
			read answer
		
			if [ "$answer" = "e" ]; then
				TABLE="-1"
				break
			elif [ "$answer" = "a" ] && [ "$1" = "csv" ]; then 
				break
			elif ! Validate_Number "$answer"; then
				printf "\\n\\e[31mPlease enter a valid number (1-%s)${CLEARFORMAT}\\n" "$c"
			else
				if [ "$answer" -lt 1 ] || [ "$answer" -gt "$c" ]; then
					printf "\\n\\e[31mPlease enter a number between 1 and %s${CLEARFORMAT}\\n" "$c"
				else
					TABLE=$(echo $TABLELIST | cut -d " " -f "$answer")
					return
				fi
			fi
		done

		LOOP="true"
		if [ "$1" = "csv" ]; then
			printf "\\n"
			for TABLE in $TABLELIST
			do
				PrintToCSV
			done
		fi	
	fi
}

PrintOutScreen() {
# $TABLE is passed back to sub from 'TableSelect()'

	TableSelect screen
	
	[ "$TABLE" = "-1" ] && return
	
	ScriptHeader Print
	
	{
		echo ".mode column"
		echo ".width 19 0"
	} > /tmp/spd-lastx.sql
	echo "SELECT datetime([Timestamp],'unixepoch','localtime') AS 'Date/Time',printf('%.2f',[Download]) AS 'Download'," >> /tmp/spd-lastx.sql
	echo "printf('%.2f',[Upload]) AS 'Upload',printf('%.2f',[Latency]) AS 'Latency',printf('%.2f',[Jitter]) AS 'Jitter'," >> /tmp/spd-lastx.sql
	echo "printf('%.2f',[PktLoss]) AS 'PktLoss',printf('%.2f',[DataDownload]) AS 'DataDownload'," >> /tmp/spd-lastx.sql
	echo "printf('%.2f',[DataUpload]) AS 'DataUpload',[ServerID],[ServerName] FROM [$TABLE] ORDER BY [Timestamp];" >> /tmp/spd-lastx.sql

	{
		printf "Speedtest results for interface: %s\\n\\n\\n" "$(echo "$TABLE" | cut -d "_" -f 2-)"
		"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" < /tmp/spd-lastx.sql
	} > /tmp/spd-stats-print.txt
	cat /tmp/spd-stats-print.txt | less -E -F

	printf "\\n"
	PressEnter
}

CreateExportDir() {
# $1 Directory

	if ! [ -d "$1" ]; then
		printf "\\n${WARN}The specified directory does not exist! Create the directory? (Y/N): ${CLEARFORMAT}"
		read answer
		if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
			mkdir -p "$1"
			if ! [ -d "$1" ]; then
				Print_Output true "\\nUnable to create Directory!!" "${ERR}"
				Print_Output true "\\nExiting function." "${ERR}"
				PressEnter
				ER="0"
			fi
		fi		
	fi
		
	pwdesc=$(echo $1 | sed 's_/_\\/_g')
	sed -i s/^CSV_OUTPUT_DIR.*$/CSV_OUTPUT_DIR="$pwdesc"/ "$CONFFILE"
	CSV_OUTPUT_DIR="$1"
	Print_Output true "\\nThe export directory has been changed to: ${SETTING}${CSV_OUTPUT_DIR} \\n" "${PASS}"
	PressEnter
	ER="1"
	
}

PrintToCSVMenu() {
	# $1 = init = called at software init, should return after directory selection

	ScriptHeader

	if [ -z "$CSV_OUTPUT_DIR" ]; then

		Print_Output true "No Export Directory for the csv file has been defined yet.\\n" "${WARN}"
		printf "\\n${CLEARFORMAT}Please enter a directory where the export csv file is to be written to: ${SETTING}"
	
		read -r dirin
		ER="1"
		CreateExportDir "$dirin"
		if [ "$ER" = "0" ]; then
			return
		fi
	else
	
		Print_Output true "Current export directory is ${SETTING} ${CSV_OUTPUT_DIR}\\n" "${PASS}"
		printf "${CLEARFORMAT}Do you wish to change export location(Y/N): "
		read -r answer
	
		if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
			printf "\\n${PASS}Please enter a directory for the csv export file: ${SETTING}"
			read dirin

			CreateExportDir "$dirin"
			if [ "$ER" = "0" ]; then
				return
			fi
		fi
	fi

	if [ ! "$1" = "init" ]; then
		TableSelect csv
		[ "$LOOP" = "false" ] && [ ! "$TABLE" = "-1" ] && PrintToCSV
	fi
}

PrintToCSV() {

	if [ -f "/tmp/spd-lastx.sql" ]; then
		rm "/tmp/spd-lastx.sql"
	fi
	
	TS="datetime([Timestamp],'unixepoch','localtime') AS 'Date/Time'"
	FN="${CSV_OUTPUT_DIR}/$(date +%Y-%m-%d)_$(date +%H-%M-%S)-${TABLE}.csv"
	TN=$(echo $TABLE | cut -d "_" -f 2-)
	printf "${CLEARFORMAT}Writing data for interface${SETTING} %s ${CLEARFORMAT} to ${SETTING} %s\n ${CLEARFORMAT}" "$TN" "${FN}"

	{
		echo ".mode csv"
		echo ".headers on"
		echo ".output ${FN}"
	} > /tmp/spd-lastx.sql
	echo "SELECT $TS,[Download],[Upload],[Latency],[Jitter],[PktLoss],[DataDownload],[DataUpload],[ResultURL],[ServerID],[ServerName] FROM [$TABLE] ORDER BY [Timestamp];" >> /tmp/spd-lastx.sql
	"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" < /tmp/spd-lastx.sql
	rm -f /tmp/spd-lastx.sql
	sed -i 's/,,/,null,/g;s/"//g;' "${FN}"
}

DoSpeedtest() {
#1 interface to be tested. 
	
	LICENSE_STRING1="--accept-license"
	LICENSE_STRING2="--accept-gdpr"
	SERVERNO=""	
	IFACE_NAME=$1
	IFACE_NAMEDB="\"$1"\"
	tmpfile=/tmp/spd-stats.txt
	resultfile=/tmp/spd-result.txt
	rm -f "$resultfile"
	rm -f "$tmpfile"

	if [ -n "$PPID" ]; then
		ps | grep -v grep | grep -v $$ | grep -v "$PPID" | grep -i "$SCRIPT_FILENAME" | grep generate | awk '{print $IFACE_NAME}' | xargs kill -9 >/dev/null 2>&1
	else
		ps | grep -v grep | grep -v $$ | grep -i "$SCRIPT_FILENAME" | grep generate | awk '{print $IFACE_NAME}' | xargs kill -9 >/dev/null 2>&1
	fi

	Print_Output true "Checking Speed on Interface: $SETTING$IFACE_NAME" "$CLEARFORMAT"
	Print_Output true "Location of SpeedTest Database: ${SCRIPT_STORAGE_DIR}/spdstats.db" "$CLEARFORMAT"

	if [ -n "$(pidof "$PROC_NAME")" ]; then
		killall -q "$PROC_NAME"
	fi
	
	[ "$SPEEDTESTSERVERNO" -ne 0 ] && SERVERNO="--server-id=$SPEEDTESTSERVERNO" || SERVERNO=""

	"$SPEEDTEST_BINARY" $SERVERNO --format="human-readable" --unit="Mbps" --progress=yes --interface=$IFACE_NAME $LICENSE_STRING1 $LICENSE_STRING2  | tee "$tmpfile" &
	sleep 2

	speedtestcount=0
	while [ -n "$(pidof "$PROC_NAME")" ] && [ "$speedtestcount" -lt 120 ]; do
		speedtestcount="$((speedtestcount + 1))"
		sleep 1
	done
	if [ "$speedtestcount" -ge 120 ]; then
		Print_Output true "Speedtest for $IFACE_NAME hung (> 2 mins), killing process" "$CRIT"
		killall -q "$PROC_NAME"
		continue
	fi
					
	if [ ! -f "$tmpfile" ] || [ -z "$(cat "$tmpfile")" ] || [ "$(grep -c FAILED $tmpfile)" -gt 0 ]; then
		Print_Output true "Error running speedtest for $IFACE_NAME" "$CRIT"
		continue
	fi
					
	TZ=$(cat /etc/TZ)
	export TZ
					
	timenow=$(date +"%s")
	timenowfriendly=$(date +"%c")
					
	download="$(grep Download "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk '{print $2}')"
	upload="$(grep Upload "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk '{print $2}')"
	latency="$(grep Latency "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk '{print $2}')"
	jitter="$(grep Latency "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk '{print $4}' | tr -d '(')"
	pktloss="$(grep 'Packet Loss' "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk '{print $3}' | tr -d '%')"
	resulturl="$(grep 'Result URL' "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk '{print $3}')"
	datadownload="$(grep Download "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk '{print $6}')"
	dataupload="$(grep Upload "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk '{print $6}')"
					
	datadownloadunit="$(grep Download "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk '{print substr($7,1,length($7)-1)}')"
	datauploadunit="$(grep Upload "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk '{print substr($7,1,length($7)-1)}')"
					
	servername="$(grep Server "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | cut -f1 -d'(' | cut -f2 -d':' | awk '{$1=$1;print}')"
	serverid="$(grep Server "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | cut -f2 -d'(' | awk '{print $3}' | tr -d ')')"
					
	! Validate_Bandwidth "$download" && download=0;
	! Validate_Bandwidth "$upload" && upload=0;
	! Validate_Bandwidth "$latency" && latency="null";
	! Validate_Bandwidth "$jitter" && jitter="null";
	! Validate_Bandwidth "$pktloss" && pktloss="null";
	! Validate_Bandwidth "$datadownload" && datadownload=0;
	! Validate_Bandwidth "$dataupload" && dataupload=0;
				
	if [ "$datadownloadunit" = "GB" ]; then
		datadownload="$(echo "$datadownload" | awk '{printf ($1*1024)}')"
	fi
					
	if [ "$datauploadunit" = "GB" ]; then
		dataupload="$(echo "$dataupload" | awk '{printf ($1*1024)}')"
	fi
					
	echo "CREATE TABLE IF NOT EXISTS [spdstats_${IFACE_NAME}] ([StatID] INTEGER PRIMARY KEY NOT NULL,[Timestamp] NUMERIC NOT NULL,[Download] REAL NOT NULL,[Upload] REAL NOT NULL,[Latency] REAL,[Jitter] REAL,[PktLoss] REAL,[ResultURL] TEXT,[DataDownload] REAL NOT NULL,[DataUpload] REAL NOT NULL,[ServerID] TEXT,[ServerName] TEXT);" > /tmp/spd-stats.sql
	"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" < /tmp/spd-stats.sql

	if [ "$(StoreResultURL check)" = "true" ]; then
		echo "INSERT INTO [spdstats_${IFACE_NAME}] ([Timestamp],[Download],[Upload],[Latency],[Jitter],[PktLoss],[ResultURL],[DataDownload],[DataUpload],[ServerID],[ServerName]) values($timenow,$download,$upload,$latency,$jitter,$pktloss,'$resulturl',$datadownload,$dataupload,$serverid,'$servername');" > /tmp/spd-stats.sql
	else
		echo "INSERT INTO [spdstats_${IFACE_NAME}] ([Timestamp],[Download],[Upload],[Latency],[Jitter],[PktLoss],[ResultURL],[DataDownload],[DataUpload],[ServerID],[ServerName]) values($timenow,$download,$upload,$latency,$jitter,$pktloss,'',$datadownload,$dataupload,$serverid,'$servername');" > /tmp/spd-stats.sql
	fi

	"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" < /tmp/spd-stats.sql
					
		{
			echo "DELETE FROM [spdstats_$IFACE_NAME] WHERE [Timestamp] < strftime('%s',datetime($timenow,'unixepoch','-$DAYSTOKEEP day'));"
			echo "PRAGMA analysis_limit=0;"
			echo "PRAGMA cache_size=-20000;"
			echo "ANALYZE spdstats_$IFACE_NAME;"
		} > /tmp/spd-stats.sql
	"$SQLITE3_PATH" "$SCRIPT_STORAGE_DIR/spdstats.db" < /tmp/spd-stats.sql >/dev/null 2>&1
	rm -f /tmp/spd-stats.sql
					
	spdtestresult="$(grep Download "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};'| awk '{$1=$1};1') - $(grep Upload "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};'| awk '{$1=$1};1')"
	spdtestresult2="$(grep Latency "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk '{$1=$1};1') - $(grep 'Packet Loss' "$tmpfile" | awk 'BEGIN { FS = "\r" } ;{print $NF};' | awk '{$1=$1};1')"
				
	printf "\\n"
	Print_Output true "Speedtest results - ${spdtestresult}\\n" "$PASS"
	Print_Output true "Connection quality - ${spdtestresult2}\\n" "$PASS"
}

RunSpeedTest() {
# $1 list of interfaces to be tested.  Seperated by commas

	ScriptHeader
	
	for i in $(echo $1 | tr ',' '\n')
	do
		if [ -e "/sys/class/net/${i}" ]; then
			if [ "$(cat "/sys/class/net/${i}/operstate")" = "up" ]; then
				DoSpeedtest $i
			fi
		else
			Print_Output true "Interface ${i} either does not exist or is not up" "${WARN}"
		fi
	done
}

MainMenu() {

	AUTOMATIC_ENABLED=""

	if AutomaticMode check; then AUTOMATIC_ENABLED="${PASS}Enabled"; else AUTOMATIC_ENABLED="${ERR}Disabled"; fi
	TEST_SCHEDULE="$(TestSchedule check)"
	if [ "$(echo "$TEST_SCHEDULE" | cut -f2 -d'|' | grep -c "/")" -gt 0 ] && [ "$(echo "$TEST_SCHEDULE" | cut -f3 -d'|')" -eq 0 ]; then
		TEST_SCHEDULE_MENU="Every $(echo "$TEST_SCHEDULE" | cut -f2 -d'|' | cut -f2 -d'/') hours"
	elif [ "$(echo "$TEST_SCHEDULE" | cut -f3 -d'|' | grep -c "/")" -gt 0 ] && [ "$(echo "$TEST_SCHEDULE" | cut -f2 -d'|')" = "*" ]; then
		TEST_SCHEDULE_MENU="Every $(echo "$TEST_SCHEDULE" | cut -f3 -d'|' | cut -f2 -d'/') minutes"
	else
		TEST_SCHEDULE_MENU="Hours: $(echo "$TEST_SCHEDULE" | cut -f2 -d'|')    -    Minutes: $(echo "$TEST_SCHEDULE" | cut -f3 -d'|')"
	fi
	
	if [ "$(echo "$TEST_SCHEDULE" | cut -f1 -d'|')" = "*" ]; then
		TEST_SCHEDULE_MENU2="Days of week: All"
	else
		TEST_SCHEDULE_MENU2="Days of week: $(echo "$TEST_SCHEDULE" | cut -f1 -d'|')"
	fi
	
	STORERESULTURL_MENU=""
	if [ "$(StoreResultURL check)" = "true" ]; then
		STORERESULTURL_MENU="Enabled"
	else
		STORERESULTURL_MENU="Disabled"
	fi

	ScriptHeader
	
	printf "${CLEARFORMAT}\\n"
	printf "1.    Run a Speedtest now\\n\\n"
	printf "2.    Toggle automatic Speedtests\\n"
	printf "        Currently: ${BOLD}${AUTOMATIC_ENABLED}%s${CLEARFORMAT}\\n\\n"
	printf "3.    Configure schedule for automatic speedtests\\n"
	printf "        ${SETTING}%s\\n        %s${CLEARFORMAT}\\n\\n" "$TEST_SCHEDULE_MENU" "$TEST_SCHEDULE_MENU2"
	printf "4.    Choose interface that script should test on\\n"
	printf "        Current Interface: ${SETTING}${IFACE}${CLEARFORMAT}\\n\\n"
	printf "5.    Choose perferred server\\n"
	printf "        Current Server being used for SpeedTest is: ${SETTING}${SPEEDTESTSERVERNAME}${CLEARFORMAT}\\n\\n"
	printf "6.    Toggle storage of speedtest result URLs\\n"
	printf "        Currently: ${SETTING}%s${CLEARFORMAT}\\n\\n" "$STORERESULTURL_MENU"
	printf "7.    Choose location to store SpeedTest database\\n"
	printf "        Current location of SpeedTest database: ${SETTING}${SCRIPT_STORAGE_DIR}${CLEARFORMAT}\\n\\n"
	printf "8.    Choose number of days to keep in database\\n"
	printf "        Current number of days of data being kept: ${SETTING}${DAYSTOKEEP}${CLEARFORMAT}\\n\\n"
	printf "9.    Print database to screen\\n\\n"
	printf "10.   Export databse to CSV file\\n"
	printf "        Current CSV export directory is: ${SETTING}${CSV_OUTPUT_DIR}${CLEARFORMAT}\\n\\n"
	printf "11.   Reinitlize Database (Delete Current Database)\\n"
	printf "\\ne.    Exit Script\\n"
	printf "\\nChoose an Option:  "
	
	while true; do
		read -r menu

		case "$menu" in
			1)
				Check_Lock Menu
				RunSpeedTest "$IFACE"
				Clear_Lock
				PressEnter
				break
			;;
			2)
				printf "\\n"
				if AutomaticMode check; then
					AutomaticMode disable
				else
					AutomaticMode enable
				fi
				break	
			;;
			3)
				Menu_EditSchedule
				PressEnter
				break
			;;
			4)
				Generate_Interface_List
				PressEnter
				break
			;;
			5)
				GenerateServerList
				PressEnter
				break
			;;
			6)
				if [ "$(StoreResultURL check)" = "true" ]; then
					StoreResultURL disable
				elif [ "$(StoreResultURL check)" = "false" ]; then
					StoreResultURL enable
				fi
				break
			;;
			7)
				dbStorageLoc
				PressEnter
				break
			;;
			8)
				DaysKeep update
				PressEnter
				break
			;;
			9)
				PrintOutScreen
				break
			;;
			10)
				CSVLOOP="false"
				PrintToCSVMenu
				printf "\\n"
				PressEnter
				break
			;;
			11)
				Reset_DB
				PressEnter
				break
			;;
			e)
				printf "\\n${BOLD}Thanks for using %s!${CLEARFORMAT}\\n\\n\\n" "$SCRIPT_NAME"
				exit 0
			;;
			*)
				MainMenu
			;;
		esac
	done
	MainMenu
	exit
}


# Begin main routine

GetVariables

mkdir -p $SCRIPT_STORAGE_DIR

if [ "$#" = "0" ];then
echo "Main Menu\\n"
	MainMenu
	
else
	case "$1" in
		generate)
			# $1 = Generate Command
			# $2 = List of custom interfaces.  If none present, use IFACE
			logger -t "$SCRIPT_NAME" "Running Automated Speedtest from other than main menu"
			NTP_Ready
			Check_Lock
			if [ -z "$2" ]; then
				RunSpeedTest "$IFACE"
			else
				RunSpeedTest "$2"
			fi
			Clear_Lock
			exit 0
		;;
		csv)
			logger -t "$SCRIPT_NAME" "Run Export to CSV in silent mode:"
			PrintToCSV silent
			exit 0
		;;
		startup)
			logger -t "$SCRIPT_NAME" "Running SpdOpenWRT in Startup Mode"
			NTP_Ready
			Check_Lock
			if AutomaticMode check; then Auto_Cron create 2>/dev/null; else Auto_Cron delete 2>/dev/null; fi
			Clear_Lock
		;;
		*)
			logger -t "$SCRIPT_NAME" "Runnng Main Menu....."
			MainMenu
			exit 0
		;;
	esac
fi			



