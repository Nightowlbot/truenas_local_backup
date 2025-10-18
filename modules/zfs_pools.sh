###############################################################################
# Docker Service Management
###############################################################################

# Stop Docker service for backup
stop_docker_service() {
    local stop_docker="$1"
    
    # Configurable parameters for Docker service operations
    local DOCKER_STOP_MAX_ATTEMPTS=15
    local DOCKER_STOP_CHECK_INTERVAL=5
    
    # Skip if Docker management is disabled
    if [[ "$stop_docker" != "true" ]]; then
        log "Docker service management disabled for this backup configuration"
        return 0
    fi
    
    log "Stopping Docker service before snapshot creation..."
    
    # Stop Docker service and socket using systemctl
    if systemctl stop docker.service docker.socket 2>&1 | tee -a "$LOG_FILE"; then
        log "Docker stop command executed, verifying service is stopped..."
        
        # Wait and verify Docker service and socket are actually stopped
        local attempt=0
        local docker_stopped=false
        
        while [ $attempt -lt $DOCKER_STOP_MAX_ATTEMPTS ]; do
            if ! systemctl is-active --quiet docker.service && ! systemctl is-active --quiet docker.socket; then
                docker_stopped=true
                break
            fi
            local service_status="active"
            local socket_status="active"
            systemctl is-active --quiet docker.service || service_status="inactive"
            systemctl is-active --quiet docker.socket || socket_status="inactive"
            log "Docker service: $service_status, socket: $socket_status, waiting... (attempt $((attempt + 1))/$DOCKER_STOP_MAX_ATTEMPTS)"
            sleep $DOCKER_STOP_CHECK_INTERVAL
            ((attempt++))
        done

        sleep $DOCKER_STOP_CHECK_INTERVAL
        
        if $docker_stopped; then
            log "${GREEN}Docker service and socket successfully stopped and verified${NC}"
            export DOCKER_WAS_STOPPED="true"
        else
            error_exit "Docker service and/or socket failed to stop within $DOCKER_STOP_MAX_ATTEMPTS attempts - aborting backup to prevent inconsistent data"
        fi
    else
        error_exit "Failed to execute Docker stop command - aborting backup to prevent inconsistent data"
    fi
    
    return 0
}

# Start Docker service after backup
start_docker_service() {
    local stop_docker="$1"
    
    # Configurable parameters for Docker service operations
    local DOCKER_START_MAX_ATTEMPTS=20
    local DOCKER_START_CHECK_INTERVAL=5
    
    # Skip if Docker management is disabled or wasn't stopped
    if [[ "$stop_docker" != "true" ]] || [[ "$DOCKER_WAS_STOPPED" != "true" ]]; then
        log "Docker service restart not needed for this backup configuration"
        return 0
    fi
    
    log "Starting Docker service after snapshot creation..."
    
    # Start Docker service and socket using systemctl
    if systemctl start docker.service docker.socket 2>&1 | tee -a "$LOG_FILE"; then
        log "Docker start command executed, verifying service is running..."
        
        # Wait and verify Docker service and socket are actually running
        local attempt=0
        local docker_started=false
        
        while [ $attempt -lt $DOCKER_START_MAX_ATTEMPTS ]; do
            if systemctl is-active --quiet docker.service && systemctl is-active --quiet docker.socket; then
                docker_started=true
                break
            fi
            local service_status="inactive"
            local socket_status="inactive"
            systemctl is-active --quiet docker.service && service_status="active"
            systemctl is-active --quiet docker.socket && socket_status="active"
            log "Docker service: $service_status, socket: $socket_status, waiting... (attempt $((attempt + 1))/$DOCKER_START_MAX_ATTEMPTS)"
            sleep $DOCKER_START_CHECK_INTERVAL
            ((attempt++))
        done
        
        if $docker_started; then
            log "${GREEN}Docker service and socket successfully started and verified${NC}"
        else
            log "${RED}Docker service and/or socket failed to start within $DOCKER_START_MAX_ATTEMPTS attempts${NC}"
            log "${RED}Please manually start Docker: systemctl start docker.service docker.socket${NC}"
        fi
    else
        log "${RED}Failed to execute Docker start command${NC}"
        log "${RED}Please manually start Docker service: systemctl start docker${NC}"
    fi
    
    # Clear the Docker stopped flag
    unset DOCKER_WAS_STOPPED
    
    return 0
}

