#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global configuration
DEFAULT_OPERATION="help"
DEFAULT_VERBOSE=false

# K3s configuration
DEFAULT_K3S_VERSION="v1.32.3+k3s1"
DEFAULT_K3S_NODE_IP=$(hostname -I | awk '{print $1}')
DEFAULT_K3S_CLUSTER_NAME="my-k3s-cluster"

# ESO configuration
DEFAULT_ESO_VERSION="0.9.5"
DEFAULT_ESO_NAMESPACE="external-secrets"
DEFAULT_AWS_REGION="eu-west-1"
DEFAULT_SECRET_STORE_NAME="aws-parameter-store"
DEFAULT_SECRET_NAME="aws-parameters"
DEFAULT_AWS_PARAMETER_PREFIX="/myapp"

# Current configuration
OPERATION=$DEFAULT_OPERATION
VERBOSE=$DEFAULT_VERBOSE

# K3s variables
K3S_VERSION=$DEFAULT_K3S_VERSION
K3S_NODE_IP=$DEFAULT_K3S_NODE_IP
K3S_CLUSTER_NAME=$DEFAULT_K3S_CLUSTER_NAME

# ESO variables
ESO_VERSION=$DEFAULT_ESO_VERSION
ESO_NAMESPACE=$DEFAULT_ESO_NAMESPACE
AWS_REGION=$DEFAULT_AWS_REGION
SECRET_STORE_NAME=$DEFAULT_SECRET_STORE_NAME
SECRET_NAME=$DEFAULT_SECRET_NAME
AWS_PARAMETER_PREFIX=$DEFAULT_AWS_PARAMETER_PREFIX
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-""}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-""}"

# Function to print header
print_header() {
    echo -e "${BLUE}"
    echo "===================================================================="
    echo "$1"
    echo "===================================================================="
    echo -e "${NC}"
}

# Function to print usage information
usage() {
    print_header "DevOps Deployment Script - K3s & External Secrets Operator"
    
    echo "Usage: $0 [options]"
    echo ""
    echo "Global Options:"
    echo "  --install               Install all components (K3s + ESO)"
    echo "  --uninstall             Uninstall all components"
    echo "  --install-k3s           Install only K3s cluster"
    echo "  --uninstall-k3s         Uninstall only K3s cluster"
    echo "  --install-eso           Install only External Secrets Operator"
    echo "  --uninstall-eso         Uninstall only External Secrets Operator"
    echo "  --verbose               Enable verbose output"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "K3s Options:"
    echo "  --k3s-version=VERSION   K3s version (default: $DEFAULT_K3S_VERSION)"
    echo "  --k3s-node-ip=IP        Node IP address (default: auto-detected)"
    echo "  --k3s-cluster-name=NAME Cluster name (default: $DEFAULT_K3S_CLUSTER_NAME)"
    echo ""
    echo "ESO Options:"
    echo "  --eso-version=VERSION   ESO version (default: $DEFAULT_ESO_VERSION)"
    echo "  --eso-namespace=NS      Kubernetes namespace (default: $DEFAULT_ESO_NAMESPACE)"
    echo "  --aws-region=REGION     AWS region (default: $DEFAULT_AWS_REGION)"
    echo "  --store-name=NAME       SecretStore name (default: $DEFAULT_SECRET_STORE_NAME)"
    echo "  --secret-name=NAME      ExternalSecret name (default: $DEFAULT_SECRET_NAME)"
    echo "  --prefix=PREFIX         AWS Parameter Store prefix (default: $DEFAULT_AWS_PARAMETER_PREFIX)"
    echo "  --access-key=KEY        AWS Access Key ID"
    echo "  --secret-key=KEY        AWS Secret Access Key"
    echo ""
    echo "Examples:"
    echo "  # Install everything with default settings"
    echo "  sudo $0 --install"
    echo ""
    echo "  # Install with custom settings"
    echo "  sudo $0 --install \\"
    echo "    --k3s-version=v1.27.3+k3s1 \\"
    echo "    --k3s-cluster-name=prod-cluster \\"
    echo "    --eso-version=0.8.0 \\"
    echo "    --aws-region=us-west-2 \\"
    echo "    --access-key=AKIAXXX \\"
    echo "    --secret-key=XXX"
    echo ""
    echo "  # Uninstall everything"
    echo "  sudo $0 --uninstall"
    exit 1
}

