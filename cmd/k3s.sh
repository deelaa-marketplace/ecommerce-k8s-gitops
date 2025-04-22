#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default variables with parameterized values
DEFAULT_K3S_VERSION="v1.32.3+k3s1"
DEFAULT_ARGOCD_VERSION="v2.14.10"
DEFAULT_ARGOCD_PORT="80"
DEFAULT_ARGOCD_NAMESPACE="argocd"
DEFAULT_CLUSTER_NAME="development"
DEFAULT_ESO_VERSION="0.16.1"
DEFAULT_ESO_NAME="external-secrets"
DEFAULT_ESO_NAMESPACE="external-secrets"

# Variables that can be overridden by command line options
K3S_VERSION=$DEFAULT_K3S_VERSION
CLUSTER_NAME=$DEFAULT_CLUSTER_NAME
NODE_IP=""
# ArgoCD variables
ARGOCD_VERSION=$DEFAULT_ARGOCD_VERSION
ARGOCD_NAME="argocd"
ARGOCD_PORT=$DEFAULT_ARGOCD_PORT
ARGOCD_NAMESPACE=$DEFAULT_ARGOCD_NAMESPACE
SKIP_ARGOCD="false"
# ESO variables
ESO_VERSION=$DEFAULT_ESO_VERSION
ESO_NAME=$DEFAULT_ESO_NAME
ESO_NAMESPACE=$DEFAULT_ESO_NAMESPACE
SKIP_ESO="false"

# Function to print usage information
usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  install                 Install K3s cluster and ArgoCD and ESO"
  echo "  uninstall               Uninstall K3s cluster and ArgoCD and ESO"
  echo "  --k3s-version=VERSION   K3s version (default: $DEFAULT_K3S_VERSION)"
  echo "  --cluster-name=NAME     Cluster name (default: $DEFAULT_CLUSTER_NAME)"
  echo "  --node-ip=IP            Node IP address (default: auto-detected)"
  echo "  --argocd-version=VER    ArgoCD version (default: $DEFAULT_ARGOCD_VERSION)"
  echo "  --argocd-port=PORT      Port for ArgoCD dashboard (default: $DEFAULT_ARGOCD_PORT for LoadBalance or NodePort range is 30000-32767)"
  echo "  --argocd-ns=NAMESPACE   Namespace for ArgoCD (default: $DEFAULT_ARGOCD_NAMESPACE)"
  echo "  --skip-argocd           Skip ArgoCD installation (default: $SKIP_ARGOCD)"
  echo "  --eso-version=VERSION   External Secrets Operator version (default: $DEFAULT_ESO_VERSION)"
  echo "  --eso-name=NAME         Name for External Secrets Operator (default: $DEFAULT_ESO_NAME)"
  echo "  --eso-ns=NAMESPACE      Namespace for External Secrets Operator (default: $DEFAULT_ESO_NAMESPACE)"
  echo "  --skip-eso              Skip External Secrets Operator installation (default: $SKIP_ESO)"
  echo "  -h, --help              Show this help message"
  exit 1
}

function get_preferred_ip() {

  # Get all IPs from hostname -I
  local ips=($(hostname -I))

  # Define public IP pattern (modify if needed)
  local public_ip=""

  for ip in "${ips[@]}"; do
    # Check if IP is a public address (non-private range)
    if [[ ! "$ip" =~ ^(10\.|192\.168\.|172\.16\.) ]]; then
      public_ip="$ip"
      break
    fi
  done

  # Default to the first IP if no public IP was found
  public_ip="${public_ip:-${ips[0]}}"

  echo "Selected IP: $public_ip"
}