###############################################################################
# Import Backup Pool
###############################################################################
import_backup_pool() {
    log "Starting backup pool import process for pool: ${DST_POOL}"
    
    # Check if pool is already imported (active)
    if zpool status "$DST_POOL" &>/dev/null; then
        log "Pool ${DST_POOL} is already imported and active"
        return 0
    fi
    
    log "Pool ${DST_POOL} not found in active pools, searching for importable pools..."
    
    # Call pool.import_find to get list of importable pools
    local find_job_output
    local job_id
    if ! find_job_output=$(midclt call pool.import_find 2>&1); then
        error_exit "Failed to find importable pools via midclt: ${find_job_output}"
    fi
    
    # Extract job ID from the output (should be a number)
    if ! job_id=$(echo "$find_job_output" | grep -E '^[0-9]+$'); then
        error_exit "Invalid job ID returned from pool.import_find: ${find_job_output}"
    fi
    
    log "Started pool import find job with ID: ${job_id}"
    
    # Wait for the job to complete and get results
    local job_result
    local attempt=0
    local max_attempts=30
    while [ $attempt -lt $max_attempts ]; do
        local job_status
        if ! job_status=$(midclt call core.get_jobs '[["id", "=", '"$job_id"']]' 2>&1); then
            error_exit "Failed to get job status: ${job_status}"
        fi
        
        local state
        if ! state=$(echo "$job_status" | jq -r '.[0].state' 2>/dev/null); then
            error_exit "Failed to parse job status JSON"
        fi
        
        case "$state" in
            "SUCCESS")
                log "Pool import find job completed successfully"
                if ! job_result=$(echo "$job_status" | jq -r '.[0].result' 2>/dev/null); then
                    error_exit "Failed to extract job result from pool import find"
                fi
                break
                ;;
            "FAILED")
                local error_msg
                error_msg=$(echo "$job_status" | jq -r '.[0].error // "Unknown error"' 2>/dev/null)
                error_exit "Pool import find job failed: ${error_msg}"
                ;;
            "RUNNING"|"WAITING")
                log "Pool import find job still running, waiting... (attempt $((attempt + 1))/${max_attempts})"
                sleep 2
                ((attempt++))
                ;;
            *)
                error_exit "Unknown job state: ${state}"
                ;;
        esac
    done
    
    if [ $attempt -ge $max_attempts ]; then
        error_exit "Pool import find job timed out after ${max_attempts} attempts"
    fi
    
    # Parse the result to find our target pool
    local pool_guid
    local pool_name
    local pool_status
    if ! pool_info=$(echo "$job_result" | jq -r '.[] | select(.name == "'"$DST_POOL"'") | "\(.guid)|\(.name)|\(.status)"' 2>/dev/null); then
        error_exit "Failed to parse importable pools JSON"
    fi
    
    if [ -z "$pool_info" ]; then
        log "${RED}ERROR: Pool '${DST_POOL}' not found in importable pools${NC}"
        log "Available pools for import:"
        echo "$job_result" | jq -r '.[] | "  - \(.name) (GUID: \(.guid), Status: \(.status))"' 2>/dev/null || log "Could not list available pools"
        error_exit "Pool '${DST_POOL}' not found in importable pools - ensure backup disk is connected"
    fi
    
    IFS='|' read -r pool_guid pool_name pool_status <<< "$pool_info"
    log "Found pool '${pool_name}' with GUID '${pool_guid}' and status '${pool_status}'"
    
    # Import the pool using its GUID
    log "Importing pool '${DST_POOL}' with GUID '${pool_guid}'..."
    
    local import_job_output
    local import_job_id
    if ! import_job_output=$(midclt call pool.import_pool '{"guid": "'"$pool_guid"'", "name": "'"$DST_POOL"'"}' 2>&1); then
        error_exit "Failed to start pool import via midclt: ${import_job_output}"
    fi
    
    # Extract import job ID
    if ! import_job_id=$(echo "$import_job_output" | grep -E '^[0-9]+$'); then
        error_exit "Invalid job ID returned from pool.import_pool: ${import_job_output}"
    fi
    
    log "Started pool import job with ID: ${import_job_id}"
    
    # Wait for the import job to complete
    attempt=0
    max_attempts=60  # Pool import might take longer
    while [ $attempt -lt $max_attempts ]; do
        local import_job_status
        if ! import_job_status=$(midclt call core.get_jobs '[["id", "=", '"$import_job_id"']]' 2>&1); then
            error_exit "Failed to get import job status: ${import_job_status}"
        fi
        
        local import_state
        if ! import_state=$(echo "$import_job_status" | jq -r '.[0].state' 2>/dev/null); then
            error_exit "Failed to parse import job status JSON"
        fi
        
        case "$import_state" in
            "SUCCESS")
                log "${GREEN}Pool '${DST_POOL}' imported successfully${NC}"
                # Verify the pool is now available
                if zpool status "$DST_POOL" &>/dev/null; then
                    log "${GREEN}Pool import verified - '${DST_POOL}' is now active${NC}"
                    return 0
                else
                    error_exit "Pool import reported success but pool is not accessible"
                fi
                ;;
            "FAILED")
                local import_error_msg
                import_error_msg=$(echo "$import_job_status" | jq -r '.[0].error // "Unknown error"' 2>/dev/null)
                error_exit "Pool import job failed: ${import_error_msg}"
                ;;
            "RUNNING"|"WAITING")
                log "Pool import job still running, waiting... (attempt $((attempt + 1))/${max_attempts})"
                sleep 3
                ((attempt++))
                ;;
            *)
                error_exit "Unknown import job state: ${import_state}"
                ;;
        esac
    done
    
    if [ $attempt -ge $max_attempts ]; then
        error_exit "Pool import job timed out after ${max_attempts} attempts"
    fi
}