# Function to parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install)
                OPERATION="install-all"
                shift
                ;;
            --uninstall)
                OPERATION="uninstall-all"
                shift
                ;;
            --install-k3s)
                OPERATION="install-k3s"
                shift
                ;;
            --uninstall-k3s)
                OPERATION="uninstall-k3s"
                shift
                ;;
            --install-eso)
                OPERATION="install-eso"
                shift
                ;;
            --uninstall-eso)
                OPERATION="uninstall-eso"
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --k3s-version=*)
                K3S_VERSION="${1#*=}"
                shift
                ;;
            --k3s-node-ip=*)
                K3S_NODE_IP="${1#*=}"
                shift
                ;;
            --k3s-cluster-name=*)
                K3S_CLUSTER_NAME="${1#*=}"
                shift
                ;;
            --eso-version=*)
                ESO_VERSION="${1#*=}"
                shift
                ;;
            --eso-namespace=*)
                ESO_NAMESPACE="${1#*=}"
                shift
                ;;
            --aws-region=*)
                AWS_REGION="${1#*=}"
                shift
                ;;
            --store-name=*)
                SECRET_STORE_NAME="${1#*=}"
                shift
                ;;
            --secret-name=*)
                SECRET_NAME="${1#*=}"
                shift
                ;;
            --prefix=*)
                AWS_PARAMETER_PREFIX="${1#*=}"
                shift
                ;;
            --access-key=*)
                AWS_ACCESS_KEY_ID="${1#*=}"
                shift
                ;;
            --secret-key=*)
                AWS_SECRET_ACCESS_KEY="${1#*=}"
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

    if [ "$OPERATION" == "help" ]; then
        usage
    fi
}

# Function to print current configuration
print_config() {
    print_header "Deployment Configuration"
    
    echo -e "${YELLOW}Operation: ${GREEN}$OPERATION${NC}"
    echo ""
    
    if [[ "$OPERATION" =~ "k3s" ]] || [[ "$OPERATION" == "install-all" ]] || [[ "$OPERATION" == "uninstall-all" ]]; then
        echo -e "${YELLOW}K3s Configuration:${NC}"
        echo "Version: $K3S_VERSION"
        echo "Node IP: $K3S_NODE_IP"
        echo "Cluster Name: $K3S_CLUSTER_NAME"
        echo ""
    fi
    
    if [[ "$OPERATION" =~ "eso" ]] || [[ "$OPERATION" == "install-all" ]] || [[ "$OPERATION" == "uninstall-all" ]]; then
        echo -e "${YELLOW}ESO Configuration:${NC}"
        echo "Version: $ESO_VERSION"
        echo "Namespace: $ESO_NAMESPACE"
        echo "AWS Region: $AWS_REGION"
        echo "SecretStore Name: $SECRET_STORE_NAME"
        echo "ExternalSecret Name: $SECRET_NAME"
        echo "AWS Parameter Prefix: $AWS_PARAMETER_PREFIX"
        
        if [ -n "$AWS_ACCESS_KEY_ID" ]; then
            echo "AWS Access Key ID: [provided]"
            echo "AWS Secret Access Key: [provided]"
        else
            echo "AWS Access Key ID: [will use existing credentials]"
        fi
        echo ""
    fi
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
    print_header "Installing K3s Cluster"
    
    if command_exists k3s; then
        echo -e "${GREEN}K3s is already installed${NC}"
        return
    fi

    echo -e "${YELLOW}Installing K3s version $K3S_VERSION...${NC}"
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - \
        --cluster-init \
        --node-ip $K3S_NODE_IP \
        --cluster-domain $K3S_CLUSTER_NAME.local \
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
    sed -i "s/127.0.0.1/$K3S_NODE_IP/g" $HOME/.kube/config
    
    echo -e "${GREEN}K3s cluster installed successfully${NC}"
    echo -e "${YELLOW}Cluster info:${NC}"
    kubectl cluster-info
}

