###############################################################################
# Check if script is run with sudo/root privileges
###############################################################################
check_sudo() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script must be run with sudo privileges."
        echo "Restarting with sudo..."
        exec sudo "$0" "$@"
        exit $?
    fi
}

###############################################################################
# Set up Lock File to Prevent Concurrent Runs
###############################################################################
setup_lock_file() {
    local LOCKFILE="/var/run/${0##*/}.lock"
    exec 200>"$LOCKFILE" || error_exit "Cannot open lockfile"
    flock -n 200 || error_exit "Another backup is running."
    trap 'error_exit "Interrupted."' INT TERM
    
    # Return success
    return 0
}

###############################################################################
# Function to check dependencies
###############################################################################
check_dependencies() {
  local missing=()
  
  for cmd in "${DEPENDENCIES[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  
  if [ ${#missing[@]} -gt 0 ]; then
    error_exit "Missing required dependencies: ${missing[*]} Please install the missing dependencies and try again."
  fi
}

###############################################################################
# Check if script is running in tmux session
###############################################################################
check_tmux_session() {
    # Check if auto mode is requested (for automated execution)
    for arg in "$@"; do
        if [ "$arg" = "auto" ]; then
            log "Running in automatic mode, skipping tmux session check"
            return
        fi
    done

    # Check if TMUX environment variable is set (script is running inside tmux)
    if [ -z "$TMUX" ]; then
        echo -e "${YELLOW}WARNING: This script is not running inside a tmux session.${NC}"
        echo "Running in tmux is recommended to prevent interruption if your SSH connection drops."
        echo ""
        read -p "Would you like to restart this script in a tmux session? (y/n): " tmux_choice
        
        case "$tmux_choice" in
            [Yy]*)
                # Check if tmux is installed
                if ! command -v tmux >/dev/null 2>&1; then
                    echo -e "${YELLOW}tmux is not installed. Installing it is recommended.${NC}"
                    echo ""
                    read -p "Continue without tmux? (y/n): " continue_choice
                    case "$continue_choice" in
                        [Yy]*) return ;; # Continue without tmux
                        *) exit 0 ;; # Exit script
                    esac
                else
                    # tmux is available, show instructions and restart in tmux
                    echo -e "${GREEN}=== TMUX USAGE INSTRUCTIONS ===${NC}"
                    echo "- Script will now restart inside a tmux session named 'backup'"
                    echo -e "- To detach from tmux without stopping the script: Press ${YELLOW}Ctrl+B${NC} then ${YELLOW}d${NC}"
                    echo -e "- To reattach later: ${YELLOW}tmux attach -t backup${NC}"
                    echo "- Detailed tmux guide is available in backupscriptreadme.txt"
                    echo ""
                    read -p "Press Enter to continue..."
                    
                    # Check if session already exists
                    if tmux has-session -t backup 2>/dev/null; then
                        echo -e "${YELLOW}A tmux session named 'backup' already exists.${NC}"
                        echo "1) Attach to existing session"
                        echo "2) Create a new unique session"
                        echo "3) Exit"
                        read -p "Choose an option (1-3): " tmux_option
                        case "$tmux_option" in
                            1) exec tmux attach -t backup ;;
                            2)
                                COUNTER=1
                                while tmux has-session -t "backup_$COUNTER" 2>/dev/null; do
                                    ((COUNTER++))
                                done
                                SESSION_NAME="backup_$COUNTER"
                                echo "Starting new session: $SESSION_NAME"
                                tmux new-session -d -s "$SESSION_NAME" "bash -i -c '$0 "$@"; EXITCODE=\$?; echo; echo \"Script exited with status \$EXITCODE. Press Enter to close this session...\"; read'"
                                exec tmux attach -t "$SESSION_NAME"
                                ;;
                            *) exit 0 ;;
                        esac
                    else
                        # No existing session, create new one
                        tmux new-session -d -s backup "bash -i -c '$0 "$@"; EXITCODE=\$?; echo; echo \"Script exited with status \$EXITCODE. Press Enter to close this session...\"; read'"
                        exec tmux attach -t backup
                    fi
                    exit 0
                fi
                ;;
            *)
                echo "Continuing without tmux. Be aware that if your SSH connection drops, the backup process will be interrupted."
                return
                ;;
        esac
    fi
}