###############################################################################
# Check Backup Pool Status
###############################################################################
check_backup_pool_status() {
    log "Checking backup pool status for: ${DST_POOL}"
    
    # Validate that DST_POOL is set
    if [[ -z "$DST_POOL" ]]; then
        error_exit "DST_POOL is not set - cannot check pool status"
    fi
    
    # First, query pools to get the pool ID by name
    log "Querying pool information for '${DST_POOL}'..."
    local pool_query_result
    if ! pool_query_result=$(midclt call pool.query '[["name", "=", "'"$DST_POOL"'"]]' 2>&1); then
        error_exit "Failed to query pool information via midclt: ${pool_query_result}"
    fi
    
    # Parse the query result to get pool ID
    local pool_id
    if ! pool_id=$(echo "$pool_query_result" | jq -r '.[0].id // empty' 2>/dev/null); then
        error_exit "Failed to parse pool query JSON response"
    fi
    
    if [ -z "$pool_id" ] || [ "$pool_id" = "null" ]; then
        log "${RED}ERROR: Pool '${DST_POOL}' not found in active pools${NC}"
        log "Available pools:"
        midclt call pool.query '[]' 2>/dev/null | jq -r '.[] | "  - \(.name) (ID: \(.id))"' 2>/dev/null || log "Could not list available pools"
        error_exit "Pool '${DST_POOL}' not found - ensure pool is imported first"
    fi
    
    log "Found pool '${DST_POOL}' with ID: ${pool_id}"
    
    # Use TrueNAS API to get pool instance details using the pool ID
    local pool_info
    if ! pool_info=$(midclt call pool.get_instance "$pool_id" 2>&1); then
        error_exit "Failed to get pool information for ${DST_POOL} (ID: ${pool_id}): ${pool_info}"
    fi
    
    # Parse the JSON response to extract health-related fields
    local pool_status
    local pool_healthy
    local pool_warning
    local status_code
    local status_detail
    
    # Extract status (required field)
    if ! pool_status=$(echo "$pool_info" | jq -r '.status // empty' 2>/dev/null); then
        error_exit "Failed to parse pool status from API response"
    fi
    
    # Extract healthy flag (boolean)
    if ! pool_healthy=$(echo "$pool_info" | jq -r '.healthy // false' 2>/dev/null); then
        error_exit "Failed to parse pool healthy flag from API response"
    fi
    
    # Extract warning flag (boolean)
    if ! pool_warning=$(echo "$pool_info" | jq -r '.warning // false' 2>/dev/null); then
        pool_warning="false"  # Default to false if not present
    fi
    
    # Extract status_code (optional string)
    status_code=$(echo "$pool_info" | jq -r '.status_code // "none"' 2>/dev/null)
    
    # Extract status_detail (optional string)
    status_detail=$(echo "$pool_info" | jq -r '.status_detail // "none"' 2>/dev/null)
    
    # Log the pool health information
    log "Pool Status Information:"
    log "  Pool Name: ${DST_POOL}"
    log "  Status: ${pool_status}"
    log "  Healthy: ${pool_healthy}"
    log "  Warning: ${pool_warning}"
    log "  Status Code: ${status_code}"
    log "  Status Detail: ${status_detail}"

    
    # Check for acceptable pool statuses first (most important check)
    case "$pool_status" in
        "ONLINE")
            log "${GREEN}Pool ${DST_POOL} is ONLINE${NC}"
            ;;
        "DEGRADED")
            log "${YELLOW}WARNING: Pool ${DST_POOL} is DEGRADED but may be usable for backup${NC}"
            if [[ "$status_detail" != "none" && "$status_detail" != "null" ]]; then
                log "${YELLOW}Details: ${status_detail}${NC}"
            fi
            ;;
        "FAULTED"|"UNAVAIL"|"REMOVED"|"OFFLINE")
            local error_msg="Pool ${DST_POOL} status is ${pool_status} - cannot proceed with backup"
            if [[ "$status_detail" != "none" && "$status_detail" != "null" ]]; then
                error_msg="${error_msg}. Details: ${status_detail}"
            fi
            error_exit "$error_msg"
            ;;
        "")
            error_exit "Pool ${DST_POOL} status is empty - unable to determine pool health"
            ;;
        *)
            log "${YELLOW}WARNING: Pool ${DST_POOL} has unknown status: ${pool_status}${NC}"
            if [[ "$status_detail" != "none" && "$status_detail" != "null" ]]; then
                log "${YELLOW}Details: ${status_detail}${NC}"
            fi
            log "${YELLOW}Proceeding with caution - unknown status may indicate issues${NC}"
            ;;
    esac
    
    # Check if the pool is in a healthy state (secondary check)
    if [[ "$pool_healthy" != "true" ]]; then
        # For unhealthy pools, check if it's a critical failure or just degraded
        case "$pool_status" in
            "ONLINE"|"DEGRADED")
                log "${YELLOW}WARNING: Pool ${DST_POOL} healthy flag is false, but status is ${pool_status}${NC}"
                log "${YELLOW}Proceeding with backup but monitoring recommended${NC}"
                ;;
            *)
                local error_msg="Pool ${DST_POOL} is not healthy (status: ${pool_status})"
                if [[ "$status_detail" != "none" && "$status_detail" != "null" ]]; then
                    error_msg="${error_msg}. Details: ${status_detail}"
                fi
                error_exit "$error_msg"
                ;;
        esac
    fi
    
    # Check for warnings (informational - backup can still proceed)
    if [[ "$pool_warning" == "true" ]]; then
        log "${YELLOW}WARNING: Pool ${DST_POOL} has warning conditions${NC}"
        if [[ "$status_detail" != "none" && "$status_detail" != "null" ]]; then
            log "${YELLOW}Details: ${status_detail}${NC}"
        fi
        log "${YELLOW}Proceeding with backup despite warnings - monitor pool health${NC}"
    fi
    
    # Final status message
    if [[ "$pool_healthy" == "true" && "$pool_warning" != "true" ]]; then
        log "${GREEN}Pool ${DST_POOL} is healthy and ready for backup${NC}"
    else
        log "${YELLOW}Pool ${DST_POOL} has some concerns but backup will proceed${NC}"
    fi
    
    return 0
}

