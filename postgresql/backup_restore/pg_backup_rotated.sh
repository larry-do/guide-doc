#!/bin/bash

###########################
####### LOAD CONFIG #######
###########################

while [ $# -gt 0 ]; do
        case $1 in
                -c)
                        CONFIG_FILE_PATH="$2"
                        shift 2
                        ;;
                *)
                        ${ECHO} "Unknown Option \"$1\"" 1>&2
                        exit 2
                        ;;
        esac
done

if [ -z $CONFIG_FILE_PATH ] ; then
        SCRIPTPATH=$(cd ${0%/*} && pwd -P)
        CONFIG_FILE_PATH="${SCRIPTPATH}/pg_backup.config"
fi

if [ ! -r ${CONFIG_FILE_PATH} ] ; then
        echo "Could not load config file from ${CONFIG_FILE_PATH}" 1>&2
        exit 1
fi

source "${CONFIG_FILE_PATH}"

###########################
#### PRE-BACKUP CHECKS ####
###########################

# Make sure we're running as the required backup user
if [ "$BACKUP_USER" != "" -a "$(id -un)" != "$BACKUP_USER" ] ; then
	echo "This script must be run as $BACKUP_USER. Exiting." 1>&2
	exit 1
fi


###########################
### INITIALISE DEFAULTS ###
###########################

if [ ! $HOSTNAME ]; then
	HOSTNAME="localhost"
fi;

if [ ! $PORT ]; then
	PORT="5432"
fi;

if [ ! $USERNAME ]; then
	USERNAME="postgres"
fi;


###########################
#### START THE BACKUPS ####
###########################

function perform_backups()
{
	SUFFIX=$1
	FINAL_BACKUP_DIR=$BACKUP_DIR"_`date +\%Y-\%m-\%d`$SUFFIX/"

	echo "Making backup directory in $FINAL_BACKUP_DIR"

	if ! mkdir -p $FINAL_BACKUP_DIR; then
		echo "Cannot create backup directory in $FINAL_BACKUP_DIR. Go and fix it!" 1>&2
		exit 1;
	fi;
	
	
	###########################
	###### FULL BACKUPS #######
	###########################
	BACKUP_DB_ONLY_CLAUSE="and (1 = 2"
	for BACKUP_DB in ${BACKUP_DB_LIST//,/ }
	do
		BACKUP_DB_ONLY_CLAUSE="$BACKUP_DB_ONLY_CLAUSE or datname = '$BACKUP_DB'"
	done
	BACKUP_DB_ONLY_CLAUSE="$BACKUP_DB_ONLY_CLAUSE)"

	FULL_BACKUP_QUERY="select datname from pg_database where not datistemplate and datallowconn $BACKUP_DB_ONLY_CLAUSE order by datname;"

	echo -e "\n\nPerforming full backup..."

	for DATABASE in `psql -h "$HOSTNAME" -p "$PORT" -U "$USERNAME" -At -c "$FULL_BACKUP_QUERY" postgres`
	do

		BACKUP_FILE_DIR=$FINAL_BACKUP_DIR$DATABASE"_`date +\%Y\%m\%d_\%H\%M\%S`.backup"
		echo "Full backup of database $DATABASE... at directory $BACKUP_FILE_DIR" 

		if ! pg_dump --file "$BACKUP_FILE_DIR.in_progress" --host "$HOSTNAME" --port "$PORT" --username "$USERNAME" --verbose --role "$USERNAME" --format=c --blobs --encoding "UTF8" "$DATABASE"; then
			echo "[!!ERROR!!] Failed to produce custom backup database $DATABASE" 1>&2
		else
			mv $BACKUP_FILE_DIR.in_progress $BACKUP_FILE_DIR
		fi

	done

	echo -e "\nAll database backups complete!"
}

# MONTHLY BACKUPS
if [[ $ENABLE_MONTHLY_BACKUP == "true" ]]; then
	DAY_OF_MONTH=`date +%d`
	if [ $DAY_OF_MONTH -eq 1 ];
	then
		# Delete all expired monthly directories
		find $BACKUP_DIR -maxdepth 1 -name "*-monthly" -exec rm -rf '{}' ';'
		perform_backups "-monthly"
	fi
fi

# WEEKLY BACKUPS
if [[ $ENABLE_WEEKLY_BACKUP == "true" ]]; then
	DAY_OF_WEEK=`date +%u` #1-7 (Monday-Sunday)
	EXPIRED_DAYS=`expr $((($WEEKS_TO_KEEP * 7) + 1))`
	if [ $DAY_OF_WEEK = $DAY_OF_WEEK_TO_KEEP ];
	then
		# Delete all expired weekly directories
		find $BACKUP_DIR -maxdepth 1 -mtime +$EXPIRED_DAYS -name "*-weekly" -exec rm -rf '{}' ';'
		perform_backups "-weekly"
	fi
fi

# DAILY BACKUPS
if [[ $ENABLE_DAILY_BACKUP == "true" ]]; then
	# Delete daily backups 7 days old or more
	find $BACKUP_DIR -maxdepth 1 -mtime +$DAYS_TO_KEEP -name "*-daily" -exec rm -rf '{}' ';'
	perform_backups "-daily"
fi
