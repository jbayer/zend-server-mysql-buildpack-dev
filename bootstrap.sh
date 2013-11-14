#!/bin/bash

# include .files when moving things around
shopt -s dotglob

# Preserve Cloud Foundry information
export LD_LIBRARY_PATH=/app/zend-server-6-php-5.4/lib
export PHP_INI_SCAN_DIR=/app/zend-server-6-php-5.4/etc/conf.d
export PHPRC=/app/zend-server-6-php-5.4/etc
echo "env[VCAP_APPLICATION] = ${VCAP_APPLICATION}"  >> /app/zend-server-6-php-5.4/etc/php-fpm.conf
echo "Launching Zend Server..."
export ZEND_UID=`id -u`
export ZEND_GID=`id -g`

ZS_MANAGE=/app/zend-server-6-php-5.4/bin/zs-manage

# Change UID in Zend Server configuration to the one used in the gear
sed "s/vcap/${ZEND_UID}/" ${PHP_INI_SCAN_DIR}/ZendGlobalDirectives.ini.erb > ${PHP_INI_SCAN_DIR}/ZendGlobalDirectives.ini
sed "s/VCAP_PORT/${PORT}/" /app/nginx/conf/sites-available/default.erb > /app/nginx/conf/sites-available/default

rm -rf /app/nginx/conf/sites-enabled
mkdir -p /app/nginx/conf/sites-enabled
ln -f -s /app/nginx/conf/sites-available/default /app/nginx/conf/sites-enabled

echo "Creating/Upgrading Zend databases. This may take several minutes..."
/app/zend-server-6-php-5.4/gui/lighttpd/sbin/php -c /app/zend-server-6-php-5.4/gui/lighttpd/etc/php-fcgi.ini /app/zend-server-6-php-5.4/share/scripts/zs_create_databases.php zsDir=/app/zend-server-6-php-5.4 toVersion=6.1.0

#Generate 7 day trial license
#/app/zend-server-6-php-5.4/bin/zsd /app/zend-server-6-php-5.4/etc/zsd.ini --generate-license

#Start Zend Server
echo "Starting Zend Server"
/app/zend-server-6-php-5.4/bin/zendctl.sh start 

# Bootstrap Zend Server
echo "Bootstrap Zend Server"
if [ -z $ZS_ADMIN_PASSWORD ]; then
   #Set the GUI admin password to "changeme" if a user did not
   ZS_ADMIN_PASSWORD="changeme"
   #Generate a Zend Server administrator password if one was not specificed in the manifest
   # ZS_ADMIN_PASSWORD=`date +%s | sha256sum | base64 | head -c 8` 
   # echo ZS_ADMIN_PASSWORD=$ZS_ADMIN_PASSWORD
fi 
$ZS_MANAGE bootstrap-single-server -p $ZS_ADMIN_PASSWORD -a 'TRUE' > /app/zend-server-6-php-5.4/tmp/api_key

# Get API key from bootstrap script output
WEB_API_KEY=`cut -s -f 1 /app/zend-server-6-php-5.4/tmp/api_key`
WEB_API_KEY_HASH=`cut -s -f 2 /app/zend-server-6-php-5.4/tmp/api_key`

# Join the server to a cluster
HOSTNAME=`hostname`
APP_UNIQUE_NAME=$HOSTNAME

if [[ -z $MYSQL_HOSTNAME && -z $MYSQL_PORT && -z $MYSQL_USERNAME && -z $MYSQL_PASSWORD && -z $MYSQL_DBNAME ]]; then
    MYSQL_HOSTNAME=`/app/bin/json-env-extract.php VCAP_SERVICES cleardb-n/a.0.credentials.hostname`
    MYSQL_PORT=`/app/bin/json-env-extract.php VCAP_SERVICES cleardb-n/a.0.credentials.port`
    MYSQL_USERNAME=`/app/bin/json-env-extract.php VCAP_SERVICES cleardb-n/a.0.credentials.username`
    MYSQL_PASSWORD=`/app/bin/json-env-extract.php VCAP_SERVICES cleardb-n/a.0.credentials.password`
    MYSQL_DBNAME=`/app/bin/json-env-extract.php VCAP_SERVICES cleardb-n/a.0.credentials.name`
fi

echo MYSQL_HOSTNAME=$MYSQL_HOSTNAME > /app/zend_mysql.sh
echo MYSQL_PORT=$MYSQL_PORT >> /app/zend_mysql.sh
echo MYSQL_USERNAME=$MYSQL_USERNAME >> /app/zend_mysql.sh
echo MYSQL_PASSWORD=$MYSQL_PASSWORD >> /app/zend_mysql.sh
echo MYSQL_DBNAME=$MYSQL_DBNAME >> /app/zend_mysql.sh

if [[ -n $MYSQL_HOSTNAME && -n $MYSQL_PORT && -n $MYSQL_USERNAME && -n $MYSQL_PASSWORD && -n $MYSQL_DBNAME ]]; then
    # Get host's IP (there probably is a better way. No cloud foundry provided environment variable is suitable.
    APP_IP=`/sbin/ifconfig w-${HOSTNAME}-1| grep 'inet addr:' | awk {'print \$2'}| cut -d ':' -f 2`

    # Actually join cluster
    $ZS_MANAGE server-add-to-cluster -n $APP_UNIQUE_NAME -i $APP_IP -o $MYSQL_HOSTNAME:$MYSQL_PORT -u $MYSQL_USERNAME -p $MYSQL_PASSWORD -d $MYSQL_DBNAME -N $WEB_API_KEY -K $WEB_API_KEY_HASH -s | sed 's/ //g' > /app/zend_cluster.sh
    eval `cat /app/zend_cluster.sh`

    # Configure session clustering
    $ZS_MANAGE store-directive -d 'zend_sc.ha.use_broadcast' -v '0' -N $WEB_API_KEY -K $WEB_API_KEY_HASH
    $ZS_MANAGE store-directive -d 'session.save_handler' -v 'cluster' -N $WEB_API_KEY -K $WEB_API_KEY_HASH
    $ZS_MANAGE restart-php -p -N $WEB_API_KEY -K $WEB_API_KEY_HASH
fi

# Fix GID/UID until ZSRV-11165 is resolved
sed -e "s|^\(zend.httpd_uid[ \t]*=[ \t]*\).*$|\1$ZEND_UID|" -i /app/zend-server-6-php-5.4/etc/conf.d/ZendGlobalDirectives.ini
sed -e "s|^\(zend.httpd_gid[ \t]*=[ \t]*\).*$|\1$ZEND_GID|" -i /app/zend-server-6-php-5.4/etc/conf.d/ZendGlobalDirectives.ini
/app/zend-server-6-php-5.4/bin/zendctl.sh start

# Debug output
if [[ -n $DEBUG ]]; then
    set
    netstat -lnpt
    bash --version
fi
