#!/bin/bash
#
# Author: Stefano Artioli
# Date:   Sep 2023
#
# This script is to make simplify the process of standing up a guacamole server leveraging
# docker to start a postgres, guacd, guacamole client and nginx container. Access to Guacamole
# is configured to leverage SAML and SAML configuration is captured when using this script.
#

# check if docker is running

if [ -f .env ]; then
    echo "Error: .env file found. Exiting the script."
    exit 1
fi

if ! (docker ps >/dev/null 2>&1)
then
	echo "docker daemon not running, will exit here!"
	exit
fi

## Check if jq is installed, if not, install it
REQUIRED_PKG="netcat"

PKG_OK=$(dpkg-query -W --showformat='${Status}\n' $REQUIRED_PKG|grep "install ok installed")

echo ""
echo Checking for $REQUIRED_PKG: $PKG_OK
echo ""

if [ "" = "$PKG_OK" ]; then
  echo "No $REQUIRED_PKG. Setting up $REQUIRED_PKG."
  sudo apt-get --yes install $REQUIRED_PKG
fi

# Function to validate the email address using regex
validate_email() {
    local email=$1
    local regex='^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'

    if [[ $email =~ $regex ]]; then
        echo "Valid email address: $email"
        return 0
    else
        echo "Invalid email address: $email"
        return 1
    fi
}

# Function to verify input with the user
verify_input() {

    echo -e "\nYou entered the following:"

    echo "  SAML_ENTITY_ID: $1"
    echo "  SAML_IDP_METADATA_URL: $2"
    echo "  Guacamole IdP Admin: $3"
    
    read -p "Is this correct? (y/n): " choice

    case "$choice" in
        [yY])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}


echo -n "Do you want to integrate Guacamole with an IdP for SAML Authentication ? [y/N]: "
read SAML

if [ "$SAML" = "y" ] ;
then

echo -e "\n- Deploying Gyacamole with IdP Integration !"
echo -e "\n- Setting up SAML initial Administrator User -"
# Capture administrative account to setup guacamole
while true; do
    echo -n "Enter admin account [admin@example.onmicrosoft.com]: "
    read GUACADMIN

    if validate_email "$GUACADMIN"; then
        break
    fi
done
echo "done"

echo -e "\n- Configure SAML Attributes -"
# Capture SAML attributes
while true; do
    echo -n "Enter Netskope App URL [example: https://app-8443-tenant.eu.npaproxy.goskope.com]: "
    read SAML_ENTITY_ID
    echo -n "Enter SAML Metadata URL: "
    read SAML_IDP_METADATA_URL

    if verify_input "$SAML_ENTITY_ID" "$SAML_IDP_METADATA_URL" "$GUACADMIN"; then
        break
    fi
done

echo -e "\n- Writing config to .env -"

# Creating .env configuration file
echo PG_PWD=$PWD > .env
echo SAML_ENTITY_ID=$SAML_ENTITY_ID >> .env
echo SAML_IDP_URL=$SAML_IDP_URL >> .env
echo SAML_IDP_METADATA_URL=$SAML_IDP_METADATA_URL >> .env

echo -e "\n- Completed writing config variables to .env"

echo -e "\n- Downloading the Guacd Docker Image and creating the Guacd Docker Container"

docker run --name guacamole-server -d --network host guacamole/guacd

bash -c 'echo -n "Waiting for Guacd on port 4822 .."; for _ in `seq 1 120`; do echo -n .; sleep 1; nc -z localhost 4822 && echo " Open." && exit ; done; echo " Timeout!" >&2; exit 1'

echo -e "\n- Guacd docker container running"

echo -e "\n- Downloading the Guacd Docker Image, retrieving the MySQL initialization database and configure it"

docker run --rm guacamole/guacamole /opt/guacamole/bin/initdb.sh --mysql > ./01-initdb.sql

# Add guacamole admin account creation script to ./init/initdb.sql
    cat << EOF >> "./01-initdb.sql"

-- Create IdP user with administrative privileges
INSERT INTO guacamole_entity (name, type) VALUES ('$GUACADMIN', 'USER');
INSERT INTO guacamole_user (entity_id, password_hash, password_salt, password_date)
SELECT
    entity_id,
    x'CA458A7D494E3BE824F5E1E175A1556C0F8EEF2C2D7DF3633BEC4A29C4411960',  -- 'guacadmin'
    x'FE24ADC5E11E2B25288D1704ABE67A79E342ECC26064CE69C5B3177795A82264',
    NOW()
FROM guacamole_entity WHERE name = '$GUACADMIN';

-- Grant this user all system permissions
INSERT INTO guacamole_system_permission (entity_id, permission)
SELECT entity_id, permission
FROM (
          SELECT '$GUACADMIN'  AS username, 'CREATE_CONNECTION'       AS permission
    UNION SELECT '$GUACADMIN'  AS username, 'CREATE_CONNECTION_GROUP' AS permission
    UNION SELECT '$GUACADMIN'  AS username, 'CREATE_SHARING_PROFILE'  AS permission
    UNION SELECT '$GUACADMIN'  AS username, 'CREATE_USER'             AS permission
    UNION SELECT '$GUACADMIN'  AS username, 'CREATE_USER_GROUP'       AS permission
    UNION SELECT '$GUACADMIN'  AS username, 'ADMINISTER'              AS permission
) permissions
JOIN guacamole_entity ON permissions.username = guacamole_entity.name AND guacamole_entity.type = 'USER';

-- Grant admin permission to read/update/administer self
INSERT INTO guacamole_user_permission (entity_id, affected_user_id, permission)
SELECT guacamole_entity.entity_id, guacamole_user.user_id, permission
FROM (
          SELECT '$GUACADMIN' AS username, '$GUACADMIN' AS affected_username, 'READ'       AS permission
    UNION SELECT '$GUACADMIN' AS username, '$GUACADMIN' AS affected_username, 'UPDATE'     AS permission
    UNION SELECT '$GUACADMIN' AS username, '$GUACADMIN' AS affected_username, 'ADMINISTER' AS permission
) permissions
JOIN guacamole_entity          ON permissions.username = guacamole_entity.name AND guacamole_entity.type = 'USER'
JOIN guacamole_entity affected ON permissions.affected_username = affected.name AND guacamole_entity.type = 'USER'
JOIN guacamole_user            ON guacamole_user.entity_id = affected.entity_id;

EOF

echo -e "\n- Launching MySQL Container"

docker run --name guacamoledb -e MYSQL_ROOT_PASSWORD='Gh.4@GMks8R.' -e MYSQL_USER=guacadmin -e MYSQL_PASSWORD='w9xHA@+V#!3M' -e MYSQL_DATABASE=guacdb -d --network host mysql/mysql-server

bash -c 'echo -n "Waiting for MySQL on port 3306 .."; for _ in `seq 1 120`; do echo -n .; sleep 1; nc -z localhost 3306 && echo " Open." && exit ; done; echo " Timeout!" >&2; exit 1'

echo -e "\n- MySQL launched"

echo -e "\n- Initialising MySQL Database for Guacamole"

docker exec -i guacamoledb sh -c 'exec mysql -u root -p"Gh.4@GMks8R." guacdb' < ./01-initdb.sql

echo -e "\n- Launching Guacamole Docker Container"

docker run --name guacamole-client -e GUACD_HOSTNAME=127.0.0.1 -e GUACD_PORT=4822 -e MYSQL_HOSTNAME=127.0.0.1  -e MYSQL_DATABASE=guacdb -e MYSQL_USER=guacadmin -e MYSQL_PASSWORD='w9xHA@+V#!3M' -d --network host guacamole/guacamole

bash -c 'echo -n "Waiting for Guacamole on port 8080 .."; for _ in `seq 1 120`; do echo -n .; sleep 1; nc -z localhost 8080 && echo " Open." && exit ; done; echo " Timeout!" >&2; exit 1'

echo -e "\n- Guacamole Container launched"

echo -e "\n- Configuring Guacamole container for IdP integration"
docker cp guacamole-client:/opt/guacamole/bin/start.sh .
sed -ie '/^GUACAMOLE_PROPERTIES/a SAML_IDP_METADATA_URL="'$SAML_IDP_METADATA_URL'"' ./start.sh
sed -ie '/^GUACAMOLE_PROPERTIES/a SAML_ENTITY_ID="'$SAML_ENTITY_ID'"' ./start.sh
sed -ie '/^GUACAMOLE_PROPERTIES/a SAML_CALLBACK_URL="'$SAML_ENTITY_ID'"' ./start.sh
sed -ie '/^GUACAMOLE_PROPERTIES/a EXTENSION_PRIORITY="saml"' ./start.sh
sed -ie '/^GUACAMOLE_PROPERTIES/a SAML_STRICT="false"' ./start.sh
sed -i 's/WEBAPP_CONTEXT:-guacamole/WEBAPP_CONTEXT:-ROOT/' ./start.sh
docker cp ./start.sh guacamole-client:/opt/guacamole/bin/start.sh
docker exec guacamole-client rm -rf /home/guacamole/tomcat/webapps/guacamole.war

echo -e "\n- Restaring Guacamole container"
docker restart guacamole-client
echo -e "\n- Guacamole container restarted"

bash -c 'echo -n "Waiting for Guacamole on port 8080 .."; for _ in `seq 1 120`; do echo -n .; sleep 1; nc -z localhost 8080 && echo " Open." && exit ; done; echo " Timeout!" >&2; exit 1'

# Deleting the old guacamole webapp folder
docker exec guacamole-client rm -rf /home/guacamole/tomcat/webapps/guacamole

# Making the guacamole containers auto-restarting
docker update --restart unless-stopped guacamoledb > /dev/null
docker update --restart unless-stopped guacamole-server > /dev/null
docker update --restart unless-stopped guacamole-client > /dev/null

echo -e "\n- Installation of Guacamole Completed !"

else
echo -e "\n- Deploying Gyacamole without IdP Integration !"
echo -e "\n- Downloading the Guacd Docker Image and creating the Guacd Docker Container"

docker run --name guacamole-server -d --network host guacamole/guacd

bash -c 'echo -n "Waiting for Guacd on port 4822 .."; for _ in `seq 1 120`; do echo -n .; sleep 1; nc -z localhost 4822 && echo " Open." && exit ; done; echo " Timeout!" >&2; exit 1'

echo -e "\n- Guacd docker container running"

echo -e "\n- Downloading the Guacd Docker Image, retrieving the MySQL initialization database and configure it"

docker run --rm guacamole/guacamole /opt/guacamole/bin/initdb.sh --mysql > ./01-initdb.sql

echo -e "\n- Launching MySQL Container"

docker run --name guacamoledb -e MYSQL_ROOT_PASSWORD='Gh.4@GMks8R.' -e MYSQL_USER=guacadmin -e MYSQL_PASSWORD='w9xHA@+V#!3M' -e MYSQL_DATABASE=guacdb -d --network host mysql/mysql-server

bash -c 'echo -n "Waiting for MySQL on port 3306 .."; for _ in `seq 1 120`; do echo -n .; sleep 1; nc -z localhost 3306 && echo " Open." && exit ; done; echo " Timeout!" >&2; exit 1'

echo -e "\n- MySQL launched"

echo -e "\n- Initialising MySQL Database for Guacamole"

docker exec -i guacamoledb sh -c 'exec mysql -u root -p"Gh.4@GMks8R." guacdb' < ./01-initdb.sql

echo -e "\n- Launching Guacamole Docker Container"

docker run --name guacamole-client -e GUACD_HOSTNAME=127.0.0.1 -e GUACD_PORT=4822 -e MYSQL_HOSTNAME=127.0.0.1  -e MYSQL_DATABASE=guacdb -e MYSQL_USER=guacadmin -e MYSQL_PASSWORD='w9xHA@+V#!3M' -d --network host guacamole/guacamole

bash -c 'echo -n "Waiting for Guacamole on port 8080 .."; for _ in `seq 1 120`; do echo -n .; sleep 1; nc -z localhost 8080 && echo " Open." && exit ; done; echo " Timeout!" >&2; exit 1'

echo -e "\n- Guacamole Container launched"

echo -e "\n- Configuring Guacamole container"
docker cp guacamole-client:/opt/guacamole/bin/start.sh .
sed -i 's/WEBAPP_CONTEXT:-guacamole/WEBAPP_CONTEXT:-ROOT/' ./start.sh
docker cp ./start.sh guacamole-client:/opt/guacamole/bin/start.sh
docker exec guacamole-client rm -rf /home/guacamole/tomcat/webapps/guacamole.war

echo -e "\n- Restaring Guacamole container"
docker restart guacamole-client
echo -e "\n- Guacamole container restarted"

bash -c 'echo -n "Waiting for Guacamole on port 8080 .."; for _ in `seq 1 120`; do echo -n .; sleep 1; nc -z localhost 8080 && echo " Open." && exit ; done; echo " Timeout!" >&2; exit 1'

# Deleting the old guacamole webapp folder
docker exec guacamole-client rm -rf /home/guacamole/tomcat/webapps/guacamole

# Making the guacamole containers auto-restarting
docker update --restart unless-stopped guacamoledb > /dev/null
docker update --restart unless-stopped guacamole-server > /dev/null
docker update --restart unless-stopped guacamole-client > /dev/null

echo -e "\n- Installation of Guacamole Completed !"
fi
