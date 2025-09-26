#!/bin/bash

# Spot-Aware Scaling Implementation Script
# This script helps you deploy and test the spot-aware scaling solution

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
}

# Function to check prerequisites (simplified)
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Only check permissions - user said they don't need the other validations
    if ! kubectl auth can-i create deployments --all-namespaces &> /dev/null; then
        warning "You may not have sufficient permissions to create deployments"
    fi
    
    success "Prerequisites check passed"
}

# Function to deploy the spot-aware scaler
deploy_scaler() {
    log "Deploying Spot-Aware Scaling Components..."
    
    # Create the spot-scaling namespace
    kubectl apply -f k8s-manifests/spot-scaling-namespace.yaml
    
    # Deploy the configuration first
    kubectl apply -f k8s-manifests/spot-scaler-config.yaml
    
    # Deploy the main scaler (NTH already handles node cordoning)
    kubectl apply -f k8s-manifests/spot-aware-scaler.yaml
    
    # Wait for deployment to be ready
    log "Waiting for Spot-Aware Scaler to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/spot-aware-scaler -n spot-scaling
    
    success "Spot-Aware Scaler deployed successfully in spot-scaling namespace (leveraging existing NTH)"
}

# Function to deploy QA workload
deploy_qa_workload() {
    log "Deploying QA workload..."
    
    # Create namespace first
    kubectl apply -f k8s-manifests/qa-namespace-pdb.yaml
    
    # Deploy the workload
    kubectl apply -f k8s-manifests/qa-workload-deployment.yaml
    
    # Wait for deployment to be ready
    log "Waiting for QA workload to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/qa-workload -n qa
    
    success "QA workload deployed successfully"
}

# Function to add spot-aware label to deployment
add_spot_aware_label() {
    log "Adding spot-aware label to deployment..."
    
    echo ""
    echo "=== Available Deployments ==="
    kubectl get deployments --all-namespaces -o custom-columns=\
NAMESPACE:.metadata.namespace,\
NAME:.metadata.name,\
READY:.status.readyReplicas,\
AGE:.metadata.creationTimestamp --no-headers | head -20
    
    echo ""
    read -p "Enter namespace: " namespace
    read -p "Enter deployment name: " deployment
    
    if ! kubectl get deployment $deployment -n $namespace &> /dev/null; then
        error "Deployment $deployment not found in namespace $namespace"
        return 1
    fi
    
    kubectl label deployment $deployment -n $namespace spot-aware=enabled --overwrite
    
    success "Added spot-aware=enabled label to deployment $deployment in namespace $namespace"
}

# Function to test the setup
test_spot_scaling() {
    log "Testing spot-aware scaling..."
    
    # Get current pod node
    current_node=$(kubectl get pods -n qa -l app=qa-workload -o jsonpath='{.items[0].spec.nodeName}')
    log "QA workload is currently running on node: $current_node"
    
    # Check if it's a spot node
    node_type=$(kubectl get node $current_node -o jsonpath='{.metadata.labels.karpenter\.sh/capacity-type}')
    log "Node type: $node_type"
    
    if [ "$node_type" = "spot" ]; then
        success "Workload is running on a spot node as expected"
    else
        warning "Workload is not on a spot node. You may want to restart the deployment to trigger scheduling on spot nodes."
    fi
    
    # Show current replica count
    replicas=$(kubectl get deployment qa-workload -n qa -o jsonpath='{.spec.replicas}')
    log "Current replica count: $replicas"
    
    success "Test completed. Monitor the logs to see scaling in action during spot interruptions."
}

# Function to monitor scaling events
monitor_scaling() {
    log "Monitoring spot-aware scaling events..."
    
    echo "Watching for scaling events (Ctrl+C to stop):"
    echo "1. Deployment scaling events"
    echo "2. Pod events"
    echo "3. Scaler logs"
    echo ""
    
    # Monitor in parallel
    (
        log "Watching deployment events..."
        kubectl get events -n qa --field-selector involvedObject.name=qa-workload -w
    ) &
    
        (
        log "Watching scaler logs..."
        kubectl logs -f deployment/spot-aware-scaler -n spot-scaling
    ) &    wait
}

