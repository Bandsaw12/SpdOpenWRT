SpdOpenWRT.sh

SpdOpenWRT.sh is adapted from the script SpdMerlin written by JackYaz for the Merlin firmware for Asus routers (https://github.com/jackyaz/spdMerlin). The script was developed using OpenWRT 21.02 on a Raspberry Pi 4B.

SpdOpenWRT.sh uses the SpeedTest CLI binary file from Ookla (https://www.speedtest.net/apps/cli) to test the speed of one or more internet facing interfaces and store the results in a local SQL database.  A speed test can be run on demand or at scheduled times.  Recorded results for each interface can be either displayed on the screen or exported to Excel CSV files.

On first run of the script, SpdOpenWRT.sh will check for all required dependent packages and install any packages that are missing. 
Notes:

1.	SpdOpenWRT.sh is a Command Line Interface (CLI) script only.  There is no LuCI interface available.

2.	SpdOpenWRT.sh uses a file called “SpdOpenWRT.conf” to store program options.  This file is created in the same directory that the SpdOpenWRT.sh script is.  On first run of       SpdOpenWRT.sh, the script will check for the conf file existence, and if not found, will proceed to ask a series of questions and create the conf file.

3.	On first use, the script will prompt for the users acceptance of Ookla’s terms of use and privacy statements.  A YES answer is required to continue using the script.  Links      to Ookla’s terms and privacy statements are presented in the script.

4.	Automated speed tests are done via OpenWRT’s crontab system. SpdOpenWRT.sh has a menu option to set up the proper crontab entries.  This script was written on a Raspberry PI     4B running version 21.02.  On this platform, the crontab file survives a reboot.  If using this script on a router where the crontab entries do not survive a reboot, add the     following to the routers list of programs to run at startup (LuCI: System->Startup->Local Startup Tab) to add the appropriate crontab entries;

          /path-to-script/SpdOpenWRT.sh startup 

5.	In addition to running SpdOpenWRT.sh in as a menu driven script, the following arguments can be used to automated processes;

      a)	SpdOpenWRT.sh generate <interface>
    
            Will run a speed test on the specified interface, store the results, and exit to the shell.  If interface is not specified, all interfaces specified in the conf file             will be tested.
  
      b)	SpdOpenWRT.sh csv

          Will have the script export the SQL database to csv files silently, then exit to the shell.  The location of the csv files must be defined before hand by executing the           script in menu mode

      c)	SpdOpenWRT startup

          Will have the script check the crontab entry to ensure the appropriate entry is in place to run scheduled speed test jobs.  See above for more detail.

  Other

    1.	One table is created in the database per interface tested.  The table name is the same as the interface under test.  Therefore, if you change interfaces, the speedtest           results from the previous interface are not lost.