###############################################################################
# Detect and Configure Backup Disk
###############################################################################
detect_and_configure_backup_disk() {
    local found_serial=""
    local found_count=0
    
    log "Searching for backup disks in $DISK_BY_ID_PATH..."
    
    # Loop through all disk IDs
    for disk_path in "$DISK_BY_ID_PATH"/ata-*; do
        # Skip if not a valid path
        [ -e "$disk_path" ] || continue
        
        # Extract serial from the path
        local disk_serial
        disk_serial=$(basename "$disk_path" | sed -n 's/^ata-.*_\(.*\)$/\1/p')
        
        # Skip if no serial found
        if [ -z "$disk_serial" ]; then
            continue
        fi
        
        # Check if this serial is in our BACKUP_SERIALS array
        for i in "${!BACKUP_SERIALS[@]}"; do
            if [[ "${BACKUP_SERIALS[i]}" == "$disk_serial" ]]; then
                log "Found matching configuration for serial: '$disk_serial'"
                found_serial="$disk_serial"
                ((found_count++))
                break
            fi
        done
    done
    
    # Error if no configured disk found
    if [ -z "$found_serial" ]; then
        error_exit "No configured backup disk found. Check connections and configuration."
    fi
    
    # Error if multiple configured disks found
    if [ "$found_count" -gt 1 ]; then
        error_exit "Multiple configured backup disks found. Please connect only one backup disk."
    fi
    
    log "Detected backup disk serial: $found_serial"

    # Find configuration for the current backup disk
    local config_found=false
    for i in "${!BACKUP_SERIALS[@]}"; do
        if [[ "${BACKUP_SERIALS[i]}" == "$found_serial" ]]; then
            # Found a match, get the corresponding configuration
            zfs_group_name="${BACKUP_ZFS_GROUPS[i]}"
            DST_POOL="${BACKUP_DST_POOLS[i]}"
            DOCKER_CONTAINERS="${BACKUP_DOCKER_CONTAINERS[i]}"
            
            log "Using configuration: zfs_group_name='$zfs_group_name', DST_POOL='$DST_POOL'"
            if [[ "$DOCKER_CONTAINERS" == "true" ]]; then
                log "Docker service will be stopped during snapshot creation"
            else
                log "Docker service will remain running during backup"
            fi
            
            # Export these values as global variables
            export BACKUP_DISK_SERIAL="$found_serial"
            export zfs_group_name DST_POOL DOCKER_CONTAINERS
            
            config_found=true
            break
        fi
    done
    
    if [[ "$config_found" != "true" ]]; then
        error_exit "No configuration found for backup disk serial: $found_serial"
    fi
    
    return 0
}

###############################################################################
# Tmux Session Cleanup
###############################################################################
cleanup_tmux_session() {
    # Check if we're running in auto mode and skip cleanup
    for arg in "$@"; do
        if [ "$arg" = "auto" ]; then
            log "Running in automatic mode, skipping tmux session cleanup"
            return
        fi
    done
    
    # Only ask about tmux session if we're actually in one
    if [ -n "$TMUX" ]; then
        # Get the current session name
        TMUX_SESSION_NAME=$(tmux display-message -p '#S')
        echo
        echo -e "${YELLOW}You are currently in tmux session: ${GREEN}$TMUX_SESSION_NAME${NC}"
        echo -e "What would you like to do with this tmux session?"
        echo "1) Detach from the session (keeps it running in the background)"
        echo "2) Kill the session and exit"
        echo "3) Do nothing (stay in the session)"
        read -p "Enter your choice (1-3): " tmux_choice
        
        case "$tmux_choice" in
            1)
                echo -e "${GREEN}Detaching from tmux session '$TMUX_SESSION_NAME'...${NC}"
                echo -e "You can reattach later with: ${YELLOW}tmux attach -t $TMUX_SESSION_NAME${NC}"
                # Use tmux detach command to detach from the session
                tmux detach
                ;;
            2)
                echo -e "${YELLOW}Killing tmux session '$TMUX_SESSION_NAME' and exiting...${NC}"
                # Use tmux kill-session to kill the current session
                tmux kill-session -t "$TMUX_SESSION_NAME"
                ;;
            *)
                echo -e "${GREEN}Remaining in tmux session '$TMUX_SESSION_NAME'.${NC}"
                echo -e "You can detach at any time by pressing ${YELLOW}Ctrl+B${NC} then ${YELLOW}d${NC}"
                ;;
        esac
    fi
}