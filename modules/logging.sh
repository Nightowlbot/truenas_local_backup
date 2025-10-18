###############################################################################
# Logging and Error Handling
###############################################################################


# Trap handler and stack trace variables
declare stack_trace
declare -i last_error_lineno=0
declare last_error_func=""


log() {
  ts="$(date '+%F %T')"
  # Log to console with color (to stderr so it doesn't interfere with function output)
  echo -e "${ts} ${GREEN}[INFO]${NC}  $1" >&2
  # Log to file (always append at this point because file is already initialized)
  echo "${ts} [INFO]  $1" >> "$LOG_FILE"
}

initialize_logging() {
    # Handle log file based on LOG_APPEND setting - convert the string to lowercase for comparison
    if [[ "${LOG_APPEND,,}" == "true" ]]; then
        # Append mode - just ensure the file is writable or can be created
        touch "$LOG_FILE" || { echo "ERROR: Cannot create or write to log file '$LOG_FILE'. Check permissions. Exiting." >&2; exit 1; }
        # Add a separator for this run
        echo -e "\n\n================================================================================" >> "$LOG_FILE"
        echo "================================================================================" >> "$LOG_FILE"
    else
        # Overwrite mode - create a new file (or truncate existing)
        > "$LOG_FILE" || { echo "ERROR: Cannot create or write to log file '$LOG_FILE'. Check permissions. Exiting." >&2; exit 1; }
    fi

    # Initialize log with start message
    log "Backup script started. Log file: $LOG_FILE"
    log "Script path: $SCRIPT_PATH"
    echo "================================================================================" >> "$LOG_FILE"
    echo "================================================================================" >> "$LOG_FILE"
}

