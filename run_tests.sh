#!/bin/bash

MAX_RUNS=500
RESULTS_DIR="test_results"
SUMMARY_FILE="test_results.txt"

# Ensure the results directory exists
mkdir -p "$RESULTS_DIR"

# Initialize the summary file
echo "Test Harness Started at $(date)" > "$SUMMARY_FILE"
echo "Targeting up to $MAX_RUNS runs."

for ((i=1; i<=MAX_RUNS; i++)); do
    RUN_DIR="$RESULTS_DIR/run_${i}"
    mkdir -p "$RUN_DIR"
    RUN_LOG="$RUN_DIR/run_${i}.log"
    START_TIME=$(date +"%Y-%m-%d %H:%M:%S")
    
    echo "==========================================================="
    echo "[$START_TIME] Starting iteration $i / $MAX_RUNS"
    echo "Logs are being captured to: $RUN_LOG"
    
    # Start a background job to periodically capture the CEC config while the test runs
    (
        n=1
        while true; do
            TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
            kubectl get cec -A -o yaml > "$RUN_DIR/cec_capture_${n}_${TIMESTAMP}.yaml" 2>/dev/null
            kubectl get backendtlspolicies,gateways,httproutes,services -A -o yaml > "$RUN_DIR/gwapi_capture_${n}_${TIMESTAMP}.yaml" 2>/dev/null
            n=$((n+1))
            sleep 1
        done
    ) &
    CAPTURE_PID=$!
    
    # Execute the script, capturing stdout and stderr into the log file
    bash start.sh > "$RUN_LOG" 2>&1
    EXIT_CODE=$?
    
    # Stop the background capture
    kill -9 $CAPTURE_PID 2>/dev/null
    wait $CAPTURE_PID 2>/dev/null
    
    # Capture logs from Cilium pods
    echo "Capturing pod logs..."
    for app_label in "k8s-app=cilium" "k8s-app=cilium-envoy" "name=cilium-operator"; do
        for pod in $(kubectl get pods -n kube-system -l "$app_label" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
            kubectl logs -n kube-system "$pod" --all-containers --ignore-errors > "$RUN_DIR/${pod}.log" 2>/dev/null
        done
    done
    
    # Capture all cluster events to see pod scheduling errors or controller warnings
    kubectl get events -A -o wide > "$RUN_DIR/events.log" 2>/dev/null
    
    END_TIME=$(date +"%Y-%m-%d %H:%M:%S")
    
    # Evaluate the result based on the exit code
    if [ $EXIT_CODE -eq 0 ]; then
        RESULT="PASS"
        echo "[$END_TIME] Iteration $i: PASS"
    else
        RESULT="FAIL"
        echo "[$END_TIME] Iteration $i: FAIL (Exit Code: $EXIT_CODE)"
        echo "!!! FLAKE TRIGGERED ON ITERATION $i !!!"
    fi
    
    # Append the result to the summary txt file
    echo "[$END_TIME] Run $i - $RESULT" >> "$SUMMARY_FILE"
    
    # If a failure occurs, we stop the loop so you can manually inspect
    # the failure logs (and cluster if you prefer to comment out the cleanup).
    if [ "$RESULT" == "FAIL" ]; then
        echo "Test failed. Stopping the harness so you can review $RUN_LOG"
        break
    fi

    # Clean up the kind cluster before the next run per requirements
    echo "Cleaning up kind cluster 'chart-testing'..."
    kind delete cluster --name chart-testing
    
    # Explicitly wait to ensure it is fully cleaned up before starting the next run
    while kind get clusters 2>/dev/null | grep -q "^chart-testing$"; do
        echo "Waiting for cluster 'chart-testing' to fully terminate..."
        sleep 5
    done
    
    echo "Cleanup successful. Proceeding..."
done

echo "Test harness has finished."