# Function to simulate spot interruption (for testing)
simulate_spot_interruption() {
    log "Simulating spot interruption for testing..."
    
    # Get a spot node with test workload
    spot_node=$(kubectl get pods -n test-qa -l app=test-pod -o jsonpath='{.items[0].spec.nodeName}')
    
    if [ -z "$spot_node" ]; then
        error "No test workload pods found in test-qa namespace"
        return 1
    fi
    
    node_type=$(kubectl get node $spot_node -o jsonpath='{.metadata.labels.karpenter\.sh/capacity-type}')
    
    if [ "$node_type" != "spot" ]; then
        warning "Current node is not a spot node. Simulation may not work as expected."
    fi
    
    log "Simulating interruption on node: $spot_node"
    
    # Cordon the node to simulate spot interruption
    kubectl cordon $spot_node
    
    # Create a fake termination event using proper kubectl syntax
    cat <<EOF | kubectl apply -f - || true
apiVersion: v1
kind: Event
metadata:
  name: spot-interruption-test-$(date +%s)
  namespace: test-qa
involvedObject:
  apiVersion: v1
  kind: Node
  name: $spot_node
reason: TerminatingEvictedPod
message: "Simulated spot interruption for testing"
type: Warning
source:
  host: $spot_node
firstTimestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
lastTimestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
count: 1
EOF
    
    log "Simulated spot interruption. Watch for scaling events..."
    log "To clean up: kubectl uncordon $spot_node"
}

# Function to cleanup
cleanup() {
    log "Cleaning up resources..."
    
    kubectl delete -f k8s-manifests/qa-workload-deployment.yaml --ignore-not-found=true
    kubectl delete -f k8s-manifests/spot-aware-scaler.yaml --ignore-not-found=true
    kubectl delete -f k8s-manifests/spot-scaler-config.yaml --ignore-not-found=true
    kubectl delete -f k8s-manifests/qa-namespace-pdb.yaml --ignore-not-found=true
    
    # Note: We don't clean up NTH since it's pre-existing
    log "Note: Node Termination Handler (NTH) left intact as it was pre-existing"
    
    success "Cleanup completed"
}

