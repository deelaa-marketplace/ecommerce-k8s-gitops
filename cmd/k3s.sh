#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default variables with parameterized values
DEFAULT_K3S_VERSION="v1.28.5+k3s1"
DEFAULT_ARGOCD_VERSION="v2.9.3"
DEFAULT_ARGOCD_PORT="8080"
DEFAULT_ARGOCD_NAMESPACE="argocd"
DEFAULT_CLUSTER_NAME="my-k3s-cluster"
DEFAULT_NODE_IP=$(hostname -I | awk '{print $1}')

# Variables that can be overridden by command line options
K3S_VERSION=$DEFAULT_K3S_VERSION
ARGOCD_VERSION=$DEFAULT_ARGOCD_VERSION
ARGOCD_PORT=$DEFAULT_ARGOCD_PORT
ARGOCD_NAMESPACE=$DEFAULT_ARGOCD_NAMESPACE
CLUSTER_NAME=$DEFAULT_CLUSTER_NAME
NODE_IP=$DEFAULT_NODE_IP

# Function to print usage information
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --install               Install K3s cluster and ArgoCD"
    echo "  --uninstall             Uninstall K3s cluster and ArgoCD"
    echo "  --k3s-version=VERSION   K3s version (default: $DEFAULT_K3S_VERSION)"
    echo "  --argocd-version=VER    ArgoCD version (default: $DEFAULT_ARGOCD_VERSION)"
    echo "  --argocd-port=PORT      Port for ArgoCD dashboard (default: $DEFAULT_ARGOCD_PORT)"
    echo "  --argocd-ns=NAMESPACE   Namespace for ArgoCD (default: $DEFAULT_ARGOCD_NAMESPACE)"
    echo "  --cluster-name=NAME     Cluster name (default: $DEFAULT_CLUSTER_NAME)"
    echo "  --node-ip=IP            Node IP address (default: auto-detected)"
    echo "  -h, --help              Show this help message"
    exit 1
}

# Function to parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install)
                OPERATION="install"
                shift
                ;;
            --uninstall)
                OPERATION="uninstall"
                shift
                ;;
            --k3s-version=*)
                K3S_VERSION="${1#*=}"
                shift
                ;;
            --argocd-version=*)
                ARGOCD_VERSION="${1#*=}"
                shift
                ;;
            --argocd-port=*)
                ARGOCD_PORT="${1#*=}"
                shift
                ;;
            --argocd-ns=*)
                ARGOCD_NAMESPACE="${1#*=}"
                shift
                ;;
            --cluster-name=*)
                CLUSTER_NAME="${1#*=}"
                shift
                ;;
            --node-ip=*)
                NODE_IP="${1#*=}"
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                usage
                ;;
        esac
    done

    if [ -z "$OPERATION" ]; then
        echo -e "${RED}Error: Either --install or --uninstall must be specified${NC}"
        usage
    fi
}

# Function to print current configuration
print_config() {
    echo -e "${YELLOW}Current Configuration:${NC}"
    echo "Operation: $OPERATION"
    echo "K3s version: $K3S_VERSION"
    echo "ArgoCD version: $ARGOCD_VERSION"
    echo "ArgoCD port: $ARGOCD_PORT"
    echo "ArgoCD namespace: $ARGOCD_NAMESPACE"
    echo "Cluster name: $CLUSTER_NAME"
    echo "Node IP: $NODE_IP"
    echo ""
}

