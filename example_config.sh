#!/usr/bin/env bash

###############################################################################
# ZFS Backup Script Configuration
# This file contains all configuration variables for the backup script
###############################################################################

# Backup Configurations
# Each array index corresponds to the same backup configuration

# Disk serial numbers for each backup configuration
# The serial is the actual disk serial as detected by the system. It can be found in the TrueNAS WebUI
BACKUP_SERIALS=(
    "AB7563DEF"         # Config 1
    "CD34895FEYZ"       # Config 2
)

# ZFS group names (without "zfs_autobackup:" prefix)
BACKUP_ZFS_GROUPS=(
    "offsite1"          # Config 1
    "offsite2"          # Config 2
)

# Destination pool names
BACKUP_DST_POOLS=(
    "offsite_backup_1"  # Config 1
    "offsite_backup_2"  # Config 2
)

# Docker service management for backup
# Set to true to stop Docker service before snapshot creation and restart after
# Set to false to leave Docker service running during backup
BACKUP_DOCKER_CONTAINERS=(
    true                # Config 1 - stop Docker service for this backup
    false               # Config 2 - leave Docker service running
)


# Scrub Configuration
# Number of days after which to scrub again
#   0 = always scrub if *any* snapshot exists
#  >0 = scrub only when the last scrub is older than this many days
#       (falls back to snapshot age if scrub history is unavailable)
SCRUB_INTERVAL_DAYS=14

# Master switch: if false, *no* scrub will ever be executed
# If there are no snapshots on the destination pool, no scrub will be performed
ENABLE_SCRUB=true

# Email Notification Configuration
# Set to true to enable email notifications when backup starts and completes
EMAIL_ENABLED=true
# Email address to receive notifications
EMAIL_ADDRESS="admin@example.com"
# Prefix for email subject lines
EMAIL_SUBJECT_PREFIX="[ZFS Backup]"

# Snapshot Retention
# Define how many snapshots matching the prefix pattern to keep per dataset
# Set KEEP_COUNT=0 to delete all but the one just created (if applicable)
# Set KEEP_COUNT=1 to keep only the latest one (created in this run)
# Set KEEP_COUNT=2 to keep the latest two, etc.
KEEP_COUNT=1

# Automatic Backup Control
# Set to true to allow automatic backup execution when a configured drive is detected
# Note: this still requires some manual setup. See readme.md for details.
# Set to false to disable automatic backups, if they were set up previously (manual execution only. Useful for testing)
ALLOW_AUTOSTART=true

# Logging Configuration
# Set to true to append to existing log file, false to overwrite it on each run
LOG_APPEND=false

# System Paths
# Path where udev provides stable device links by ID (serial, WWN, etc.)
# Usually does not need to be changed
DISK_BY_ID_PATH="/dev/disk/by-id"