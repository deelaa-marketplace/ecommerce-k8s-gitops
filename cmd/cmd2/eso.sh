#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default variables
DEFAULT_ESO_VERSION="0.16.1"
DEFAULT_NAMESPACE="default"
DEFAULT_AWS_REGION="eu-west-1"
DEFAULT_SECRET_STORE_NAME="aws-parameter-store"
DEFAULT_SECRET_NAME="aws-parameters"
DEFAULT_AWS_PARAMETER_PREFIX="/app"

# Variables that can be overridden
ESO_VERSION=$DEFAULT_ESO_VERSION
NAMESPACE=$DEFAULT_NAMESPACE
AWS_REGION=$DEFAULT_AWS_REGION
SECRET_STORE_NAME=$DEFAULT_SECRET_STORE_NAME
SECRET_NAME=$DEFAULT_SECRET_NAME
AWS_PARAMETER_PREFIX=$DEFAULT_AWS_PARAMETER_PREFIX
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-""}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-""}"


# Function to print usage information
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --install               Install and configure ESO for AWS Parameter Store"
    echo "  --uninstall             Uninstall ESO and related resources"
    echo "  --eso-version=VERSION   ESO version (default: $DEFAULT_ESO_VERSION)"
    echo "  --namespace=NAMESPACE   Kubernetes namespace (default: $DEFAULT_NAMESPACE)"
    echo "  --region=REGION         AWS region (default: $DEFAULT_AWS_REGION)"
    echo "  --store-name=NAME       SecretStore name (default: $DEFAULT_SECRET_STORE_NAME)"
    echo "  --secret-name=NAME      ExternalSecret name (default: $DEFAULT_SECRET_NAME)"
    echo "  --prefix=PREFIX         AWS Parameter Store prefix (default: $DEFAULT_AWS_PARAMETER_PREFIX)"
    echo "  --access-key=KEY        AWS Access Key ID"
    echo "  --secret-key=KEY        AWS Secret Access Key"
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
            --eso-version=*)
                ESO_VERSION="${1#*=}"
                shift
                ;;
            --namespace=*)
                NAMESPACE="${1#*=}"
                shift
                ;;
            --region=*)
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

    if [ -z "$OPERATION" ]; then
        echo -e "${RED}Error: Either --install or --uninstall must be specified${NC}"
        usage
    fi

    if [ "$OPERATION" == "install" ] && [ -z "$AWS_ACCESS_KEY_ID" ]; then
        echo -e "${YELLOW}AWS Access Key ID not provided. Will attempt to use existing AWS credentials.${NC}"
    fi
}