# Function to uninstall K3s
uninstall_k3s() {
    print_header "Uninstalling K3s Cluster"
    
    if ! command_exists k3s; then
        echo -e "${YELLOW}K3s is not installed${NC}"
        return
    fi

    echo -e "${YELLOW}Uninstalling K3s...${NC}"
    /usr/local/bin/k3s-uninstall.sh
    
    # Clean up configuration files
    echo -e "${YELLOW}Cleaning up configuration files...${NC}"
    rm -rf $HOME/.kube
    
    echo -e "${GREEN}K3s cluster uninstalled successfully${NC}"
}

# Function to install ESO dependencies
install_eso_dependencies() {
    echo -e "${YELLOW}Checking ESO dependencies...${NC}"
    
    if ! command_exists kubectl; then
        echo -e "${RED}Error: kubectl is not installed${NC}"
        echo "Please install kubectl and ensure it's configured to access your cluster"
        exit 1
    fi
    
    if ! command_exists helm; then
        echo -e "${YELLOW}Installing Helm...${NC}"
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        echo -e "${GREEN}Helm installed successfully${NC}"
    else
        echo -e "${GREEN}Helm is already installed${NC}"
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}Error: kubectl is not configured properly or cluster is not accessible${NC}"
        exit 1
    fi
}

# Function to install External Secrets Operator
install_eso() {
    print_header "Installing External Secrets Operator"
    
    install_eso_dependencies

    echo -e "${YELLOW}Installing External Secrets Operator version $ESO_VERSION...${NC}"
    
    # Add the External Secrets Helm repository
    helm repo add external-secrets https://charts.external-secrets.io
    helm repo update
    
    # Create namespace if it doesn't exist
    kubectl create namespace $ESO_NAMESPACE 2>/dev/null || true
    
    # Install the operator
    helm install external-secrets \
        external-secrets/external-secrets \
        -n $ESO_NAMESPACE \
        --version $ESO_VERSION
    
    # Wait for the operator to be ready
    echo -e "${YELLOW}Waiting for External Secrets Operator to be ready...${NC}"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=external-secrets -n $ESO_NAMESPACE --timeout=300s
    
    echo -e "${GREEN}External Secrets Operator installed successfully${NC}"
}

# Function to configure AWS credentials for ESO
configure_aws_credentials() {
    echo -e "${YELLOW}Configuring AWS credentials for ESO...${NC}"
    
    # Create Kubernetes secret with AWS credentials if provided
    if [ -n "$AWS_ACCESS_KEY_ID" ]; then
        kubectl create secret generic aws-secret \
            --from-literal=access-key=$AWS_ACCESS_KEY_ID \
            --from-literal=secret-key=$AWS_SECRET_ACCESS_KEY \
            -n $ESO_NAMESPACE
    else
        echo -e "${YELLOW}Using existing AWS credentials from environment or IAM role${NC}"
    fi
}

# Function to create SecretStore
create_secret_store() {
    echo -e "${YELLOW}Creating SecretStore resource...${NC}"
    
    if [ -n "$AWS_ACCESS_KEY_ID" ]; then
        # SecretStore with explicit credentials
        cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: $SECRET_STORE_NAME
  namespace: $ESO_NAMESPACE
spec:
  provider:
    aws:
      service: ParameterStore
      region: $AWS_REGION
      auth:
        secretRef:
          accessKeyIDSecretRef:
            name: aws-secret
            key: access-key
          secretAccessKeySecretRef:
            name: aws-secret
            key: secret-key
EOF
    else
        # SecretStore using ambient credentials (IAM role)
        cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: $SECRET_STORE_NAME
  namespace: $ESO_NAMESPACE
spec:
  provider:
    aws:
      service: ParameterStore
      region: $AWS_REGION
EOF
    fi
    
    echo -e "${GREEN}SecretStore created successfully${NC}"
}

