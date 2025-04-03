#!/bin/bash

# Base directories
base_log_dir="/path/log"
today_log_dir="$base_log_dir/$(date +'%Y%m%d')"
mkdir -p "$today_log_dir"

# Source folder
src_folder=(
  "/path/source"
)

# Destination folder
dest_folder="/path/destination"

PUSHGATEWAY_URL="<http://$domain:$port>"

# Logging function with timestamp and log level
log() {
  local level=$1
  local message=$2
  local logfile=$3
  local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] [$level] $message" | tee -a "$logfile"
}

push_metrics() {
    local metric_name="$1"
    local value="$2"
    local job_name="$3"

    cat <<EOF | curl --data-binary @- "${PUSHGATEWAY_URL}/metrics/job/${job_name}"
# TYPE ${metric_name} counter
${metric_name} ${value}
EOF
}

push_error_message() {
    local error_msg="$1"
    local job_name="$2"

    # Encode error message to avoid issues in Prometheus (replace special chars)
    local encoded_msg=$(echo "$error_msg" | sed 's/"/\\"/g' | sed 's/ /_/g' | sed 's/:/_/g')

    cat <<EOF | curl --data-binary @- "${PUSHGATEWAY_URL}/metrics/job/${job_name}"
# TYPE rsync_error_message gauge
rsync_error_message{error="$error_msg"} 1
EOF
}

# Start time
start_time=$(date +'%Y-%m-%d %H:%M:%S')

# Loop through each folder
for folder in "${src_folder[@]}"; do
  # Create log file name
  log_file="$today_log_dir/logRsync_$(basename "$folder")_$(basename "$dest_folder").log"

  file_count=0
  failed_count=0
  rsync_failed=0  # Default: No failure
  error_message="None"
  job_name="$job_name"
  
  # Log start of process
  log "INFO" "Starting rsync process" "$log_file"
  log "INFO" "Source: $folder" "$log_file"
  log "INFO" "Destination: $dest_folder" "$log_file"
  log "INFO" "Start time: $start_time" "$log_file"

  push_metrics "rsync_active" "1" "$job_name"
  
  # Run rsync with progress monitoring and logging
  rsync -avzh --progress --ignore-existing --exclude "*/2023/" --exclude "*/2024/" --stats "$folder" "$dest_folder" 2>&1 | 
  while IFS= read -r line; do
    if [[ "$line" == *"------Rsync data start------"* ]]; then
      log "INFO" "$line" "$log_file"
    elif [[ "$line" == *"building file list"* ]]; then
      log "INFO" "$line" "$log_file"
    elif [[ "$line" == *"sending incremental"* ]]; then
      log "INFO" "$line" "$log_file"
    elif [[ "$line" == *"to-check"* ]]; then
      log "INFO" "$line" "$log_file"
    elif [[ "$line" == *"./"* ]]; then
      # This captures file transfers
      log "FILE" "$line" "$log_file"
    elif [[ "$line" == *"total size"* ]]; then
      log "INFO" "$line" "$log_file"
    elif [[ "$line" == *"error"* ]]; then
      log "ERROR" "$line" "$log_file"
    elif [[ "$line" == *"error"* ]]; then
      log "ERROR" "$line" "$log_file"
      ((failed_count++))  # Increment failed file counter
    elif [[ "$line" == *"./"* ]]; then
      log "FILE" "$line" "$log_file"
      ((file_count++))  # Increment success file counter
    else
      log "PROCESSING" "$line" "$log_file"
    fi
  done &

  exit_code=$?

  # Set rsync_failed=1 if rsync failed
  if [[ $exit_code -ne 0 ]]; then
    rsync_failed=1
    log "ERROR" "Rsync process FAILED with exit code $exit_code" "$log_file"
  fi

  # Push metrics to Prometheus Pushgateway
  push_metrics "sync_files_total" "$file_count" "$job_name"
  push_metrics "failed_files_total" "$failed_count" "$job_name"
  push_metrics "rsync_failed" "$rsync_failed" "$job_name"
  push_metrics "rsync_exit_code" "$exit_code" "$job_name"
  push_error_message "error_message" "$error_msg" "$job_name"

  push_metrics "rsync_active" "0" "$job_name"
  
  # Log that the process is running in background
  log "INFO" "Rsync process started in background for $folder" "$log_file"
done

echo "All rsync processes have been started in background."