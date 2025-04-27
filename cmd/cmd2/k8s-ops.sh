#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default variables with parameterized values
DEFAULT_K8S_VERSION="1.28"
DEFAULT_ARGOCD_VERSION="v2.9.3"
DEFAULT_ARGOCD_PORT="8080"
DEFAULT_ARGOCD_NAMESPACE="argocd"
DEFAULT_CLUSTER_NAME="my-cluster"
DEFAULT_NODE_IP=$(hostname -I | awk '{print $1}')

# Variables that can be overridden by command line options
K8S_VERSION=$DEFAULT_K8S_VERSION
ARGOCD_VERSION=$DEFAULT_ARGOCD_VERSION
ARGOCD_PORT=$DEFAULT_ARGOCD_PORT
ARGOCD_NAMESPACE=$DEFAULT_ARGOCD_NAMESPACE
CLUSTER_NAME=$DEFAULT_CLUSTER_NAME
NODE_IP=$DEFAULT_NODE_IP

# Function to print usage information
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --install               Install Kubernetes cluster and ArgoCD"
    echo "  --uninstall             Uninstall Kubernetes cluster and ArgoCD"
    echo "  --k8s-version=VERSION   Kubernetes version (default: $DEFAULT_K8S_VERSION)"
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
            --k8s-version=*)
                K8S_VERSION="${1#*=}"
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
    echo "Kubernetes version: $K8S_VERSION"
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

# Function to install required dependencies
install_dependencies() {
    echo -e "${YELLOW}Installing dependencies...${NC}"
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
}

# Function to install Docker
install_docker() {
    if command_exists docker; then
        echo -e "${GREEN}Docker is already installed${NC}"
        return
    fi

    echo -e "${YELLOW}Installing Docker...${NC}"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io

    # Configure Docker to use systemd as the cgroup driver
    sudo mkdir -p /etc/docker
    cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

    sudo systemctl enable docker
    sudo systemctl restart docker
    sudo usermod -aG docker $USER
    echo -e "${GREEN}Docker installed successfully${NC}"
}

# Function to install kubeadm, kubelet and kubectl
install_kube_tools() {
    if command_exists kubeadm && command_exists kubectl && command_exists kubelet; then
        echo -e "${GREEN}Kubernetes tools are already installed${NC}"
        return
    fi

    echo -e "${YELLOW}Installing Kubernetes tools...${NC}"
    sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
    echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo apt-get update
    sudo apt-get install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
    echo -e "${GREEN}Kubernetes tools installed successfully${NC}"
}

# Function to initialize Kubernetes cluster
init_k8s_cluster() {
    if kubectl cluster-info &> /dev/null; then
        echo -e "${GREEN}Kubernetes cluster is already initialized${NC}"
        return
    fi

    echo -e "${YELLOW}Initializing Kubernetes cluster...${NC}"
    sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$K8S_VERSION --control-plane-endpoint=$NODE_IP
    
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    
    # Install Flannel network plugin
    kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
    
    echo -e "${GREEN}Kubernetes cluster initialized successfully${NC}"
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

# Function to uninstall Kubernetes and ArgoCD
uninstall_all() {
    echo -e "${YELLOW}Starting uninstallation process...${NC}"
    
    # Delete ArgoCD namespace and resources
    if kubectl get namespace $ARGOCD_NAMESPACE &> /dev/null; then
        echo -e "${YELLOW}Deleting ArgoCD resources...${NC}"
        kubectl delete namespace $ARGOCD_NAMESPACE
    fi
    
    # Reset Kubernetes cluster
    if command_exists kubeadm; then
        echo -e "${YELLOW}Resetting Kubernetes cluster...${NC}"
        sudo kubeadm reset --force
    fi
    
    # Remove Kubernetes packages
    echo -e "${YELLOW}Removing Kubernetes packages...${NC}"
    sudo apt-get purge -y kubeadm kubectl kubelet kubernetes-cni
    sudo apt-get autoremove -y
    
    # Remove Docker
    echo -e "${YELLOW}Removing Docker...${NC}"
    sudo apt-get purge -y docker-ce docker-ce-cli containerd.io
    sudo rm -rf /var/lib/docker
    sudo rm -rf /etc/docker
    
    # Remove configuration files
    echo -e "${YELLOW}Cleaning up configuration files...${NC}"
    rm -rf $HOME/.kube
    sudo rm -rf /etc/kubernetes
    
    # Remove ArgoCD CLI
    if command_exists argocd; then
        echo -e "${YELLOW}Removing ArgoCD CLI...${NC}"
        sudo rm -f /usr/local/bin/argocd
    fi
    
    echo -e "${GREEN}Uninstallation completed successfully${NC}"
}

# Main function
main() {
    parse_args "$@"
    confirm
    
    case "$OPERATION" in
        install)
            install_dependencies
            install_docker
            install_kube_tools
            init_k8s_cluster
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

#sudo ./script.sh --install --k8s-version=1.28 --argocd-version=v2.9.3 --argocd-port=8080 --argocd-ns=argocd --cluster-name=my-cluster --node-ip=192.168.1.100