###############################################################################
# Optional Scrub
###############################################################################
run_scrub() {
    log "Checking scrub configuration for pool: ${DST_POOL}"
    
    # Check if scrub is enabled
    if [[ "${ENABLE_SCRUB,,}" != "true" ]]; then
        log "Scrub is disabled (ENABLE_SCRUB=${ENABLE_SCRUB}), skipping scrub"
        return 0
    fi
    
    # Validate required variables
    if [[ -z "$DST_POOL" ]]; then
        error_exit "DST_POOL is not set - cannot run scrub"
    fi
    
    if [[ -z "$SCRUB_INTERVAL_DAYS" ]]; then
        error_exit "SCRUB_INTERVAL_DAYS is not set - cannot determine scrub schedule"
    fi
    
    # Validate SCRUB_INTERVAL_DAYS is a positive number
    if ! [[ "$SCRUB_INTERVAL_DAYS" =~ ^[0-9]+$ ]] || [[ "$SCRUB_INTERVAL_DAYS" -eq 0 ]]; then
        error_exit "SCRUB_INTERVAL_DAYS must be a positive integer, got: ${SCRUB_INTERVAL_DAYS}"
    fi
    
    log "Scrub is enabled with ${SCRUB_INTERVAL_DAYS} day interval"
    
    # Get current pool information to check scrub status
    # First get pool ID
    local pool_query_result
    if ! pool_query_result=$(midclt call pool.query '[["name", "=", "'"$DST_POOL"'"]]' 2>&1); then
        error_exit "Failed to query pool information for scrub check: ${pool_query_result}"
    fi
    
    local pool_id
    if ! pool_id=$(echo "$pool_query_result" | jq -r '.[0].id // empty' 2>/dev/null); then
        error_exit "Failed to parse pool ID from query response"
    fi
    
    if [ -z "$pool_id" ] || [ "$pool_id" = "null" ]; then
        error_exit "Pool '${DST_POOL}' not found for scrub operation"
    fi
    
    log "Found pool '${DST_POOL}' with ID: ${pool_id}"
    
    # Get pool scan/scrub information using pool.get_instance
    local pool_info
    if ! pool_info=$(midclt call pool.get_instance "$pool_id" 2>&1); then
        error_exit "Failed to get pool instance information for scrub check: ${pool_info}"
    fi
    
    # Extract scan information from pool data
    local scan_info
    scan_info=$(echo "$pool_info" | jq '.scan' 2>/dev/null)
    
    if [[ "$scan_info" == "null" ]]; then
        log "No scan information available for pool, proceeding with scrub"
    else
        # Parse scan information - note that individual fields may be null
        local scan_function
        local scan_state
        local scan_end_time
        local total_secs_left

        scan_function=$(echo "$scan_info" | jq -r '.function // "null"' 2>/dev/null)
        scan_state=$(echo "$scan_info" | jq -r '.state // "null"' 2>/dev/null)
        scan_end_time=$(echo "$scan_info" | jq -r '.end_time // "null"' 2>/dev/null)
        total_secs_left=$(echo "$scan_info" | jq -r '.total_secs_left // "null"' 2>/dev/null)
        
        log "Pool scan status: function=${scan_function}, state=${scan_state}, end_time=${scan_end_time}, total_secs_left=${total_secs_left}"
        
        # Only allow scrub if no scan operation is active or if last scrub is finished
        if [[ "$scan_function" == "SCRUB" && "$scan_state" != "FINISHED" && "$scan_state" != "null" ]]; then
            error_exit "Cannot start scrub on pool ${DST_POOL}: Previous scrub state is '${scan_state}' (not FINISHED)"
        fi
        
        # Also check if there's time remaining on any scan operation (double check to be extra safe)
        if [[ "$total_secs_left" != "null" && "$total_secs_left" != "0" ]]; then
            error_exit "Cannot start scrub on pool ${DST_POOL}: Scan operation in progress (${total_secs_left} seconds remaining)"
        fi
        
        # Check last scrub time if available
        if [[ "$scan_end_time" != "null" && "$scan_function" == "SCRUB" && "$scan_state" == "FINISHED" ]]; then
            # Calculate days since last scrub
            local current_time
            current_time=$(date +%s)
            
            # Convert scan_end_time from MongoDB extended JSON format to epoch seconds
            # TrueNAS returns: {"$date": 1760362731000} (milliseconds)
            local last_scrub_time
            if [[ "$scan_end_time" =~ \"\$date\":[[:space:]]*([0-9]+) ]]; then
                local millis="${BASH_REMATCH[1]}"
                last_scrub_time=$((millis / 1000))  # Convert milliseconds to seconds
                log "Parsed scrub end time: ${millis}ms -> ${last_scrub_time}s"
            else
                log "${YELLOW}Unexpected date format in scan_end_time: ${scan_end_time}, proceeding with scrub${NC}"
                last_scrub_time=0
            fi
            
            if [[ "$last_scrub_time" -gt 0 ]]; then
                local days_since_scrub
                days_since_scrub=$(( (current_time - last_scrub_time) / 86400 ))
                
                log "Last scrub completed ${days_since_scrub} days ago (threshold: ${SCRUB_INTERVAL_DAYS} days)"
                
                if [[ "$days_since_scrub" -lt "$SCRUB_INTERVAL_DAYS" ]]; then
                    log "${GREEN}Pool ${DST_POOL} was scrubbed recently (${days_since_scrub} days ago), skipping scrub${NC}"
                    return 0
                fi
            fi
        fi
    fi
    
    # Start scrub
    log "Starting scrub on pool: ${DST_POOL}"
    
    local scrub_job_output
    local scrub_job_id
    if ! scrub_job_output=$(midclt call pool.scrub.scrub "$DST_POOL" "START" 2>&1); then
        error_exit "Failed to start scrub on pool ${DST_POOL}: ${scrub_job_output}"
    fi
    
    # Extract job ID - scrub is always a job-based operation
    if ! [[ "$scrub_job_output" =~ ^[0-9]+$ ]]; then
        error_exit "Invalid job ID returned from pool.scrub.scrub: ${scrub_job_output}"
    fi
    
    scrub_job_id="$scrub_job_output"
    log "Started scrub job with ID: ${scrub_job_id}"
    
    # Wait for the scrub job to complete
    local job_state=""
    local attempt=0
    local max_attempts=3600
    local check_interval=60  # Check every x seconds
    
    log "Waiting for scrub job to complete (this may take several minutes)..."
    
    while [ $attempt -lt $max_attempts ]; do
        local job_status
        if ! job_status=$(midclt call core.get_jobs '[["id", "=", '"$scrub_job_id"']]' 2>&1); then
            log "${YELLOW}WARNING: Failed to get scrub job status (attempt $((attempt + 1))): ${job_status}${NC}"
            sleep $check_interval
            attempt=$((attempt + 1))
            continue
        fi
        
        if ! job_state=$(echo "$job_status" | jq -r '.[0].state // empty' 2>/dev/null); then
            log "${YELLOW}WARNING: Failed to parse job state (attempt $((attempt + 1)))${NC}"
            sleep $check_interval
            attempt=$((attempt + 1))
            continue
        fi
        
        case "$job_state" in
            "SUCCESS")
                log "${GREEN}Scrub job completed successfully${NC}"
                
                # Get job result to check for errors found during scrub
                local job_result
                if job_result=$(echo "$job_status" | jq -r '.[0].result // empty' 2>/dev/null); then
                    if [[ -n "$job_result" && "$job_result" != "null" && "$job_result" != "empty" ]]; then
                        log "Scrub result: ${job_result}"
                    fi
                fi
                
                # Additional check: Get current pool scan status to verify scrub results
                local final_pool_info
                if final_pool_info=$(midclt call pool.get_instance "$pool_id" 2>&1); then
                    local final_scan_info
                    final_scan_info=$(echo "$final_pool_info" | jq '.scan' 2>/dev/null)
                    
                    if [[ "$final_scan_info" != "null" ]]; then
                        local scan_errors
                        scan_errors=$(echo "$final_scan_info" | jq -r '.errors // "null"' 2>/dev/null)
                        
                        if [[ "$scan_errors" != "null" && "$scan_errors" != "0" ]]; then
                            error_exit "Scrub completed but found ${scan_errors} errors on pool ${DST_POOL}. Backup aborted for safety."
                        else
                            log "${GREEN}Scrub completed successfully with no errors found${NC}"
                        fi
                    else
                        log "${GREEN}Scrub completed successfully (no scan data available)${NC}"
                    fi
                fi
                break
                ;;
            "RUNNING")
                if (( attempt % 6 == 0 )); then  # Log progress every minute (6 * 10 seconds)
                    log "Scrub job still running... (${attempt}0 seconds elapsed)"
                fi
                ;;
            "FAILED")
                local job_error
                job_error=$(echo "$job_status" | jq -r '.[0].error // "Unknown error"' 2>/dev/null)
                error_exit "Scrub job failed: ${job_error}"
                ;;
            "WAITING"|"PENDING")
                log "Scrub job is pending/waiting to start..."
                ;;
            *)
                log "Scrub job state: ${job_state} (waiting for completion...)"
                ;;
        esac
        
        sleep $check_interval
        attempt=$((attempt + 1))
    done
    
    if [ $attempt -ge $max_attempts ]; then
        error_exit "Scrub job timed out after $((max_attempts * check_interval)) seconds"
    fi
    
    log "${GREEN}Scrub initiated on pool ${DST_POOL}${NC}"
    return 0
}



