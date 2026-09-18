#!/bin/bash

# 1. Wait for pods to be ready
echo "Waiting for test pods to be running..."
oc wait --for=condition=Ready pod -l app=mtu-test --timeout=60s

# 2. Extract Pod Names and IPs
POD_A=$(oc get pods -l app=mtu-test -o jsonpath='{.items[0].metadata.name}')
POD_B=$(oc get pods -l app=mtu-test -o jsonpath='{.items[1].metadata.name}')
POD_B_IP=$(oc get pod $POD_B -o jsonpath='{.status.podIP}')

NODE_A=$(oc get pod $POD_A -o jsonpath='{.spec.nodeName}')
NODE_B=$(oc get pod $POD_B -o jsonpath='{.spec.nodeName}')

echo "=========================================================="
echo "Source Pod:      $POD_A (on Node: $NODE_A)"
echo "Destination IP:  $POD_B_IP ($POD_B on Node: $NODE_B)"
echo "Executing:       ping -s 9000 $POD_B_IP"
echo "Press [Ctrl + C] at any time to stop the test."
echo "=========================================================="
echo ""

# 3. Execute the indefinite 9000 payload ping
oc exec $POD_A -it -- ping -s 9000 $POD_B_IP