function get_chart_version_for_app_version() {
  local chart_name="$1"
  local target_app_version="$2"

  # Get newest chart version matching the app version (sorted by semver)
  local chart_version
  chart_version=$(helm search repo "$chart_name" --versions --output json 2>/dev/null |
    jq -r --arg av "$target_app_version" '
            [.[] | select(.app_version == $av) |
            {version: .version, chunks: (.version | split(".") | map(tonumber))}] |
            sort_by(.chunks) |
            reverse |
            .[0].version // empty
        ')

  if [ -z "$chart_version" ]; then
    echo "ERROR: No chart version found for app version '$target_app_version'" >&2
    return 1
  fi

  echo "$chart_version"
}

function get_app_version_for_chart_version() {
  local chart_name="$1"
  local target_chart_version="$2"

  # Get versions and sort by app_version (newest first)
  local app_version
  app_version=$(helm search repo "$chart_name" --versions --output json 2>/dev/null |
    jq -r --arg chart_ver "$target_chart_version" '
            [.[] | select(.version == $chart_ver) | .app_version] |
            sort_by(. | sub("^v"; "") | split(".") | map(tonumber)) |
            reverse | .[0] // empty
        ')

  if [ -z "$app_version" ]; then
    echo "ERROR: No app versions found for chart version '$target_chart_version'" >&2
    return 1
  fi

  echo "$app_version"
}

# Function to check and modify the string
to_v_prefix() {
  [[ "$1" == v* ]] && echo "$1" || echo "v$1"
}
# Function to parse command line arguments
parse_args() {
  if [[ $# -lt 1 ]]; then
    usage
  fi

  OPERATION=$1
  shift

  if [[ "$OPERATION" != "install" ]] && [[ "$OPERATION" != "uninstall" ]]; then
    echo "Invalid operation: $OPERATION"
    usage
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --k3s-version=*)
      K3S_VERSION="${1#*=}"
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
    --skip-argocd)
      SKIP_ARGOCD="true"
      shift
      ;;
    --eso-version=*)
      ESO_VERSION="${1#*=}"
      shift
      ;;
    --eso-name=*)
      ESO_NAME="${1#*=}"
      shift
      ;;
    --eso-ns=*)
      ESO_NAMESPACE="${1#*=}"
      shift
      ;;
    --skip-eso)
      SKIP_ESO="true"
      shift
      ;;

    -h | --help)
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

  # convert to v prefix

  ARGOCD_VERSION=$(to_v_prefix "$ARGOCD_VERSION")
  ESO_VERSION=$(to_v_prefix "$ESO_VERSION")

  if [[ ! "$ARGOCD_PORT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: ArgoCD port must be a number${NC}"
    usage
  fi

  if [ -z "$NODE_IP" ]; then
    NODE_IP=$(get_preferred_ip)
    echo -e "${YELLOW}Node IP: Auto-detected as $NODE_IP${NC}"
    # Check if the first IP is a valid IPv4 address
    if [[ ! "${NODE_IP}" ]]; then
      echo -e "${YELLOW}Node IP: Unable to auto-detect a valid IP address. Specify using --node-ip${NC}"
      usage
    fi
  fi
}

# Function to print current configuration
print_config() {
  echo -e "${YELLOW}Current Configuration:${NC}"
  echo -e "${YELLOW}K3s Version: ${GREEN}$K3S_VERSION${NC}"
  echo -e "${YELLOW}Cluster Name: ${GREEN}$CLUSTER_NAME${NC}"
  echo -e "${YELLOW}Node IP: ${GREEN}$NODE_IP${NC}"
  echo -e "${YELLOW}ArgoCD Version: ${GREEN}$ARGOCD_VERSION${NC}"
  echo -e "${YELLOW}ArgoCD Port: ${GREEN}$ARGOCD_PORT${NC}"
  echo -e "${YELLOW}ArgoCD Namespace: ${GREEN}$ARGOCD_NAMESPACE${NC}"
  echo -e "${YELLOW}Skip ArgoCD: ${GREEN}$SKIP_ARGOCD${NC}"
  echo -e "${YELLOW}ESO Version: ${GREEN}$ESO_VERSION${NC}"
  echo -e "${YELLOW}ESO Name: ${GREEN}$ESO_NAME${NC}"
  echo -e "${YELLOW}ESO Namespace: ${GREEN}$ESO_NAMESPACE${NC}"
  echo -e "${YELLOW}Skip ESO: ${GREEN}$SKIP_ESO${NC}"
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

# Generic function to detect a Kubernetes operator in a specific namespace
# Usage: is_operator_installed <namespace> <operator_name> <deployment_label>
function is_operator_installed() {
  local namespace="$1"
  local operator_name="$2"
  local deployment_label="$3"

  echo -e "${YELLOW}Checking for ${operator_name} in namespace '$namespace'...${NC}"

  # Check if namespace exists
  if ! kubectl get ns "${namespace}" &>/dev/null; then
    echo -e "${YELLOW}Namespace '${namespace}' does not exist..${NC}"
    #kubectl create namespace $namespace
    return 1
  fi

  # Check for deployment with the specified label
  if kubectl get deployments -n "${namespace}" -l "$deployment_label" &>/dev/null; then
    echo -e "${GREEN}${operator_name} deployment found (label: ${deployment_label}) in namespace '${namespace}'${NC}"
    return 0
  fi

  return 1
}

is_crd_installed() {
  local crd_name="$1"
  if kubectl get crd "$crd_name" &>/dev/null; then
    echo -e "✅ ${GREEN}${crd_name} CRD is already installed${NC}"
    return 0
  else
    echo -e "${YELLOW}${crd_name} CRD not found${NC}"
    return 1
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
    --node-ip "$NODE_IP" \
    --cluster-domain "$CLUSTER_NAME".local \
    --write-kubeconfig-mode 644 \
    --disable traefik

  # Wait for K3s to be ready
  echo -e "${YELLOW}Waiting for K3s to be ready...${NC}"
  until kubectl get nodes &>/dev/null; do
    sleep 2
  done

  # Set up kubectl configuration
  mkdir -p "$HOME"/.kube
  sudo cp /etc/rancher/k3s/k3s.yaml "$HOME"/.kube/config
  sudo chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config
  sed -i "s/127.0.0.1/$NODE_IP/g" "$HOME"/.kube/config

  echo -e "${GREEN}K3s installed successfully${NC}"
}

install_argocd() {
  if [[ "$SKIP_ARGOCD" == "true" ]]; then
    echo -e "${YELLOW}Skipping ArgoCD installation...${NC}"
    return
  fi
  # Check if the operator is already installed
  is_operator_installed "$ARGOCD_NAMESPACE" "ArgoCD" "app.kubernetes.io/name=argocd-server"
  local is_upgrade=$?

  if [[ $is_upgrade -eq 0 ]]; then
    echo -e "${GREEN}Detected an existing ArgoCD in cluster namespace. Will try upgrade${NC}"
  fi
  # Check if ArgoCD CRD is already installed in another cluster
  if [[ $is_upgrade -ne 0 ]] && is_crd_installed "applications.argoproj.io"; then
    echo -e "${GREEN}ArgoCD is already installed. Only one instance is allowed per cluster${NC}"
    return
  fi

  # Determine the type of service to use
  local argocd_type="LoadBalancer"
  if [[ "$ARGOCD_PORT" -ge 30000 && "$ARGOCD_PORT" -le 32767 ]]; then
    echo -e "${GREEN}ArgoCD port is valid and within range for NodePort!. Defaulting to NodePort${NC}"
    argocd_type="NodePort"
  fi

  # Determine the operation (install or upgrade)
  if [[ $is_upgrade -eq 0 ]]; then
    echo -e "${YELLOW}Upgrading ArgoCD to $argocd_type...${NC}"
  else
    echo -e "${YELLOW}Installing ArgoCD to $argocd_type...${NC}"
  fi
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update
  local chat_version
  if ! chat_version=$(get_chart_version_for_app_version "argo/argo-cd" "$ARGOCD_VERSION"); then
    echo -e "${RED}Error: Unable to find chart version for ArgoCD version $ARGOCD_VERSION${NC}"
    return
  fi

  if [[ "$argocd_type" == "NodePort" ]]; then
    helm upgrade --install "$ARGOCD_NAME" argo/argo-cd \
      --namespace "$ARGOCD_NAMESPACE" \
      --version "$chat_version" \
      --create-namespace \
      --set server.service.type=$argocd_type \
      --set server.service.nodePort="$ARGOCD_PORT"
  else
    helm upgrade --install "$ARGOCD_NAME" argo/argo-cd \
      --namespace "$ARGOCD_NAMESPACE" \
      --version "$chat_version" \
      --create-namespace \
      --set server.service.type=$argocd_type \
      --set server.service.port="$ARGOCD_PORT"
  fi

  local installed=$?
  if [[ "$installed" -ne 0 ]]; then
    echo -e "${RED}Error installing ArgoCD${NC}"
    return
  fi

  # Wait for ArgoCD to be ready
  echo -e "${YELLOW}Waiting for ArgoCD to be ready...${NC}"
  kubectl wait --for=condition=available deployment/argocd-server -n "$ARGOCD_NAMESPACE" --timeout=300s

  # Get initial admin password
  ARGOCD_PASSWORD=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

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
  curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/download/"$ARGOCD_VERSION"/argocd-linux-amd64
  sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
  rm argocd-linux-amd64
  echo -e "${GREEN}ArgoCD CLI installed successfully${NC}"
}

# Function to install External Secrets Operator
install_eso() {
  if [[ ${SKIP_ESO} == "true" ]]; then
    echo -e "${YELLOW}Skipping External Secrets Operator installation...${NC}"
    return
  fi

  # Check if the operator is already installed
  local is_upgrade
  is_upgrade=$(is_operator_installed "$ESO_NAMESPACE" "ESO" "app.kubernetes.io/name=${ESO_NAME}")

  if [[ "$is_upgrade" -eq 0 ]]; then
    echo -e "${GREEN}Detected an existing ESO in cluster namespace. Will try an upgrade${NC}"
  fi

  # Check if CRD is already installed
  # local installCRD = is_crd_installed "externalsecrets.external-secrets.io" && false || true
  if [[ "$is_upgrade" -ne 0 ]] && is_crd_installed "externalsecrets.external-secrets.io"; then
    echo -e "${GREEN}External Secrets Operator CRD is already installed. Only one instance is allowed per cluster ${NC}"
    return
  fi

  echo -e "${YELLOW}Installing External Secrets Operator...${NC}"

  # Add the External Secrets Helm repository
  helm repo add external-secrets https://charts.external-secrets.io
  helm repo update

  # Check if the chart version is available
  local chat_version
  if ! chat_version=$(get_chart_version_for_app_version "external-secrets/external-secrets" "$ESO_VERSION"); then
    echo -e "${RED}Error: Unable to find chart version for ESO version $ESO_VERSION${NC}"
    return
  fi
  # Install the operator
  helm upgrade --install "$ESO_NAME" \
    external-secrets/external-secrets \
    -n "$ESO_NAMESPACE" \
    --create-namespace \
    --version "$chat_version" \
    --set installCRDs=true

  # Wait for the operator to be ready
  echo -e "${YELLOW}Waiting for External Secrets Operator to be ready...${NC}"
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name="$ESO_NAME" -n "$ESO_NAMESPACE" --timeout=300s

  echo -e "${GREEN}External Secrets Operator installed successfully${NC}"
}

# Function to uninstall K3s and ArgoCD
uninstall_all() {
  echo -e "${YELLOW}Starting uninstallation process...${NC}"

  # Uninstall ArgoCD
  if [[ "$SKIP_ARGOCD" == "false" ]]; then
    echo -e "${YELLOW}Uninstalling ArgoCD...${NC}"
    if kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
      helm uninstall "$ARGOCD_NAME" -n "$ARGOCD_NAMESPACE"
    else
      echo -e "${YELLOW}Namespace $ARGOCD_NAMESPACE does not exist. ArgoCD uninstallation.${NC}"
    fi
  fi

  # Remove ArgoCD CLI
  if command_exists argocd; then
    echo -e "${YELLOW}Removing ArgoCD CLI...${NC}"
    sudo rm -f /usr/local/bin/argocd
  fi

  # Uninstall External Secrets Operator
  if [[ "$SKIP_ESO" == "false" ]]; then
    echo -e "${YELLOW}Uninstalling External Secrets Operator...${NC}"
    if kubectl get namespace "$ESO_NAMESPACE" &>/dev/null; then
      helm uninstall "$ESO_NAME" -n "$ESO_NAMESPACE"
    else
      echo -e "${YELLOW}Namespace $ESO_NAMESPACE does not exist. Skipping External Secrets Operator uninstallation.${NC}"
    fi
  fi

  # Uninstall K3s
  if command_exists k3s; then
    echo -e "${YELLOW}Uninstalling K3s...${NC}"
    /usr/local/bin/k3s-uninstall.sh
  fi
}

check_dependencies() {
  echo -e "${YELLOW}Checking dependencies...${NC}"
  # Check if kubectl is installed
  if ! command_exists kubectl; then
    echo -e "${RED}kubectl is not installed${NC}"
    return 1
  fi

  # Check if Helm is installed
  if ! command_exists helm; then
    echo -e "${RED}Helm is not installed${NC}"

  fi
}
# Function to install necessary dependencies
# This function checks for required tools like Helm and installs them if they are not already present.
install_dependencies() {
  echo -e "${YELLOW}Checking dependencies...${NC}"

  # Check if curl is installed else install it
  if ! command_exists curl; then
    echo -e "${RED}curl is not installed. Installing...${NC}"
    sudo apt-get install -y curl
  else
    echo -e "${GREEN}curl is already installed${NC}"
  fi
  # Check if jq is installed else install it
  if ! command_exists jq; then
    echo -e "${RED}jq is not installed. Installing...${NC}"
    sudo apt-get install -y jq
  else
    echo -e "${GREEN}jq is already installed${NC}"
  fi

  # Check if Helm is required and not installed, then install it
  # Helm is needed if ArgoCD or External Secrets Operator installation is not skipped
  if [[ "$SKIP_ARGOCD" == "false" || "$SKIP_ESO" == "false" ]] && ! command_exists helm; then
    echo -e "${YELLOW}Installing Helm...${NC}"
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo -e "${GREEN}Helm installed successfully${NC}"
  else
    # If Helm is already installed, notify the user
    echo -e "${GREEN}Helm is already installed${NC}"
  fi
}

# Function to verify installation
verify_installation() {
  echo -e "${YELLOW}Verifying installation...${NC}"

  # Check if K3s is running
  if ! command_exists k3s; then
    echo -e "${RED}K3s is not installed${NC}"
    return 1
  fi

  # Check if kubectl is configured
  if ! kubectl cluster-info &>/dev/null; then
    echo -e "${RED}kubectl is not configured correctly${NC}"
    return 1
  fi

  # Check if ArgoCD CRD is installed
  if ! kubectl get crd applications.argoproj.io &>/dev/null; then
    echo -e "${RED}ArgoCD CRD is not installed${NC}"
    return 1
  fi

  # Check if External Secrets Operator is running
  # Check if ESO CRD is installed
  if ! kubectl get crd externalsecrets.external-secrets.io &>/dev/null; then
    echo -e "${RED}External Secrets Operator CRD is not installed${NC}"
    return 1
  fi
  # output values
  echo -e "${YELLOW}ArgoCD Dashboard URL: http://$NODE_IP:$ARGOCD_PORT${NC}"

  echo -e "${GREEN}All components are installed and running successfully${NC}"
}

# Main function
main() {
  parse_args "$@"
  confirm

  case "$OPERATION" in
  install)
    install_dependencies
    install_k3s
    install_argocd
    install_argocd_cli
    install_eso
    verify_installation
    ;;
  uninstall)
    check_dependencies || exit 1
    uninstall_all
    ;;
  *)
    echo -e "${RED}Invalid operation${NC}"
    exit 1
    ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
