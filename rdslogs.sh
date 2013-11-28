#!/bin/bash

usage()
{
  cat << EOF
  RDS Logs Manager

  usage: $0 -h host -u user -p password -P port -a [config|unconfig|enable|disable|rotate|dump] -g default

  $0 -h localhost -u root -p admin -P 3306 -a config -g name

  OPTIONS:
     -h    Host
     -u    User
     -p    Password
     -P    Port
     -a    Actions: [config|unconfig|enable|disable|rotate|dump]
     -g    RDS Parameter Group
EOF
}

while getopts “h:u:p:P:a:g:” OPTION
do
  case $OPTION in
    h)
      HOST=$OPTARG
      ;;
    u)
      USER=$OPTARG
      ;;
    p)
      PASSWORD=$OPTARG
      ;;
    P)
      PORT=$OPTARG
      ;;
    a)
      if [[ $OPTARG == "config"   ||
            $OPTARG == "unconfig" ||
            $OPTARG == "enable"   ||
            $OPTARG == "disable"  ||
            $OPTARG == "rotate"   ||
            $OPTARG == "dump"     ]]; then
        ACTION=$OPTARG
      else
        continue
      fi
      ;;
    g)
      GROUP=$OPTARG
      ;;
    ?)
      usage
      exit
      ;;
    esac
done

if [[ ( -z $HOST && -z $USER && -z $PASSWORD && -z $PORT && -z $ACTION ) || ( -z $ACTION && -z $GROUP ) ]]
then
  usage
  exit 1
fi

if ( ! type -P 'mysql' > /dev/null ) || ( ! type -P 'mysqldump' > /dev/null )
then
  echo "Not exist mysql client, please install."
  exit 1
fi

if [[ ! -n "$AWS_CREDENTIAL_FILE" ]]
then
  echo "Is not define variable AWS_CREDENTIAL_FILE in your bash."
  exit 1
fi

if [[ $ACTION == "config" ]]
then
  if ( ! type -P "rds-modify-db-parameter-group" > /dev/null )
  then
    echo "Install and configure Amazon RDS Command Line Toolkit"
    exit 1
  fi

  rds-modify-db-parameter-group $GROUP \
    --parameters "name=general_log,value=ON,method=immediate" \
    --parameters "name=slow_query_log, value=ON, method=immediate" \
    --parameters "name=long_query_time, value=10, method=immediate" \
    --parameters "name=min_examined_row_limit, value=100, method=immediate" \
    --parameters "name=log_queries_not_using_indexes, value=1, method=immediate" \
    --parameters="name=event_scheduler, value=ON, method=immediate"
elif [[ $ACTION == "unconfig" ]]
then
  if ! type -P "rds-modify-db-parameter-group" > /dev/null
  then
    echo "Install and configure Amazon RDS Command Line Toolkit"
    exit 1
  fi

  rds-modify-db-parameter-group $GROUP \
    --parameters "name=general_log,value=OFF,method=immediate" \
    --parameters "name=slow_query_log, value=OFF, method=immediate" \
    --parameters="name=event_scheduler, value=OFF, method=immediate"
elif [[ $ACTION == "enable" ]]
then
  CMDS[0]="CREATE EVENT IF NOT EXISTS ev_rds_slow_log_rotation    ON SCHEDULE EVERY 6 HOUR   DO CALL mysql.rds_rotate_slow_log();"
  CMDS[1]="CREATE EVENT IF NOT EXISTS ev_rds_general_log_rotation ON SCHEDULE EVERY 6 HOUR   DO CALL mysql.rds_rotate_general_log();"
  CMDS[2]="CREATE EVENT IF NOT EXISTS ev_rds_gsh_rotation         ON SCHEDULE EVERY 6 HOUR   DO CALL mysql.rds_rotate_global_status_history();"
  CMDS[3]="CREATE EVENT IF NOT EXISTS ev_rds_gsh_collector        ON SCHEDULE EVERY 1 MINUTE DO CALL mysql.rds_collect_global_status_history();"
  CMDS[4]="FLUSH STATUS;"
  CMDS[5]="CALL mysql.rds_enable_gsh_collector();"
elif [[ $ACTION == "disable" ]]
then
  CMDS[0]="CALL mysql.rds_disable_gsh_collector();"
  CMDS[1]="DROP EVENT ev_rds_gsh_collector;"
  CMDS[2]="DROP EVENT ev_rds_gsh_rotation;"
  CMDS[3]="DROP EVENT ev_rds_slow_log_rotation;"
  CMDS[4]="DROP EVENT ev_rds_general_log_rotation;"
elif [[ $ACTION == "rotate" ]]
then
  CMDS[0]="CALL mysql.rds_rotate_slow_log;"
  CMDS[1]="CALL mysql.rds_rotate_general_log;"
elif [[ $ACTION == "dump" ]]
then
  DATETIME=$(date '+%Y%m%d_%H%M%S')

  mysqldump -h ${HOST} \
            -P ${PORT} \
            -u ${USER} \
            -p${PASSWORD} \
            --default-character-set=utf8 \
            --skip-extended-insert \
            --single-transaction \
            mysql \
            general_log > general_${DATETIME}.log

  mysqldump -h ${HOST} \
            -P ${PORT} \
            -u ${USER} \
            -p${PASSWORD} \
            --default-character-set=utf8 \
            --skip-extended-insert \
            --single-transaction \
            mysql \
            slow_log > slow_${DATETIME}.log
fi

for ((i = 0; i < ${#CMDS[@]}; i++))
do
  echo "${CMDS[i]}"
  mysql -h ${HOST} \
        -P ${PORT} \
        -u ${USER} \
        -p${PASSWORD} \
        mysql -e "${CMDS[i]}"
done