# Function to verify pod placement and scaling behavior
verify_placement_strategy() {
    log "Verifying pod placement strategy..."
    
    echo ""
    echo "=== Current Pod Status ==="
    kubectl get pods -n qa -l app=qa-workload -o custom-columns=\
NAME:.metadata.name,\
NODE:.spec.nodeName,\
NODE-TYPE:.metadata.annotations.'node\.alpha\.kubernetes\.io/instance-type',\
STATUS:.status.phase,\
READY:.status.conditions[?\(@.type==\"Ready\"\)].status --no-headers 2>/dev/null || \
    kubectl get pods -n qa -l app=qa-workload -o wide
    
    echo ""
    echo "=== Node Capacity Types ==="
    kubectl get nodes -l karpenter.sh/capacity-type -o custom-columns=\
NAME:.metadata.name,\
CAPACITY-TYPE:.metadata.labels.'karpenter\.sh/capacity-type',\
INSTANCE-TYPE:.metadata.labels.'node\.kubernetes\.io/instance-type',\
STATUS:.status.conditions[?\(@.type==\"Ready\"\)].status --no-headers 2>/dev/null || \
    kubectl get nodes --show-labels | grep capacity-type
    
    echo ""
    echo "=== Current Deployment Affinity Rules ==="
    kubectl get deployment qa-workload -n qa -o jsonpath='{.spec.template.spec.affinity}' | jq . 2>/dev/null || \
    echo "No affinity rules currently set"
    
    echo ""
    echo "=== Current Replica Count ==="
    local replicas=$(kubectl get deployment qa-workload -n qa -o jsonpath='{.spec.replicas}')
    local ready_replicas=$(kubectl get deployment qa-workload -n qa -o jsonpath='{.status.readyReplicas}')
    echo "Desired: $replicas, Ready: $ready_replicas"
    
    echo ""
    echo "=== Recent Scaling Events ==="
    kubectl get events -n qa --field-selector involvedObject.name=qa-workload \
        --sort-by='.firstTimestamp' | tail -5 || echo "No recent events found"
    
    success "Placement verification completed"
}

# Function to show real-time scaling behavior
watch_scaling_behavior() {
    log "Starting real-time scaling behavior monitor..."
    
    echo "This will show:"
    echo "1. Pod placement changes"
    echo "2. Node capacity types"
    echo "3. Deployment scaling events"
    echo "4. Scaler controller logs"
    echo ""
    echo "Press Ctrl+C to stop monitoring"
    echo ""
    
    # Create monitoring script
    cat > /tmp/scaling_monitor.sh << 'EOF'
#!/bin/bash
while true; do
    clear
    echo "=== SPOT-AWARE SCALING MONITOR ==="
    echo "Time: $(date)"
    echo ""
    
    echo "🚀 POD STATUS:"
    kubectl get pods -n test-qa -l app=test-pod -o custom-columns=\
NAME:.metadata.name,\
NODE:.spec.nodeName,\
STATUS:.status.phase,\
READY:.status.conditions[?\(@.type==\"Ready\"\)].status --no-headers 2>/dev/null || echo "No pods found"
    
    echo ""
    echo "🏗️  NODE TYPES:"
    kubectl get nodes -l karpenter.sh/capacity-type -o custom-columns=\
NAME:.metadata.name,\
TYPE:.metadata.labels.'karpenter\.sh/capacity-type',\
STATUS:.status.conditions[?\(@.type==\"Ready\"\)].status --no-headers 2>/dev/null || echo "No nodes found"
    
    echo ""
    echo "📊 DEPLOYMENT STATUS:"
    kubectl get deployment test-pod-deployment -n test-qa -o custom-columns=\
NAME:.metadata.name,\
DESIRED:.spec.replicas,\
CURRENT:.status.replicas,\
READY:.status.readyReplicas,\
AVAILABLE:.status.availableReplicas --no-headers 2>/dev/null || echo "Deployment not found"
    
    echo ""
    echo "🔄 RECENT EVENTS (last 3):"
    kubectl get events -n test-qa --field-selector involvedObject.name=test-pod-deployment \
        --sort-by='.firstTimestamp' --no-headers | tail -3 | cut -c1-100 || echo "No events"
    
    echo ""
    echo "🤖 SCALER STATUS:"
    kubectl get pods -n spot-scaling -l app=spot-aware-scaler -o custom-columns=\
NAME:.metadata.name,\
STATUS:.status.phase,\
RESTARTS:.status.containerStatuses[0].restartCount --no-headers 2>/dev/null || echo "Scaler not found"
    
    sleep 5
done
EOF
    
    chmod +x /tmp/scaling_monitor.sh
    /tmp/scaling_monitor.sh
}

# Function to configure namespaces
configure_namespaces() {
    log "Configuring namespace targeting for Spot-Aware Scaler..."
    
    echo ""
    echo "=== Namespace Configuration Options ==="
    echo "1. Whitelist specific namespaces (RECOMMENDED)"
    echo "2. Blacklist specific namespaces"
    echo "3. Monitor all namespaces"
    echo "4. Use existing configuration"
    echo ""
    
    read -p "Choose configuration mode [1-4]: " config_choice
    
    case $config_choice in
        1)
            echo "Enter namespaces to monitor (comma-separated):"
            echo "Example: qa-eagles-1,qa-hot-1,staging"
            read -p "Namespaces: " namespaces
            
            # Update ConfigMap
            kubectl patch configmap spot-aware-scaler-config -n spot-scaling \
                -p '{"data":{"target-namespaces":"'$namespaces'","namespace-mode":"whitelist"}}'
            
            success "Configured to monitor only: $namespaces"
            ;;
        2)
            echo "Enter namespaces to EXCLUDE (comma-separated):"
            echo "Example: kube-system,kube-public,default"
            read -p "Exclude namespaces: " namespaces
            
            kubectl patch configmap spot-aware-scaler-config -n spot-scaling \
                -p '{"data":{"target-namespaces":"'$namespaces'","namespace-mode":"blacklist"}}'
            
            success "Configured to exclude: $namespaces"
            ;;
        3)
            kubectl patch configmap spot-aware-scaler-config -n spot-scaling \
                -p '{"data":{"target-namespaces":"","namespace-mode":"all"}}'
            
            success "Configured to monitor ALL namespaces"
            warning "This will affect all pods with spot-aware=enabled label across all namespaces"
            ;;
        4)
            log "Using existing configuration"
            ;;
        *)
            error "Invalid choice. Using existing configuration."
            ;;
    esac
    
    # Show current configuration
    echo ""
    echo "=== Current Configuration ==="
    kubectl get configmap spot-aware-scaler-config -n spot-scaling -o yaml | grep -A 10 "data:"
}

# Main menu
show_menu() {
    echo ""
    echo "=================== Spot-Aware Scaling Setup ==================="
    echo "1. Check Prerequisites"
    echo "2. Deploy Spot-Aware Scaler"
    echo "3. Deploy Sample QA Workload"
    echo "4. Add spot-aware Label to Existing Deployment"
    echo "5. Test Setup"
    echo "6. Monitor Scaling Events"
    echo "7. Simulate Spot Interruption (Testing)"
    echo "8. Verify Pod Placement Strategy"
    echo "9. Watch Real-time Scaling Behavior"
    echo "10. Configure Target Namespaces"
    echo "11. Deploy All Components (1-3)"
    echo "12. Cleanup"
    echo "0. Exit"
    echo "=============================================================="
}

# Main execution
main() {
    while true; do
        show_menu
        read -p "Enter your choice [0-9]: " choice
        
        case $choice in
            1) check_prerequisites ;;
            2) deploy_scaler ;;
            3) deploy_qa_workload ;;
            4) add_spot_aware_label ;;
            5) test_spot_scaling ;;
            6) monitor_scaling ;;
            7) simulate_spot_interruption ;;
            8) verify_placement_strategy ;;
            9) watch_scaling_behavior ;;
            10) configure_namespaces ;;
            11) 
                check_prerequisites
                deploy_scaler
                deploy_qa_workload
                test_spot_scaling
                ;;
            12) cleanup ;;
            0) 
                log "Exiting..."
                exit 0
                ;;
            *) 
                error "Invalid option. Please try again."
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