# Print a stack trace to help debug where errors occurred
print_stack_trace() {
    local i frame=0 FRAMES=${#BASH_SOURCE[@]}
    
    # Output to console with color
    echo -e "\n${RED}Stack trace (most recent call first):${NC}" >&2
    echo "=======================================" >&2
    
    # Output to log file as well
    echo -e "\nStack trace (most recent call first):" >> "$LOG_FILE"
    echo "=======================================" >> "$LOG_FILE"
    
    # Start from 1 to skip print_stack_trace function itself
    for ((i=1; i<FRAMES; i++)); do
        local lineno=${BASH_LINENO[i-1]}
        local src=${BASH_SOURCE[i]:-"unknown"}
        local func=${FUNCNAME[i]:-"main"}
        
        # Skip stack trace functions themselves
        [[ "$func" == "error_trap" || "$func" == "error_exit" ]] && continue
        
        # Output to console with color
        echo -e "${RED}[$frame] $src:$lineno: in function $func()${NC}" >&2
        
        # Log to file as well
        echo "[$frame] $src:$lineno: in function $func()" >> "$LOG_FILE"
        
        # Optionally show context of the code
        if [[ -f "$src" ]]; then
            local start=$((lineno > 2 ? lineno - 2 : 1))
            local end=$((lineno + 2))
            sed -n "${start},${end}p" "$src" | while read -r ctx_line; do
                local ctx_lineno=$((start++))
                if [[ $ctx_lineno == "$lineno" ]]; then
                    # Output to console with color
                    echo -e "${RED}>> $ctx_line${NC}" >&2
                    # Log to file
                    echo ">> $ctx_line" >> "$LOG_FILE"
                else
                    # Output to console
                    echo "   $ctx_line" >&2
                    # Log to file
                    echo "   $ctx_line" >> "$LOG_FILE"
                fi
            done
        fi
        
        ((frame++))
    done
    # Output footer to console
    echo "=======================================" >&2
    echo "" >&2
    
    # Output footer to log file too
    echo "=======================================" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
}

# Error trap
# To catch unexpected errors
error_trap() {
    local exit_code=$?
    last_error_lineno=$1
    last_error_func="${FUNCNAME[1]:-main}"
    
    # Prevent recursive calls
    if [[ "${_in_error_trap:-}" == "true" ]]; then
        exit $exit_code
    fi
    local _in_error_trap=true
    
    # Only store the stack trace if we haven't already
    if [[ -z "$stack_trace" ]]; then
        # Capture the current call stack for later use
        local i frame=0 FRAMES=${#BASH_SOURCE[@]}
        stack_trace=""
        
        for ((i=1; i<FRAMES; i++)); do
            local lineno=${BASH_LINENO[i-1]}
            local src=${BASH_SOURCE[i]:-"unknown"}
            local func=${FUNCNAME[i]:-"main"}
            
            # Skip the error_trap function itself
            [[ "$func" == "error_trap" ]] && continue
            
            stack_trace+="[$frame] $src:$lineno: in function $func()\n"
            ((frame++))
        done
    fi
    
    # Log the error with context
    echo "ERROR: Script failed unexpectedly at line $last_error_lineno in function $last_error_func" >&2
    echo "Exit code: $exit_code" >&2
    
    # Print stack trace
    if [[ -n "$stack_trace" ]]; then
        echo -e "$stack_trace" >&2
    fi
    
    # Actually exit the script
    exit $exit_code
}


# Use for expected errors where we want to exit gracefully and send the log per email
# So do not use this in the email functions themselves
error_exit() {
  ts="$(date '+%F %T')"
  # Log error to stderr with color
  echo -e "${ts} ${RED}[ERROR]${NC} $1" >&2
  # Log error to file (always append at this point because file is already initialized)
  echo "${ts} [ERROR] $1" >> "$LOG_FILE"
  
  # Print stack trace if available
  if [[ -n "$stack_trace" ]]; then
      echo -e "\n${RED}Error occurred in $last_error_func() at line $last_error_lineno${NC}" >&2
      echo -e "$stack_trace" >&2
      echo "Error occurred in $last_error_func() at line $last_error_lineno" >> "$LOG_FILE"
      echo -e "$stack_trace" >> "$LOG_FILE"
  else
      print_stack_trace
  fi

  # Send email notification about the error
  # Only if configuration has been loaded
  if [[ -n "$EMAIL_ENABLED" ]]; then
      send_completion_notification "error" 1
  fi

  exit 1
}

##############################################################################
# Email Notification Functions
###############################################################################
send_email() {
    local subject="$1"
    local message="$2"
    local log_file_path="$3"  # Optional log file path to include as attachment
    
    # Skip if email notifications are disabled
    if [[ "${EMAIL_ENABLED,,}" != "true" ]] || [[ -z "$EMAIL_ADDRESS" ]]; then
        return 0
    fi
    
    log "Sending email notification to $EMAIL_ADDRESS: $subject"
    
    # Convert plain text message to simple HTML format
    local html_content="<html><body><pre style=\"font-family: monospace;\">${message}</pre></body></html>"
    
    # Define path to the send_email script
    local email_script="${SCRIPT_DIR}/send_email/multireport_sendemail.py"
    
    # Check if the email script exists and is executable
    if [[ ! -f "$email_script" ]]; then
        log "${YELLOW}[WARN]${NC} Email script not found at $email_script"
        return 1
    fi
    
    # Execute the email command
    log "Executing email script: $email_script"
    local email_result
    local email_exit_code
    
    if [[ -n "$log_file_path" && -f "$log_file_path" ]]; then
        log "Including log file as attachment: $log_file_path"
        email_result=$(python3 "$email_script" --subject "$subject" --to_address "$EMAIL_ADDRESS" --mail_body_html "$html_content" --attachment_files "$log_file_path" 2>&1)
        email_exit_code=$?
    else
        email_result=$(python3 "$email_script" --subject "$subject" --to_address "$EMAIL_ADDRESS" --mail_body_html "$html_content" 2>&1)
        email_exit_code=$?
    fi
    
    # Parse JSON response to check if email was sent successfully
    if [[ $email_exit_code -eq 0 ]]; then
        # Check if we got valid JSON response
        if ! echo "$email_result" | jq -e . >/dev/null 2>&1; then
            log "${YELLOW}[WARN]${NC} Email script returned non-JSON response: $email_result"
            return 1
        fi
        
        # Parse the structured response from your email script
        error_status=$(echo "$email_result" | jq -r '.error' 2>/dev/null)
        detail=$(echo "$email_result" | jq -r '.detail' 2>/dev/null)
        total_attach=$(echo "$email_result" | jq -r '.total_attach' 2>/dev/null)
        ok_attach=$(echo "$email_result" | jq -r '.ok_attach' 2>/dev/null)
        
        if [[ "$error_status" == "false" ]]; then
            # Email sent successfully
            log "Email notification sent successfully: $detail"
            if [[ "$total_attach" -gt 0 ]]; then
                if [[ "$ok_attach" -eq "$total_attach" ]]; then
                    log "All $total_attach attachment(s) sent successfully"
                else
                    log "${YELLOW}[WARN]${NC} Attachments: $ok_attach of $total_attach successful"
                fi
            fi
            return 0
        else
            # Email script reported an error
            log "${YELLOW}[WARN]${NC} Email script reported error: $detail"
            log "${YELLOW}[WARN]${NC} Full email response: $email_result"
            if [[ "$total_attach" -gt 0 && "$ok_attach" -ne "$total_attach" ]]; then
                log "${YELLOW}[WARN]${NC} Attachment issues: $ok_attach of $total_attach successful"
            fi
            return 1
        fi
    else
        # Email script failed to execute or crashed
        log "${YELLOW}[WARN]${NC} Email script failed to execute (exit code: $email_exit_code)"
        log "${YELLOW}[WARN]${NC} Full error output: $email_result"
        return 1
    fi
}

send_start_notification() {
    # Skip if email notifications are disabled
    if [[ "${EMAIL_ENABLED,,}" != "true" ]] || [[ -z "$EMAIL_ADDRESS" ]]; then
        return 0
    fi
    
    local subject="${EMAIL_SUBJECT_PREFIX} Backup Started - ${zfs_group_name} to ${DST_POOL}"
    local message="ZFS Backup started at $(date '+%F %T')
    
Source Pool: ${zfs_group_name}
Destination Pool: ${DST_POOL}
Backup Disk Serial: ${BACKUP_DISK_SERIAL}

This is an automated message from your TrueNAS ZFS backup script."
    
    log "Sending backup start notification email"
    send_email "$subject" "$message"
}

send_completion_notification() {
    # Skip if email notifications are disabled
    if [[ "${EMAIL_ENABLED,,}" != "true" ]] || [[ -z "$EMAIL_ADDRESS" ]]; then
        return 0
    fi
    
    local status="$1"  # success or error
    local exit_code="$2"
    local message_prefix="Successfully completed"
    
    if [[ "$status" == "error" ]]; then
        message_prefix="Failed with error code $exit_code"
    fi
    
    local subject="${EMAIL_SUBJECT_PREFIX} Backup ${status^} - ${zfs_group_name} to ${DST_POOL}"
    local message="ZFS Backup ${message_prefix} at $(date '+%F %T')
    
Source Pool: ${zfs_group_name}
Destination Pool: ${DST_POOL}
Backup Disk Serial: ${BACKUP_DISK_SERIAL}

The complete backup log is attached to this email.
This is an automated message from your TrueNAS ZFS backup script."
    
    log "Sending backup completion notification email with log attachment"
    send_email "$subject" "$message" "$LOG_FILE"
}




















## Not really used anymore, but kept for potential future use
#run_step() {
#  desc="$1"; shift
#  log "→ $desc"
#  # Execute command, pipe combined stdout/stderr to tee.
#  # tee displays on console (stdout) and always appends to the log file.
#  # 'set -o pipefail' (set globally above) ensures the exit status reflects the original command's failure.
#  if ! "$@" 2>&1 | tee -a "$LOG_FILE"; then
#    error_exit "Step failed: $desc (See log file '$LOG_FILE' for details)"
#  fi
#  # Log success only if the command truly succeeded
#  log "${GREEN}[DONE]${NC} $desc"
#}