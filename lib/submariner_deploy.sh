#!/bin/bash

# Deploy Submariner addon on the clusterset managed clusters

function get_cluster_credential_name() {
    local cluster
    local platform
    local cluster_creds_name

    cluster="$1"

    platform=$(oc get clusterdeployment -n "$cluster" -o json --no-headers=true \
                 -o custom-columns=PLATFORM:".metadata.labels.hive\.openshift\.io/cluster-platform")
    cluster_creds_name=$(oc get clusterdeployment -n "$cluster" "$cluster" \
                           -o jsonpath={.spec.platform."$platform".credentialsSecretRef.name})
    echo "$cluster_creds_name"
}

# Prepare configuration for managed clusters.
# Create "gateway" instance and open required ports.
function prepare_clusters_for_submariner() {
    INFO "Perform Submariner cloud prepare for the managed clusters"
    local creds

    for cluster in $MANAGED_CLUSTERS; do
        creds=$(get_cluster_credential_name "$cluster")
        INFO "Using $creds credentials for $cluster cluster"
        INFO "Prepare cloud for cluster $cluster"

        CL="$cluster" CRED="$creds" yq eval '.metadata.namespace = env(CL)
            | .spec.credentialsSecret.name = env(CRED)' \
            "$SCRIPT_DIR/resources/submarinerconfig.yaml" | oc apply -f -
    done
}

function deploy_submariner_addon() {
    INFO "Perform deployment of Submariner addon"

    for cluster in $MANAGED_CLUSTERS; do
        INFO "Deploy Submariner addon on cluster - $cluster"

        CL="$cluster" yq eval '.metadata.namespace = env(CL)' \
            "$SCRIPT_DIR/resources/submarineraddon.yaml" | oc apply -f -
    done
}

# The function will check the Submariner addon deployment state
# based on the gived condition value.
# The function will get two arguments:
# 1 - namespace of the managed cluster
# 2 - condition that needs to be checked
function check_submariner_deployment_state() {
    local namespace
    local condition

    namespace=$1
    condition=$2

    oc get managedclusteraddons/submariner -n "$namespace" \
        -o jsonpath='{.status.conditions[?(@.type == "'"$condition"'")].reason}'
}

# The function will wait and check the state of the Submariner services.
# The following services are checked:
# - Submariner Gateway node
# - Submariner Agent
# - Submariner cross cluster connectivity
function wait_for_submariner_ready_state() {
    INFO "Wait for Submariner ready status"
    local wait_timeout
    local timeout
    local cmd_output

    INFO "Check Submariner Gateway node state on clusters"
    wait_timeout=300
    timeout=0
    cmd_output=""
    for cluster in $MANAGED_CLUSTERS; do
        INFO "Checking Submariner Gateway node state on $cluster cluster"
        until [[ "$timeout" -eq "$wait_timeout" ]] || [[ "$cmd_output" == "SubmarinerGatewayNodesLabeled" ]]; do
            INFO "Deploying..."
            cmd_output=$(check_submariner_deployment_state "$cluster" "SubmarinerGatewayNodesLabeled")
            sleep $(( TIMEOUT++ ))
        done
        INFO "Submariner Gateway node has been deployed on $cluster cluster"
    done
    INFO "Submariner Gateway node has been sucesfully deployed on each cluster"

    INFO "Check Submariner Agent state on clusters"
    wait_timeout=300
    timeout=0
    cmd_output=""
    for cluster in $MANAGED_CLUSTERS; do
        INFO "Checking Submariner Agent state on $cluster cluster"
        until [[ "$timeout" -eq "$wait_timeout" ]] || [[ "$cmd_output" == "SubmarinerAgentDeployed" ]]; do
            INFO "Deploying..."
            cmd_output=$(check_submariner_deployment_state "$cluster" "SubmarinerAgentDegraded")
            sleep $(( TIMEOUT++ ))
        done
        INFO "Submariner Agent has been deployed on $cluster cluster"
    done
    INFO "Submariner Agent has been sucesfully deployed on each cluster"

    INFO "Check Submariner connectivity between clusters"
    wait_timeout=300
    timeout=0
    cmd_output=""
    for cluster in $MANAGED_CLUSTERS; do
        INFO "Checking Submariner connectivity on $cluster cluster"
        until [[ "$timeout" -eq "$wait_timeout" ]] || [[ "$cmd_output" == "ConnectionsEstablished" ]]; do
            INFO "Deploying..."
            cmd_output=$(check_submariner_deployment_state "$cluster" "SubmarinerConnectionDegraded")
            sleep $(( TIMEOUT++ ))
        done
        INFO "Submariner connectivity has been established on $cluster cluster"
    done
    INFO "Submariner connectivity have been sucesfully established between clusters"
    INFO "All Submariner services sucesfully running on the clusters"
}