###############################################################################
# Run ZFS Autobackup
###############################################################################
run_zfs_autobackup() {
    log "Starting ZFS autobackup process from ${zfs_group_name} to ${DST_POOL} (two-step: snapshots then transfer)"
    
    # Validate required variables - these are fatal errors that should stop the backup
    if [[ -z "$zfs_group_name" ]]; then
        error_exit "zfs_group_name is not set - cannot proceed with backup"
    fi
    
    if [[ -z "$DST_POOL" ]]; then
        error_exit "DST_POOL is not set - cannot proceed with backup"
    fi
    
    if [[ -z "$KEEP_COUNT" ]]; then
        error_exit "KEEP_COUNT is not set - cannot proceed with backup"
    fi
    
    # Check if python3 is available - fatal error
    if ! command -v python3 >/dev/null 2>&1; then
        error_exit "python3 is not available, required for zfs_autobackup"
    fi
    
    # Define the path to zfs_autobackup module in the script directory
    local zfs_autobackup_dir="${SCRIPT_DIR}/zfs_autobackup"
    
    # Check if the zfs_autobackup directory exists - fatal error
    if [[ ! -d "$zfs_autobackup_dir" ]]; then
        error_exit "zfs_autobackup directory not found at: ${zfs_autobackup_dir}"
    fi
    
    # Check if the zfs_autobackup module structure exists - fatal error
    if [[ ! -f "${zfs_autobackup_dir}/zfs_autobackup/ZfsAutobackup.py" ]]; then
        error_exit "zfs_autobackup module not found at: ${zfs_autobackup_dir}/zfs_autobackup/ZfsAutobackup.py"
    fi
    
    log "Found zfs_autobackup module at: ${zfs_autobackup_dir}"
    
    # Set up Python path to include the zfs_autobackup directory
    # This allows Python to find the zfs_autobackup module
    export PYTHONPATH="${zfs_autobackup_dir}:${PYTHONPATH:-}"
    log "Set PYTHONPATH to include: ${zfs_autobackup_dir}"
    
    # Change to the zfs_autobackup directory for module execution
    local original_pwd="$PWD"
    cd "$zfs_autobackup_dir"
    log "Changed to zfs_autobackup directory for module execution: $zfs_autobackup_dir"
    
    # Stop Docker service before creating snapshots (if configured)
    stop_docker_service "$DOCKER_CONTAINERS"
    
    # Step 1: Create snapshots only (no transfer)
    log "Step 1: Creating snapshots with --no-send flag"
    local snapshot_cmd=(
        "python3" "-m" "zfs_autobackup.ZfsAutobackup"
        "--clear-mountpoint"
        "--keep-source" "$KEEP_COUNT"
        "--keep-target" "$KEEP_COUNT"
        "--allow-empty"
        "--verbose"
        "--no-send"
        "$zfs_group_name"
        "$DST_POOL"
    )
    
    log "Executing snapshot creation command: ${snapshot_cmd[*]}"
    
    # Execute the snapshot command and display output to console while logging to file
    "${snapshot_cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
    local snapshot_exit_code=$?
    
    # Start Docker service back up after snapshot creation
    start_docker_service "$DOCKER_CONTAINERS"
    
    # Check the exit code for snapshot creation
    if [ $snapshot_exit_code -ne 0 ]; then
        # Return to original directory before error exit
        cd "$original_pwd"
        error_exit "ZFS snapshot creation failed with exit code: ${snapshot_exit_code}"
    fi
    
    log "${GREEN}Snapshots created successfully${NC}"
    
    # Step 2: Transfer snapshots (without --no-send flag)
    log "Step 2: Transferring snapshots to backup pool"
    local transfer_cmd=(
        "python3" "-m" "zfs_autobackup.ZfsAutobackup"
        "--clear-mountpoint"
        "--keep-source" "$KEEP_COUNT"
        "--keep-target" "$KEEP_COUNT"
        "--allow-empty"
        "--verbose"
        "--no-snapshot"
        "$zfs_group_name"
        "$DST_POOL"
    )
    
    log "Executing transfer command: ${transfer_cmd[*]}"
    
    # Execute the transfer command and display output to console while logging to file
    "${transfer_cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
    local transfer_exit_code=$?
    
    # Return to original directory
    cd "$original_pwd"
    
    # Check the exit code for transfer
    if [ $transfer_exit_code -eq 0 ]; then
        log "${GREEN}ZFS autobackup completed successfully (snapshots created and transferred)${NC}"
        return 0
    else
        error_exit "ZFS transfer failed with exit code: ${transfer_exit_code}"
    fi
}

