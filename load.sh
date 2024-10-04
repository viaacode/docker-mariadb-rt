#!/usr/bin/env bash

while getopts "d:t:" opt; do
    case $opt in
        d) ORIGDUMP=$OPTARG
            ;;
        t) Time=$OPTARG
            ;;
    esac
done

[ -z "$ORIGDUMP" ] && exit 1 # BackupDir mandatary
Time=${Time:=null}

DUMPBASE="/docker-entrypoint-initdb.d/10-mysqldump"
MYSQLOPTS="--max_allowed_packet=64M --innodb_log_files_in_group=8 --innodb_log_file_size=20M"

# Recover the dump unless it has been recovered before
if [ ! -r $DUMPBASE.sql* ] ; then

    DUMPFILE="$RecoveryArea/$(basename $ORIGDUMP)"

    # Recover the dump file
    echo "$(date '+%m/%d %H:%M:%S'): Recovering dump file: $DUMPFILE"
    [ -r $DUMPFILE ] && rm $DUMPFILE
    cat <<EOF | socat -,ignoreeof $RecoverySocket
    { \
        "client": "$HOSTNAME", \
        "path": "$ORIGDUMP", \
        "uid": "$(id -u)" \
    }
EOF
    [ -r $DUMPFILE ] || exit 5

    # Creating the link below will make docker-entrypoint.sh import it.
    # docker-entrypoint.sh uses filename extension to determine file type.
    file -L $DUMPFILE | grep -qwi 'gzip' && EXT='sql.gz' || EXT='sql'
    ln -s $DUMPFILE "$DUMPBASE.$EXT"
    chown mysql:mysql $DUMPFILE

    sed -r -i -e "s/\\\$RecoverySecret/$RecoverySecret/" /docker-entrypoint-initdb.d/90-create_test_user.sql

    coproc tailcop {
        exec docker-entrypoint.sh $MYSQLOPTS --skip-networking 2>&1 
    }

    exec 3<&${tailcop[0]}

    while read -ru 3 line; do
        echo $line
        [ $(expr "$line" : '.*MariaDB init process done. Ready for start up.') -gt 0 ] && break
    done

    while read -ru 3 line; do
        echo $line
        [ $(expr "$line" : '.*\[Note\] m\w*d: ready for connections.') -gt 0 ] && break
    done

    # Keep reading and showing myqld messages
    cat <&3 &

    echo "$(date '+%m/%d %H:%M:%S'): Shutting down MySQL Server"
    [ -n "$tailcop_PID" ] && kill $tailcop_PID && wait $tailcop_PID
fi
exec /usr/local/bin/docker-entrypoint.sh $MYSQLOPTS
