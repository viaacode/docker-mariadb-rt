#!/usr/bin/env bash

while getopts ":d:l:t:" opt; do
    case $opt in
        d) BackupDir=$OPTARG
            ;;
        l) BinLogDir=$OPTARG
            ;;
        t) Time=$OPTARG
            ;;
    esac
done

if [ ! -d "/var/lib/mysql/mysql" ]; then

    [ -z "$BackupDir" ] && exit 1 # BackupDir mandatary
    Time=${Time:=null}

    RecoveryDir="$RecoveryArea/$(basename $BackupDir)"
    Report="$RecoveryArea/recovery_report.txt"
    [ -e $Report ] && rm -f $Report

    mysql=( mysql --protocol=socket -uroot )
    Uid=$(id -u mysql)

    echo "$(date '+%m/%d %H:%M:%S'): Recovering Database files"
    rm -fr $RecoveryArea/*
    cat <<EOF | socat -,ignoreeof $RecoverySocket
    { \
        "client": "$HOSTNAME", \
        "path": "$BackupDir", \
        "uid": "$Uid", \
        "time": "$Time" \
    }
EOF
    StatusFile="$(find $RecoveryDir -name backup.status)"
    DataDir="$(dirname $(find $RecoveryDir -type d -name mysql))"
    BinLogDir=${BinLogDir:-$DataDir}

    # symlink the recovered database files to the standard datafile location
    for i in $DataDir/*; do ln -s $i /var/lib/mysql; done

    echo -e "\n$(date '+%m/%d %H:%M:%S'): Recovery report for $HOSTNAME:\n" >>$Report
    cat $StatusFile 2>&1 | tee -a $Report

    echo "$(date '+%m/%d %H:%M:%S'): Checking Database innodb file integrity"
    innochecksum /var/lib/mysql/ibdata*
    RC=$? # save rc because date command below overwrites it
    echo "$(date '+%m/%d %H:%M:%S'): Checking Database innodb file integrity ended with exitcode $RC" | tee -a $Report
    [ $RC -ne 0 ] && exit $RC

    echo "$(date '+%m/%d %H:%M:%S'): Starting MySQL Server"
    # Do not open tcp socket yet
    coproc tailcop {
        exec /usr/local/bin/docker-entrypoint.sh --skip-grant-tables --skip-networking 2>&1 
    }

    exec 3<&${tailcop[0]}

    while read -ru 3 line; do
     echo $line
     [ $(expr "$line" : '.*InnoDB: .* started; log sequence number') -gt 0 ] && echo $line >>$Report
     [ $(expr "$line" : '.*\[Note\] mysqld: ready for connections.') -gt 0 ] && break
    done

    # Display output of mysqld during recovery
    cat <&3 &

    echo "$(date '+%m/%d %H:%M:%S'): Recover binary logs"
    cat <<EOF | socat -,ignoreeof $RecoverySocket
    { \
        "client": "$HOSTNAME", \
        "path": "$BinLogDir/binlog.index", \
        "uid": "$Uid", \
        "time": "$Time" \
    }
EOF
    firstlog=( $(egrep '^binlog\.[0-9]+\s[0-9]+$' "$StatusFile") )
    # firstlog[0] : filename of binlog during backup"
    # firstlog[1] : position in the firstlog during backup snapshot
    args=( "-j ${firstlog[1]}" )
    [ "$Time" != "null" ] && args+=( "--stop-datetime='$Time'" )
    while read -r file; do
        # As long as we have not seen the first loga, skip
        # entries in the binlog list until we encounter the first log
        [ ${#args[*]} -le 1 -a "${firstlog[0]}" != $(basename $file) ] && continue
        # add binlog to argument list and recover it
        args+=( "$RecoveryArea/$(basename $file)" )
        echo "$(date '+%m/%d %H:%M:%S'): Recovering binlog: $file"
         cat <<-EOF | socat -,ignoreeof $RecoverySocket
            { \
                "client": "$HOSTNAME", \
                "path": "$file", \
                "uid": "$Uid" \
            }
EOF
    done <$RecoveryArea/binlog.index

    echo "$(date '+%m/%d %H:%M:%S'): Applying binlogs: ${args[@]}" | tee -a $Report
    eval mysqlbinlog ${args[@]} | ${mysql[@]}
    # mysqlbinlog does not give non-zero return code when it fails

    # Check datebase table integrity
    echo "$(date '+%m/%d %H:%M:%S'): Checking Database table integrity"
    mysqlcheck --user=root --all-databases
    RC=$?
    echo "$(date '+%m/%d %H:%M:%S'): Checking Database table integrity ended with exitcode $RC" | tee -a $Report
    [ $RC -ne 0 ] && exit $RC

    # Create Test User, etc ..."
    # This flushes privileges!
    sed -r -i -e "s/\\\$RecoverySecret/$RecoverySecret/" /docker-entrypoint-initdb.d/90-create_test_user.sql
    for f in /docker-entrypoint-initdb.d/*.sql; do
        echo "$0: running $f"
    	eval ${mysql[@]} < "$f"
    done

    # Shutdown
    echo "$(date '+%m/%d %H:%M:%S'): Shutting down MySQL Server"
    [ -n "$tailcop_PID" ] && kill $tailcop_PID && wait $tailcop_PID
    exit 0
else
    # Delegate control to the docker-io/mysql container implementation
    exec /usr/local/bin/docker-entrypoint.sh mysqld
fi
