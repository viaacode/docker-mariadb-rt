-- Flush privileges first to make this work when server is started
-- with --skip-grant-tables
-- therefore this script should be executed as final step in the
-- database initialization sequence

FLUSH PRIVILEGES;

CREATE USER 'recoverytest'@'%' IDENTIFIED BY '$RecoverySecret';
GRANT SELECT ON *.* TO 'recoverytest'@'%';

FLUSH PRIVILEGES;

quit
