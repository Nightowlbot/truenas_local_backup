#!/usr/bin/env bash
set -o pipefail # Pipe commands fail if any command in the pipe fails
set -o errtrace # Enable ERR trap for functions, command substitutions, and subshells
# Set generic trap to catch errors
trap 'echo "ERROR: Script failed unexpectedly. Do all dependencies exist? Does config.sh exist?" >&2; exit 1' ERR

###############################################################################
# ZFS Backup Script for TrueNAS SCALE
#
# Automated ZFS backup solution that detects external drives by serial number
# and performs incremental backups with comprehensive safety features.
#
# For detailed documentation, see README.md
###############################################################################


###############################################################################
# Global Variables and Constants
###############################################################################
# Default value, in case config.sh is not found.
# Only change in config.sh
LOG_APPEND=false

# Color Configuration
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# Get the real directory where the script is located (resolving symlinks)
# First get the path to the script itself, resolving all symlinks
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || readlink "$0" 2>/dev/null || echo "$0")
# Then get the directory containing the resolved script
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
# Make sure SCRIPT_DIR is absolute
if [[ ! "$SCRIPT_DIR" = /* ]]; then
    SCRIPT_DIR="$(pwd)/$SCRIPT_DIR"
fi
LOG_FILE="${SCRIPT_DIR}/backup.log"

# Define all required dependencies
DEPENDENCIES=("zpool" "zfs" "grep" "awk" "date" "read" "midclt" "jq" "sed" "xargs" "tee" "flock" "tmux" "readlink" "python3")

###############################################################################
# source config and modules
###############################################################################
# Make sure these files exist! No logging initialized at this point, so no error logging yet
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/modules/logging.sh"
source "$SCRIPT_DIR/modules/helpers.sh"
source "$SCRIPT_DIR/modules/zfs_pools.sh"

# Set up the specific error trap
trap 'error_trap ${LINENO}' ERR

# Validate configuration arrays
validate_config() {
    # Check that all arrays are defined
    if [[ -z "${BACKUP_SERIALS[*]}" ]]; then
        error_exit "BACKUP_SERIALS array is empty or not defined in config.sh"
    fi
    
    if [[ -z "${BACKUP_ZFS_GROUPS[*]}" ]]; then
        error_exit "BACKUP_ZFS_GROUPS array is empty or not defined in config.sh"
    fi
    
    if [[ -z "${BACKUP_DST_POOLS[*]}" ]]; then
        error_exit "BACKUP_DST_POOLS array is empty or not defined in config.sh"
    fi
    
    # BACKUP_DOCKER_CONTAINERS array must be defined
    if [[ ! -v BACKUP_DOCKER_CONTAINERS ]]; then
        error_exit "BACKUP_DOCKER_CONTAINERS array is not defined in config.sh"
    fi
    
    # Check that all arrays have the same length
    local serials_count=${#BACKUP_SERIALS[@]}
    local groups_count=${#BACKUP_ZFS_GROUPS[@]}
    local pools_count=${#BACKUP_DST_POOLS[@]}
    local containers_count=${#BACKUP_DOCKER_CONTAINERS[@]}
    
    if [[ $serials_count -ne $groups_count ]] || [[ $serials_count -ne $pools_count ]] || [[ $serials_count -ne $containers_count ]]; then
        error_exit "Configuration arrays must have the same number of elements: BACKUP_SERIALS($serials_count), BACKUP_ZFS_GROUPS($groups_count), BACKUP_DST_POOLS($pools_count), BACKUP_DOCKER_CONTAINERS($containers_count)"
    fi
    
    # Validate required variables
    local required_vars=("SCRUB_INTERVAL_DAYS" "ENABLE_SCRUB" "KEEP_COUNT" "DISK_BY_ID_PATH" "EMAIL_ENABLED" "ALLOW_AUTOSTART" "LOG_APPEND")
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            error_exit "Required configuration variable '$var' is not set in config.sh"
        fi
    done
}

###############################################################################
# Main Function - Executes All Steps in Order
###############################################################################
main() {

    # Check if script is run with sudo privileges
    check_sudo
    
    # Initialize log file
    initialize_logging
    
    # Check cofig file
    validate_config
    
    # Check for dependencies
    check_dependencies
    
    # Verify tmux session (if enabled)
    check_tmux_session "$@"
    
    # Set up lock file to prevent concurrent execution
    setup_lock_file
    
    # Detect and configure backup disk
    detect_and_configure_backup_disk
    
    # Send email notification about backup start
    send_start_notification

    # Import backup pool (if not already imported)
    import_backup_pool
    
    # Check backup pool health status
    check_backup_pool_status

    # Perform scrub if needed
    run_scrub
    
    # Run ZFS autobackup to sync data
    run_zfs_autobackup
    
    # Export backup pool via middleware
    export_backup_pool
    
    # Final success message
    log "${GREEN}Backup from $zfs_group_name to $DST_POOL completed successfully.${NC}"

    # Send email message
    send_completion_notification
    
    # Ask about tmux session cleanup
    cleanup_tmux_session "$@"
    
    return 0
}

###############################################################################
# Run the Main Function
###############################################################################
# Call the main function and exit with its return code
if ! main; then
    exit_code=$?
    echo "Script exited with errors. Check the log file for details."
    exit $exit_code
fi
exit 0