# Function to confirm before proceeding
confirm() {
    print_config
    read -p "Do you want to proceed with these settings? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}Operation aborted by user${NC}"
        exit 1
    fi
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install K3s
install_k3s() {
    if command_exists k3s; then
        echo -e "${GREEN}K3s is already installed${NC}"
        return
    fi

    echo -e "${YELLOW}Installing K3s...${NC}"
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - \
        --cluster-init \
        --node-ip $NODE_IP \
        --cluster-domain $CLUSTER_NAME.local \
        --write-kubeconfig-mode 644 \
        --disable traefik
    
    # Wait for K3s to be ready
    echo -e "${YELLOW}Waiting for K3s to be ready...${NC}"
    until kubectl get nodes &> /dev/null; do
        sleep 2
    done
    
    # Set up kubectl configuration
    mkdir -p $HOME/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    sed -i "s/127.0.0.1/$NODE_IP/g" $HOME/.kube/config
    
    echo -e "${GREEN}K3s installed successfully${NC}"
}

# Function to install ArgoCD
install_argocd() {
    if kubectl get namespace $ARGOCD_NAMESPACE &> /dev/null; then
        echo -e "${GREEN}ArgoCD is already installed in namespace $ARGOCD_NAMESPACE${NC}"
        return
    fi

    echo -e "${YELLOW}Installing ArgoCD...${NC}"
    kubectl create namespace $ARGOCD_NAMESPACE
    kubectl apply -n $ARGOCD_NAMESPACE -f https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml
    
    # Wait for ArgoCD to be ready
    echo -e "${YELLOW}Waiting for ArgoCD to be ready...${NC}"
    kubectl wait --for=condition=available deployment/argocd-server -n $ARGOCD_NAMESPACE --timeout=300s
    
    # Patch service to use NodePort
    kubectl patch svc argocd-server -n $ARGOCD_NAMESPACE -p '{"spec": {"type": "NodePort", "ports": [{"nodePort": '"$ARGOCD_PORT"', "port": 80, "protocol": "TCP", "targetPort": 8080}]}}'
    
    # Get initial admin password
    ARGOCD_PASSWORD=$(kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    
    echo -e "${GREEN}ArgoCD installed successfully${NC}"
    echo -e "${YELLOW}ArgoCD Dashboard URL: http://$NODE_IP:$ARGOCD_PORT${NC}"
    echo -e "${YELLOW}Username: admin${NC}"
    echo -e "${YELLOW}Password: $ARGOCD_PASSWORD${NC}"
}

# Function to install ArgoCD CLI
install_argocd_cli() {
    if command_exists argocd; then
        echo -e "${GREEN}ArgoCD CLI is already installed${NC}"
        return
    fi

    echo -e "${YELLOW}Installing ArgoCD CLI...${NC}"
    curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/download/$ARGOCD_VERSION/argocd-linux-amd64
    sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
    rm argocd-linux-amd64
    echo -e "${GREEN}ArgoCD CLI installed successfully${NC}"
}

# Function to uninstall K3s and ArgoCD
uninstall_all() {
    echo -e "${YELLOW}Starting uninstallation process...${NC}"
    
    # Delete ArgoCD namespace and resources
    if kubectl get namespace $ARGOCD_NAMESPACE &> /dev/null; then
        echo -e "${YELLOW}Deleting ArgoCD resources...${NC}"
        kubectl delete namespace $ARGOCD_NAMESPACE
    fi
    
    # Uninstall K3s
    if command_exists k3s; then
        echo -e "${YELLOW}Uninstalling K3s...${NC}"
        /usr/local/bin/k3s-uninstall.sh
    fi
    
    # Remove ArgoCD CLI
    if command_exists argocd; then
        echo -e "${YELLOW}Removing ArgoCD CLI...${NC}"
        sudo rm -f /usr/local/bin/argocd
    fi
    
    # Remove configuration files
    echo -e "${YELLOW}Cleaning up configuration files...${NC}"
    rm -rf $HOME/.kube
    rm -rf $HOME/.cache/argocd
    
    echo -e "${GREEN}Uninstallation completed successfully${NC}"
}

# Main function
main() {
    parse_args "$@"
    confirm
    
    case "$OPERATION" in
        install)
            install_k3s
            install_argocd
            install_argocd_cli
            ;;
        uninstall)
            uninstall_all
            ;;
        *)
            echo -e "${RED}Invalid operation${NC}"
            exit 1
            ;;
    esac
    
    echo -e "${GREEN}Operation completed successfully${NC}"
}

# Execute main function
main "$@"