#!/bin/bash

echo "Waiting for iperf3 test pods to spin up in the default namespace..."
oc wait --for=condition=Ready pod -l app=iperf3-server -n default --timeout=60s
oc wait --for=condition=Ready pod -l app=iperf3-client -n default --timeout=60s

# FIXED: Removed jsonpath completely. Uses standard columns to stay immune to Windows shell parsing.
SERVER_POD=$(oc get pods -l app=iperf3-server -n default --no-headers | awk '{print $1}')
CLIENT_POD=$(oc get pods -l app=iperf3-client -n default --no-headers | awk '{print $1}')

# Retrieve IP and Node configurations using wide output formatting
SERVER_IP=$(oc get pod "$SERVER_POD" -n default -o wide --no-headers | awk '{print $6}')
SERVER_NODE=$(oc get pod "$SERVER_POD" -n default -o wide --no-headers | awk '{print $7}')
CLIENT_NODE=$(oc get pod "$CLIENT_POD" -n default -o wide --no-headers | awk '{print $7}')

echo "=========================================================="
echo "Server Pod: $SERVER_POD (Node: $SERVER_NODE) [Namespace: default]"
echo "Client Pod: $CLIENT_POD (Node: $CLIENT_NODE) [Namespace: default]"
echo "=========================================================="
echo ""

echo "----------------------------------------------------------"
echo "RUNNING BENCHMARK 1: Standard Frame (1500 MTU / 1360 MSS / 4 Streams)"
echo "----------------------------------------------------------"
# Start background CPU tracker using Debian/Ubuntu top flags
oc exec "$CLIENT_POD" -n default -- top -b -d 1 -n 12 > /tmp/cpu_1500.txt &
TRACKER_PID=$!

# Execute iperf and log output to extract total speed
oc exec "$CLIENT_POD" -n default -- iperf3 -c "$SERVER_IP" -t 10 -M 1360 -P 4 > /tmp/iperf_1500.txt
cat /tmp/iperf_1500.txt

wait $TRACKER_PID 2>/dev/null
echo ""
echo ">>> Avg CPU Idle during 1500 MTU test (Lower % means higher CPU load):"
CPU_IDLE_1500=$(grep "%Cpu(s)" /tmp/cpu_1500.txt | awk '{print $8}' | awk '{sum+=$1} END {if (NR>0) print sum/NR; else print 0}')
echo "${CPU_IDLE_1500}% Idle"

# Extract final aggregate speed for 1500 MTU
SPEED_1500=$(grep "SUM" /tmp/iperf_1500.txt | grep "receiver" | awk '{print $6}')
if [ -z "$SPEED_1500" ]; then SPEED_1500=$(grep "SUM" /tmp/iperf_1500.txt | tail -n 1 | awk '{print $6}'); fi

echo ""
echo "----------------------------------------------------------"
echo "RUNNING BENCHMARK 2: Jumbo Frame (9000 MTU / 8860 MSS / 4 Streams)"
echo "----------------------------------------------------------"
# Start background CPU tracker for the jumbo frame run
oc exec "$CLIENT_POD" -n default -- top -b -d 1 -n 12 > /tmp/cpu_9000.txt &
TRACKER_PID=$!

# Execute iperf and log output to extract total speed
oc exec "$CLIENT_POD" -n default -- iperf3 -c "$SERVER_IP" -t 10 -M 8860 -P 4 > /tmp/iperf_9000.txt
cat /tmp/iperf_9000.txt

wait $TRACKER_PID 2>/dev/null
echo ""
echo ">>> Avg CPU Idle during 9000 MTU test (Higher % means less CPU strain):"
CPU_IDLE_9000=$(grep "%Cpu(s)" /tmp/cpu_9000.txt | awk '{print $8}' | awk '{sum+=$1} END {if (NR>0) print sum/NR; else print 0}')
echo "${CPU_IDLE_9000}% Idle"

# Extract final aggregate speed for 9000 MTU
SPEED_9000=$(grep "SUM" /tmp/iperf_9000.txt | grep "receiver" | awk '{print $6}')
if [ -z "$SPEED_9000" ]; then SPEED_9000=$(grep "SUM" /tmp/iperf_9000.txt | tail -n 1 | awk '{print $6}'); fi

rm -f /tmp/cpu_1500.txt /tmp/cpu_9000.txt /tmp/iperf_1500.txt /tmp/iperf_9000.txt

echo ""
echo "=========================================================="
echo "           CPU PERFORMANCE COMPARISON SUMMARY            "
echo "=========================================================="
awk -v idle1500="$CPU_IDLE_1500" -v idle9000="$CPU_IDLE_9000" '
BEGIN {
    if (idle1500 > 0 && idle9000 > 0) {
        load1500 = 100 - idle1500;
        load9000 = 100 - idle9000;
        savings  = load1500 - load9000;

        printf "â€¢ 1500 MTU Active CPU Consumption: %.2f%%\n", load1500;
        printf "â€¢ 9000 MTU Active CPU Consumption: %.2f%%\n", load9000;
        printf "â€¢ Total CPU Overhead Reduction:    %.2f%% less CPU load with Jumbo Frames!\n", savings;
    } else {
        print "Could not generate comparison: Missing valid CPU log calculations.";
    }
}'
echo "=========================================================="

echo ""
echo "=========================================================="
echo "          NETWORK THROUGHPUT COMPARISON SUMMARY           "
echo "=========================================================="
awk -v sp1500="$SPEED_1500" -v sp9000="$SPEED_9000" '
BEGIN {
    if (sp1500 > 0 && sp9000 > 0) {
        gain_abs = sp9000 - sp1500;
        gain_pct = (gain_abs / sp1500) * 100;

        printf "â€¢ 1500 MTU Aggregate Speed:        %.2f Gbps\n", sp1500;
        printf "â€¢ 9000 MTU Aggregate Speed:        %.2f Gbps\n", sp9000;
        printf "â€¢ Total Network Performance Gain: +%.2f Gbps (+%.1f%% throughput improvement!)\n", gain_abs, gain_pct;
    } else {
        print "Could not generate comparison: Missing valid iperf bandwidth output.";
    }
}'
echo "=========================================================="

echo "Press [ENTER] to exit and close this window..."
read -r