# Function to print current configuration
print_config() {
    echo -e "${YELLOW}Current Configuration:${NC}"
    echo "Operation: $OPERATION"
    echo "ESO Version: $ESO_VERSION"
    echo "Namespace: $NAMESPACE"
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

# --- Dependency Management ---
install_envsubst() {
  if command -v apt-get &>/dev/null; then
    sudo apt-get update && sudo apt-get install -y gettext-base
  elif command -v yum &>/dev/null; then
    sudo yum install -y gettext
  else
    echo "ERROR: Could not detect package manager (apt/yum)"
    exit 1
  fi
}


# Function to install dependencies
install_dependencies() {
    echo -e "${YELLOW}Checking dependencies...${NC}"
    
    if ! command_exists kubectl; then
        echo -e "${RED}Error: kubectl is not installed${NC}"
        echo "Please install kubectl and ensure it's configured to access your cluster"
        exit 1
    fi

    if ! command -v envsubst &>/dev/null; then
        echo "Installing envsubst..."
        install_envsubst || { echo "envsubst installation failed"; missing=1; }
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
    echo -e "${YELLOW}Installing External Secrets Operator...${NC}"
    
    # Add the External Secrets Helm repository
    helm repo add external-secrets https://charts.external-secrets.io
    helm repo update
    
    # Install the operator
    helm install external-secrets \
        external-secrets/external-secrets \
        -n $NAMESPACE \
        --create-namespace \
        --version $ESO_VERSION
    
    # Wait for the operator to be ready
    echo -e "${YELLOW}Waiting for External Secrets Operator to be ready...${NC}"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=external-secrets -n $NAMESPACE --timeout=300s
    
    echo -e "${GREEN}External Secrets Operator installed successfully${NC}"
}

# Function to configure AWS credentials
configure_aws_credentials() {
    echo -e "${YELLOW}Configuring AWS credentials...${NC}"
    
    # Create Kubernetes secret with AWS credentials if provided
    if [ -n "$AWS_ACCESS_KEY_ID" ]; then
        kubectl create secret generic aws-secret \
            --from-literal=access-key=$AWS_ACCESS_KEY_ID \
            --from-literal=secret-key=$AWS_SECRET_ACCESS_KEY \
            -n $NAMESPACE
    else
        echo -e "${YELLOW}Using existing AWS credentials from environment or IAM role${NC}"
    fi
    
    echo -e "${GREEN}AWS credentials configured${NC}"
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
  namespace: $NAMESPACE
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
  namespace: $NAMESPACE
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
  namespace: $NAMESPACE
spec:
  refreshInterval: 2h
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

# Function to verify installation
verify_installation() {
    echo -e "${YELLOW}Verifying installation...${NC}"
    
    # Check SecretStore status
    echo -e "${YELLOW}SecretStore status:${NC}"
    kubectl get SecretStore $SECRET_STORE_NAME -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
    echo ""
    
    # Check ExternalSecret status
    echo -e "${YELLOW}ExternalSecret status:${NC}"
    kubectl get ExternalSecret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
    echo ""
    
    # Wait for secret to be created
    echo -e "${YELLOW}Waiting for secret to be available...${NC}"
    for i in {1..10}; do
        if kubectl get secret $SECRET_NAME -n $NAMESPACE &> /dev/null; then
            echo -e "${GREEN}Secret successfully created:${NC}"
            kubectl get secret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.data}' | jq
            return
        fi
        sleep 5
    done
    
    echo -e "${RED}Error: Secret not created within expected time${NC}"
    echo -e "${YELLOW}Check the ExternalSecret status with:${NC}"
    echo "kubectl describe externalsecret $SECRET_NAME -n $NAMESPACE"
}

# Function to uninstall ESO
uninstall_eso() {
    echo -e "${YELLOW}Uninstalling External Secrets Operator...${NC}"
    
    # Delete the ExternalSecret
    if kubectl get externalsecret $SECRET_NAME -n $NAMESPACE &> /dev/null; then
        kubectl delete externalsecret $SECRET_NAME -n $NAMESPACE
    fi
    
    # Delete the SecretStore
    if kubectl get secretstore $SECRET_STORE_NAME -n $NAMESPACE &> /dev/null; then
        kubectl delete secretstore $SECRET_STORE_NAME -n $NAMESPACE
    fi
    
    # Delete the AWS credentials secret
    if kubectl get secret aws-secret -n $NAMESPACE &> /dev/null; then
        kubectl delete secret aws-secret -n $NAMESPACE
    fi
    
    # Uninstall the Helm chart
    helm uninstall external-secrets -n $NAMESPACE
    
    # Delete the namespace
    kubectl delete namespace $NAMESPACE
    
    echo -e "${GREEN}External Secrets Operator and related resources uninstalled${NC}"
}

# Main function
main() {
    parse_args "$@"
    confirm
    
    case "$OPERATION" in
        install)
            install_dependencies
            install_eso
            configure_aws_credentials
            create_secret_store
            create_external_secret
            verify_installation
            ;;
        uninstall)
            uninstall_eso
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

# ./script.sh --install \
#     --eso-version=0.9.5 \
#     --namespace=external-secrets \
#     --region=us-west-2 \
#     --store-name=my-aws-store \
#     --secret-name=app-secrets \
#     --prefix=/production/myapp \
#     --access-key=AKIAXXXXXXXXXXXXXXXX \
#     --secret-key=XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX