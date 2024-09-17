#! /usr/bin/bash

# Install MongoDB on Zone.eu servers automatically.
# 
# Usage:
# 1. Copy the script (.mongo-magic.sh) into your HOME directory (e.g., /data01/virt12345/).
# 2. Run the script from the terminal using: "bash .mongo-magic.sh".
#
# Download Instructions:
# You can download this script directly from GitHub using:
# - wget: wget https://raw.githubusercontent.com/raidokulla/mongo-magic/master/.mongo-magic.sh
# - curl: curl -O https://raw.githubusercontent.com/raidokulla/mongo-magic/master/.mongo-magic.sh
#
# Features:
# - Checks for an existing MongoDB instance and prevents conflicts.
# - Offers to back up the current database before installation.
# - Allows the user to choose between MongoDB versions 6.0 and 7.0.
# - Lets the user select the memory allocation for MongoDB from predefined options (256M, 512M, 1G, 2G, 3G).
# - Enables the user to specify a custom PM2 app name.
# - Automatically checks for compatible MongoDB tools and installs them.
# - Prompts for the creation of a new user with root access and an optional additional user with read/write permissions.
#
# Author: Raido K @ Vellex Digital
# GitHub: https://github.com/raidokulla


# GET LOOPBACK IP
LOOPBACK=$(vs-loopback-ip -4)
MONGODB_DIR="$HOME/mongodb"

# Check if MongoDB is running
if pgrep -x "mongod" > /dev/null; then
    echo "MongoDB is currently running. Exiting script to avoid conflicts."
    exit 1
fi

# Check if a MongoDB directory exists
if [ -d "$MONGODB_DIR/db" ]; then
    echo "Existing MongoDB database found."
    read -p "Do you want to back it up before overwriting? (y/n): " backup_choice

    if [[ "$backup_choice" == "y" ]]; then
        echo "Backing up existing MongoDB database..."
        tar -czvf "$HOME/mongodb_backup_$(date +%Y%m%d_%H%M%S).tar.gz" "$MONGODB_DIR/db"
        echo "Backup completed."
    fi

    echo "Overwriting existing MongoDB database..."
    rm -rf "$MONGODB_DIR/db/*"  # Clear existing database files
fi

# Ask user which MongoDB version to install
echo "Select MongoDB version to install:"
echo "1) 6.0"
echo "2) 7.0"
read -p "Enter choice (1 or 2): " version_choice

case $version_choice in
    1) MONGO_VERSION="mongodb-linux-x86_64-rhel80-6.0.0.tgz";;
    2) MONGO_VERSION="mongodb-linux-x86_64-rhel80-7.0.0.tgz";;
    *) echo "Invalid choice. Exiting."; exit 1;;
esac

# CREATE REQUIRED DIRS
mkdir -p "$MONGODB_DIR/log" "$MONGODB_DIR/run" "$MONGODB_DIR/db"

# Change to MongoDB directory
cd "$MONGODB_DIR" || { echo "Failed to change directory!"; exit 1; }

# GET MONGODB
wget "https://fastdl.mongodb.org/linux/$MONGO_VERSION" || { echo "Download failed!"; exit 1; }
tar -zxvf "$MONGO_VERSION" -C "$MONGODB_DIR"  # Extract directly to the MongoDB directory
ln -s "$MONGODB_DIR/mongodb-linux-x86_64-rhel80-${version_choice}.0.0" "$MONGODB_DIR/mongodb-binary"

# GET MONGOSH
wget https://downloads.mongodb.com/compass/mongosh-1.5.2-linux-x64.tgz -O mongosh.tgz || { echo "Download failed!"; exit 1; }
tar -zxvf mongosh.tgz
echo 'export PATH=$PATH:$HOME/mongodb/mongosh-1.5.2-linux-x64/bin' >> "$HOME/.bash_profile"
source "$HOME/.bash_profile"

# CHECK FOR TOOLS UPDATES
echo "Checking for MongoDB tools updates..."
TOOL_VERSION="mongodb-database-tools-rhel80-x86_64-100.5.4.tgz"
wget "https://fastdl.mongodb.org/tools/db/$TOOL_VERSION" -O tools.tgz || { echo "Download failed!"; exit 1; }
tar -zxvf tools.tgz
echo 'export PATH=$PATH:$HOME/mongodb/mongodb-database-tools-rhel80-x86_64-100.5.4/bin' >> "$HOME/.bash_profile"
source "$HOME/.bash_profile"

# CREATE MONGO.CFG
cat > "$MONGODB_DIR/mongo.cfg" << ENDOFFILE
processManagement:
    fork: false
    pidFilePath: "$MONGODB_DIR/run/mongodb-5679.pid"
net:
    bindIp: $LOOPBACK
    port: 5679
    unixDomainSocket:
        enabled: false
systemLog:
    verbosity: 0
    quiet: true
    destination: file
    path: "$MONGODB_DIR/log/mongodb.log"
    logRotate: reopen
    logAppend: true
storage:
    dbPath: "$MONGODB_DIR/db/"
    journal:
        enabled: true
    directoryPerDB: true
    engine: wiredTiger
    wiredTiger:
        engineConfig:
            journalCompressor: snappy
            cacheSizeGB: 1
        collectionConfig:
            blockCompressor: snappy
ENDOFFILE

echo "Mongo CFG created."

# Ask user for memory limit
echo "Select memory limit for MongoDB:"
echo "1) 256M"
echo "2) 512M"
echo "3) 1G"
echo "4) 2G"
echo "5) 3G"
read -p "Enter choice (1-5): " memory_choice

case $memory_choice in
    1) MEMORY="256M";;
    2) MEMORY="512M";;
    3) MEMORY="1G";;
    4) MEMORY="2G";;
    5) MEMORY="3G";;
    *) echo "Invalid choice. Exiting."; exit 1;;
esac

# Ask user for PM2 app name
read -p "Enter a name for the PM2 app: " pm2_app_name

# CREATE JSON FOR PM2
cat > "$MONGODB_DIR/${pm2_app_name}.pm2.json" << ENDOFFILE
{
  "apps": [{
    "name": "$pm2_app_name",
    "script": "$MONGODB_DIR/mongodb-binary/bin/mongod",
    "args": "--config $MONGODB_DIR/mongo.cfg --auth",
    "cwd": "$MONGODB_DIR",
    "max_memory_restart": "$MEMORY"
  }]
}
ENDOFFILE

echo "MongoDB PM2 JSON created."

# START MONGODB FIRST TIME
echo "Starting MongoDB..."
pm2 start "$MONGODB_DIR/${pm2_app_name}.pm2.json" || { echo "Failed to start MongoDB!"; exit 1; }
echo "MongoDB started successfully."

# CREATE ADMIN DB USER
echo "Creating new root user."
read -p "Enter new username: " username
read -sp "Enter new password: " password
echo

./mongodb-binary/bin/mongod -f "$MONGODB_DIR/mongo.cfg" --fork

mongosh $USER.loopback.zonevs.eu:5679/admin --eval "db.createUser({
    user: \"$username\",
    pwd: \"$password\",
    roles: [{ role: \"root\", db: \"admin\" }]
})"

# WARNING ABOUT CREATING A NEW USER
echo "WARNING: It is recommended to create a new user with read/write permissions."
read -p "Do you want to create a new user with limited permissions? (y/n): " create_user

if [[ "$create_user" == "y" ]]; then
    read -p "Enter new username for limited access: " new_username
    read -sp "Enter password for new user: " new_password
    echo
    mongosh $USER.loopback.zonevs.eu:5679/admin --eval "db.createUser({
        user: \"$new_username\",
        pwd: \"$new_password\",
        roles: [{ role: \"readWrite\", db: \"my-database\" }]
    })"
    echo "New user created with read/write permissions."
fi

# CLOSE MONGO
echo "Shutting down MongoDB..."
./mongodb-binary/bin/mongod -f "$MONGODB_DIR/mongo.cfg" --shutdown

# DO NEXT COMMENTS
echo "Setup MongoDB as new PM2 app at Zone."
echo "Virtuaalserverid -> Veebiserver -> PM2 protsessid (Node.js)"
echo "Path for app: $MONGODB_DIR/${pm2_app_name}.pm2.json"