# Function to create ExternalSecret
create_external_secret() {
    echo -e "${YELLOW}Creating ExternalSecret resource...${NC}"
    
    cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: $SECRET_NAME
  namespace: $ESO_NAMESPACE
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: $SECRET_STORE_NAME
    kind: SecretStore
  target:
    name: $SECRET_NAME
  dataFrom:
  - extract:
      key: $AWS_PARAMETER_PREFIX
EOF
    
    echo -e "${GREEN}ExternalSecret created successfully${NC}"
    echo -e "${YELLOW}Secrets will be synchronized from AWS Parameter Store under prefix: $AWS_PARAMETER_PREFIX${NC}"
}

# Function to verify ESO installation
verify_eso_installation() {
    echo -e "${YELLOW}Verifying ESO installation...${NC}"
    
    # Check SecretStore status
    echo -e "${YELLOW}SecretStore status:${NC}"
    kubectl get SecretStore $SECRET_STORE_NAME -n $ESO_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
    echo ""
    
    # Check ExternalSecret status
    echo -e "${YELLOW}ExternalSecret status:${NC}"
    kubectl get ExternalSecret $SECRET_NAME -n $ESO_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
    echo ""
    
    # Wait for secret to be created
    echo -e "${YELLOW}Waiting for secret to be available...${NC}"
    for i in {1..10}; do
        if kubectl get secret $SECRET_NAME -n $ESO_NAMESPACE &> /dev/null; then
            echo -e "${GREEN}Secret successfully created:${NC}"
            kubectl get secret $SECRET_NAME -n $ESO_NAMESPACE -o jsonpath='{.data}' | jq
            return
        fi
        sleep 5
    done
    
    echo -e "${RED}Error: Secret not created within expected time${NC}"
    echo -e "${YELLOW}Check the ExternalSecret status with:${NC}"
    echo "kubectl describe externalsecret $SECRET_NAME -n $ESO_NAMESPACE"
}

# Function to uninstall ESO
uninstall_eso() {
    print_header "Uninstalling External Secrets Operator"
    
    # Delete the ExternalSecret
    if kubectl get externalsecret $SECRET_NAME -n $ESO_NAMESPACE &> /dev/null; then
        kubectl delete externalsecret $SECRET_NAME -n $ESO_NAMESPACE
    fi
    
    # Delete the SecretStore
    if kubectl get secretstore $SECRET_STORE_NAME -n $ESO_NAMESPACE &> /dev/null; then
        kubectl delete secretstore $SECRET_STORE_NAME -n $ESO_NAMESPACE
    fi
    
    # Delete the AWS credentials secret
    if kubectl get secret aws-secret -n $ESO_NAMESPACE &> /dev/null; then
        kubectl delete secret aws-secret -n $ESO_NAMESPACE
    fi
    
    # Uninstall the Helm chart
    helm uninstall external-secrets -n $ESO_NAMESPACE
    
    # Delete the namespace
    kubectl delete namespace $ESO_NAMESPACE
    
    echo -e "${GREEN}External Secrets Operator and related resources uninstalled${NC}"
}

# Main function
main() {
    parse_args "$@"
    
    if [ "$OPERATION" != "help" ]; then
        confirm
    fi
    
    case "$OPERATION" in
        "install-all")
            install_k3s
            install_eso
            configure_aws_credentials
            create_secret_store
            create_external_secret
            verify_eso_installation
            ;;
        "uninstall-all")
            uninstall_eso
            uninstall_k3s
            ;;
        "install-k3s")
            install_k3s
            ;;
        "uninstall-k3s")
            uninstall_k3s
            ;;
        "install-eso")
            install_eso
            configure_aws_credentials
            create_secret_store
            create_external_secret
            verify_eso_installation
            ;;
        "uninstall-eso")
            uninstall_eso
            ;;
        "help")
            usage
            ;;
        *)
            echo -e "${RED}Invalid operation${NC}"
            usage
            ;;
    esac
    
    print_header "Operation Completed"
    echo -e "${GREEN}Successfully executed operation: $OPERATION${NC}"
}

# Execute main function
main "$@"