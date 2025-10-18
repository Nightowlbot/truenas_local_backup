#!/usr/bin/env bash
set -e

###############################################################################
# TrueNAS SCALE backup wrapper script
# This script checks if the inserted disk's serial number matches any configured
# serial in the config.sh file before executing the main backup script
###############################################################################

# Get the real directory where the script is located (resolving symlinks)
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || readlink "$0" 2>/dev/null || echo "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
# Make sure SCRIPT_DIR is absolute
if [[ ! "$SCRIPT_DIR" = /* ]]; then
    SCRIPT_DIR="$(pwd)/$SCRIPT_DIR"
fi

# Backup script path
BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"

# Log file path - will be overwritten each time
LOG_FILE="${SCRIPT_DIR}/backup_wrapper.log"

# Path where udev provides stable device links by ID (serial, WWN, etc.)
DISK_BY_ID_PATH="/dev/disk/by-id"

# Initialize log file (overwrite)
> "$LOG_FILE"

# Function to log messages to file
log() {
    local timestamp
    timestamp=$(date '+%F %T')
    echo "$timestamp [INFO] $1" >> "$LOG_FILE"
}

# Log errors to file
log_error() {
    local timestamp
    timestamp=$(date '+%F %T')
    echo "$timestamp [ERROR] $1" >> "$LOG_FILE"
}

# Add a delay, if backup drive is already inserted at startup, to ensure truenas services are ready
log "Backup wrapper started. Waiting 30 seconds for system readiness..."
sleep 30

log "Checking for valid backup drives"

# Check if backup script exists
if [ ! -f "$BACKUP_SCRIPT" ]; then
    log_error "Backup script not found at $BACKUP_SCRIPT"
    exit 1
fi

# Check if config file exists
config_file="$SCRIPT_DIR/config.sh"
if [ ! -f "$config_file" ]; then
    log_error "Configuration file (config.sh) not found in $SCRIPT_DIR"
    exit 1
fi

# Source the configuration file
log "Reading configuration from config.sh"
source "$config_file"

# Validate that required arrays are loaded
if [[ -z "${BACKUP_SERIALS[*]}" ]]; then
    log_error "BACKUP_SERIALS array is empty or not defined in config.sh"
    exit 1
fi

# Check if automatic backup is allowed
if [[ "${ALLOW_AUTOSTART,,}" != "true" ]]; then
    log "Automatic backup is disabled (ALLOW_AUTOSTART=${ALLOW_AUTOSTART}). Skipping backup execution."
    exit 0
fi

log "Automatic backup is enabled - proceeding with disk detection"
log "Found ${#BACKUP_SERIALS[@]} configured backup disk(s)"

# Function to check for matching disk serial numbers
check_for_backup_disk() {
    log "Checking for disks with matching serial numbers..."
    
    # Get all disk-by-id paths that might contain serial numbers
    if [ ! -d "$DISK_BY_ID_PATH" ]; then
        log_error "Disk-by-id path not found: $DISK_BY_ID_PATH"
        return 1
    fi
    
    local found_match=false
    
    # Loop through all disks in the by-id directory
    for disk_path in "$DISK_BY_ID_PATH"/ata-*; do
        # Skip if not a file
        [ -L "$disk_path" ] || continue
        
        # Extract serial from the path
        local disk_serial
        disk_serial=$(basename "$disk_path" | sed -n 's/^ata-.*_\(.*\)$/\1/p')
        
        # Skip if no serial found
        if [ -z "$disk_serial" ]; then
            continue
        fi
        
        log "Found disk with serial: $disk_serial"
        
        # Check if this serial is in our BACKUP_SERIALS array
        for serial in "${BACKUP_SERIALS[@]}"; do
            if [ "$disk_serial" = "$serial" ]; then
                log "Found matching serial: $disk_serial"
                found_match=true
                break
            fi
        done
        
        # If we found a match, no need to continue checking
        $found_match && break
    done
    
    # Return true if we found a matching disk
    $found_match && return 0 || return 1
}

# Check for a matching backup disk
if check_for_backup_disk; then
    log "Matching backup disk found - executing backup script"
    # Execute the backup script with all the original arguments
    log "Running: $BACKUP_SCRIPT auto"
    "$BACKUP_SCRIPT" auto
    exit_code=$?
    log "Backup script completed with exit code: $exit_code"
    exit $exit_code
else
    log "No matching backup disk found - skipping backup"
    exit 0
fi