###############################################################################
# Export Backup Pool
###############################################################################
export_backup_pool() {
    log "Starting backup pool export process for pool: ${DST_POOL}"
    
    # Check if pool is currently imported (active)
    if ! zpool status "$DST_POOL" &>/dev/null; then
        log "Pool ${DST_POOL} is not currently imported/active - nothing to export"
        return 0
    fi
    
    log "Pool ${DST_POOL} is active, proceeding with export..."
    
    # Query pools to get the pool ID by name
    log "Querying pool information for '${DST_POOL}'..."
    local pool_query_result
    if ! pool_query_result=$(midclt call pool.query '[["name", "=", "'"$DST_POOL"'"]]' 2>&1); then
        error_exit "Failed to query pool information via midclt: ${pool_query_result}"
    fi
    
    # Parse the query result to get pool ID
    local pool_id
    if ! pool_id=$(echo "$pool_query_result" | jq -r '.[0].id // empty' 2>/dev/null); then
        error_exit "Failed to parse pool query JSON response"
    fi
    
    if [ -z "$pool_id" ] || [ "$pool_id" = "null" ]; then
        log "${RED}ERROR: Pool '${DST_POOL}' not found in active pools${NC}"
        log "Available pools:"
        midclt call pool.query '[]' 2>/dev/null | jq -r '.[] | "  - \(.name) (ID: \(.id))"' 2>/dev/null || log "Could not list available pools"
        error_exit "Pool '${DST_POOL}' not found in active pools - cannot export"
    fi
    
    log "Found pool '${DST_POOL}' with ID: ${pool_id}"
    
    # Export the pool using its ID
    log "Exporting pool '${DST_POOL}' (ID: ${pool_id})..."
    
    local export_job_output
    local export_job_id
    # Export with cascade=false, restart_services=false, destroy=false (safe export)
    if ! export_job_output=$(midclt call pool.export "$pool_id" '{"cascade": false, "restart_services": false, "destroy": false}' 2>&1); then
        error_exit "Failed to start pool export via midclt: ${export_job_output}"
    fi
    
    # Extract export job ID
    if ! export_job_id=$(echo "$export_job_output" | grep -E '^[0-9]+$'); then
        error_exit "Invalid job ID returned from pool.export: ${export_job_output}"
    fi
    
    log "Started pool export job with ID: ${export_job_id}"
    
    # Wait for the export job to complete
    local attempt=0
    local max_attempts=30  # Pool export should be relatively quick
    while [ $attempt -lt $max_attempts ]; do
        local export_job_status
        if ! export_job_status=$(midclt call core.get_jobs '[["id", "=", '"$export_job_id"']]' 2>&1); then
            error_exit "Failed to get export job status: ${export_job_status}"
        fi
        
        local export_state
        if ! export_state=$(echo "$export_job_status" | jq -r '.[0].state' 2>/dev/null); then
            error_exit "Failed to parse export job status JSON"
        fi
        
        case "$export_state" in
            "SUCCESS")
                log "${GREEN}Pool '${DST_POOL}' exported successfully${NC}"
                # Verify the pool is no longer accessible
                if ! zpool status "$DST_POOL" &>/dev/null; then
                    log "${GREEN}Pool export verified - '${DST_POOL}' is no longer active${NC}"
                    return 0
                else
                    log "${YELLOW}WARNING: Pool export reported success but pool is still accessible${NC}"
                    # This might be a timing issue, let's wait a moment and check again
                    sleep 2
                    if ! zpool status "$DST_POOL" &>/dev/null; then
                        log "${GREEN}Pool export verified after delay - '${DST_POOL}' is no longer active${NC}"
                        return 0
                    else
                        error_exit "Pool export reported success but pool remains accessible after verification"
                    fi
                fi
                ;;
            "FAILED")
                local export_error_msg
                export_error_msg=$(echo "$export_job_status" | jq -r '.[0].error // "Unknown error"' 2>/dev/null)
                error_exit "Pool export job failed: ${export_error_msg}"
                ;;
            "RUNNING"|"WAITING")
                log "Pool export job still running, waiting... (attempt $((attempt + 1))/${max_attempts})"
                sleep 2
                ((attempt++))
                ;;
            *)
                error_exit "Unknown export job state: ${export_state}"
                ;;
        esac
    done
    
    if [ $attempt -ge $max_attempts ]; then
        error_exit "Pool export job timed out after ${max_attempts} attempts"
    fi
}