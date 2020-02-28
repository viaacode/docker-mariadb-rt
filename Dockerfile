# This container inherits from https://github.com/docker-library/mysql
# It recovers a mysql LVM snapshot from the backup system 
# performs roll forward recovery and runs consistency checks 

FROM mariadb:10.3
MAINTAINER Herwig Bogaert

ARG RecoveryAreaGid=4

RUN apt-get update && apt-get install -y file socat && rm -rf /var/lib/apt/lists/*

# Grant the mysql user permission to manipulate the recovered files
RUN usermod -G $RecoveryAreaGid mysql
ENV MYSQL_RANDOM_ROOT_PASSWORD true

COPY show_dbs.sql /docker-entrypoint-initdb.d/10-show_dbs.sql
COPY create_test_user.sql /docker-entrypoint-initdb.d/90-create_test_user.sql

COPY recover.sh /usr/local/bin/
COPY load.sh /usr/local/bin/

ENV RecoveryArea /recovery_area
ENV RecoverySocket "unix:/recovery_socket"
