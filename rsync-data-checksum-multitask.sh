#!/bin/bash

# Set strict bash options for better error handling
set -euo pipefail
IFS=$'\n\t'

# Configuration
readonly DB_NAME="/path/DB-dir"
readonly BASE_LOG_DIR="/path/log-dir/"
readonly TODAY_LOG_DIR="${BASE_LOG_DIR}/$(date +'%Y%m%d')"
readonly PUSHGATEWAY_URL="<http://$IP:$port-pushgateway>"  # Set your Pushgateway URL

# Enhanced logging function with different log levels
log() {
    local level="$1"
    local message="$2"
    local log_file="$3"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    local duration=""
    
    if [ $# -eq 4 ]; then
        duration=" (Duration: $4)"
    fi
    
    echo "[${timestamp}] [${level}] ${message}${duration}" | tee -a "$log_file"
}

# Push metrics to Pushgateway
push_metrics() {
    local metric_name="$1"
    local value="$2"
    local task_name="$3"
    
    cat <<EOF | curl --data-binary @- "${PUSHGATEWAY_URL}/metrics/job/${task_name}"
# TYPE ${metric_name} gauge
${metric_name} ${value}
EOF
}

# Function to calculate duration
get_duration() {
    local start_time="$1"
    local end_time="$2"
    local duration=$((end_time - start_time))
    local hours=$((duration / 3600))
    local minutes=$(( (duration % 3600) / 60 ))
    local seconds=$((duration % 60))
    echo "${hours}h ${minutes}m ${seconds}s"
}

# Enhanced process_and_sync with detailed progress logging
process_and_sync() {
    local source_directory="$1"
    local destination_directory="$2"
    local table="$3"
    local log_file="$4"
    local task_name="$5"
    local start_time
    start_time=$(date +%s)
    
    log "INFO" "Starting sync process for directory: $source_directory" "$log_file"
    
    local total_files
    total_files=$(find "$source_directory" -type f | wc -l)
    local processed_files=0
    local synced_files=0
    local failed_files=0
    
    while IFS= read -r -d '' file; do
        ((processed_files++))
        relative_path="${file#"${source_directory%/}/"}"
        
        log "INFO" "Processing file ${processed_files}/${total_files}: $relative_path" "$log_file"
        
        local checksum
        if ! checksum=$(md5sum "$file" 2>/dev/null | cut -d' ' -f1); then
            log "ERROR" "Failed to calculate MD5 for: $relative_path" "$log_file"
            ((failed_files++))
            continue
        fi
        
        local stored_checksum
        stored_checksum=$(sqlite3 "$DB_NAME" "SELECT md5_hash FROM ${table} WHERE file_path='${relative_path}' LIMIT 1;") || true
        
        if [[ "$checksum" != "$stored_checksum" ]]; then
            log "INFO" "Checksums differ, syncing file: $relative_path" "$log_file"
            if  rsync -avzh --progress --ignore-existing --stats --relative "$file" "$destination_directory/$relative_path" >> "$log_file" 2>&1; then
                sqlite3 "$DB_NAME" "INSERT INTO ${table} (file_path, md5_hash, last_synced) VALUES ('${relative_path}', '${checksum}', datetime('now')) ON CONFLICT(file_path) DO UPDATE SET md5_hash=excluded.md5_hash, last_synced=excluded.last_synced;"
                ((synced_files++))
                log "INFO" "Successfully synced: $relative_path" "$log_file"
            else
                ((failed_files++))
                log "ERROR" "Failed to sync: $relative_path" "$log_file"
            fi
        else
            log "INFO" "File already in sync: $relative_path" "$log_file"
        fi
    done < <(find "$source_directory" -type f -print0)
    
    local end_time
    end_time=$(date +%s)
    
    push_metrics "processed_files" "$processed_files" "$task_name"
    push_metrics "synced_files" "$synced_files" "$task_name"
    push_metrics "failed_files" "$failed_files" "$task_name"
    
    log "INFO" "Sync process completed" "$log_file" "$(get_duration "$start_time" "$end_time")"
    log "INFO" "Summary: Processed: $processed_files, Synced: $synced_files, Failed: $failed_files" "$log_file"
}

# Main function with enhanced logging
main() {
    local main_log_file="$TODAY_LOG_DIR/main.log"
    local start_time
    start_time=$(date +%s)
    
    mkdir -p "$TODAY_LOG_DIR"
    log "INFO" "Starting sync script" "$main_log_file"
    
    declare -A tasks=(
        ["task-name"]="/path/source/|/path/destination|$task-name"
        ["task-name"]="/path/source/|/path/destination|$task-name"
        # // put task in here if multiple task need to run 
        # ...
        # // end of task 

    for task_name in "${!tasks[@]}"; do
        local task_start_time
        task_start_time=$(date +%s)
        local task_log_file="$TODAY_LOG_DIR/logRsync_${task_name}.log"
        
        IFS='|' read -r source_dir dest_dir table_name <<< "${tasks[$task_name]}"
        
        log "INFO" "Starting task: $task_name" "$main_log_file"
        process_and_sync "$source_dir" "$dest_dir" "$table_name" "$task_log_file" "$task_name"
        
        local task_end_time
        task_end_time=$(date +%s)
        log "INFO" "Task $task_name completed" "$main_log_file" "$(get_duration "$task_start_time" "$task_end_time")"
    done
    
    local end_time
    end_time=$(date +%s)
    log "INFO" "All tasks completed" "$main_log_file" "$(get_duration "$start_time" "$end_time")"
}

if ! main; then
    log "ERROR" "Script failed with errors. Check logs for details." "$TODAY_LOG_DIR/main.log"
    exit 1
fi
