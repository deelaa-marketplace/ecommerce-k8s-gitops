#!/bin/bash
set -eo pipefail

# Default values
DEFAULT_ESO_VERSION="0.16.1"
DEFAULT_NAMESPACE="default"
DEFAULT_NAME_PREFIX="${DEFAULT_NAMESPACE}"
DEFAULT_AWS_REGION="eu-west-1"

# Initialize variables
ESO_VERSION="${DEFAULT_ESO_VERSION}"
NAMESPACE="${DEFAULT_NAMESPACE}"
NAME_PREFIX="${DEFAULT_NAME_PREFIX}"
AWS_REGION="${DEFAULT_AWS_REGION}"
REFRESH_INTERVAL=""

CREATE_PARAMETER_STORE_ESO="true"
CREATE_ECR_ESO="true"
CREATE_AWS_SECRET="true"

# AWS credentials
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"

# Output file for variables
VARIABLES_OUTPUT_FILE="${NAME_PREFIX}_secret_variables.env"

# Function to check dependencies
check_dependencies() {
    local missing=()

    # Required commands
    for cmd in kubectl helm; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing required commands: ${missing[*]}"
        echo "Please install them before running this script."
        exit 1
    fi
}

# Function to print usage
print_usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --eso-version <version>       External Secrets Operator version (default: $DEFAULT_ESO_VERSION)
  --namespace <namespace>       Kubernetes namespace (default: $DEFAULT_NAMESPACE)
  --name-prefix <prefix>        Prefix for all resources (default: $DEFAULT_NAME_PREFIX)
  --aws-region <region>         AWS region (default: $DEFAULT_AWS_REGION)
  --aws-access-key <key>        AWS access key ID (default: from AWS_ACCESS_KEY_ID env)
  --aws-secret-key <key>        AWS secret access key (default: from AWS_SECRET_ACCESS_KEY env)
  --refresh-interval            ESO refresh interval (default: empty)
  --skip-parameter-store-eso    Skip Parameter Store ESO creation
  --skip-ecr-eso                Skip ECR ESO creation
  --help                        Show this help message
EOF
    exit 1
}

# Function to parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --eso-version)
            ESO_VERSION="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            NAME_PREFIX="$2" # Update name prefix to match namespace
            shift 2
            ;;
        --name-prefix)
            NAME_PREFIX="$2"
            shift 2
            ;;
        --aws-region | --aws-region)
            AWS_REGION="$2"
            shift 2
            ;;
        --aws-access-key)
            AWS_ACCESS_KEY_ID="$2"
            shift 2
            ;;
        --aws-secret-key)
            AWS_SECRET_ACCESS_KEY="$2"
            shift 2
            ;;
        --refresh-interval)
            REFRESH_INTERVAL="$2"
            shift 2
            ;;
        --skip-parameter-store-eso)
            CREATE_PARAMETER_STORE_ESO="false"
            shift
            ;;
        --skip-ecr-eso)
            CREATE_ECR_ESO="false"
            shift
            ;;
        --help)
            print_usage
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            ;;
        esac
    done

    CREATE_AWS_SECRET=$([[ "$CREATE_ECR_ESO" == "true" || "$CREATE_PARAMETER_STORE_ESO" == "true" ]] && echo "true" || echo "false")
    CREATE_AWS_SECRET="false"
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

# Function to validate AWS credentials
validate_aws_credentials() {
    if [[ "$CREATE_AWS_SECRET" == "true" ]]; then
        if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
            echo "ERROR: AWS credentials not provided and not found in environment variables."
            echo "Please provide AWS credentials using --aws-access-key and --aws-secret-key"
            echo "or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables."
            exit 1
        fi
    fi
}

# Function to print configuration
print_configuration() {
    cat <<EOF
Final Configuration Parameters:
===============================
ESO Version:               ${ESO_VERSION}
Namespace:                 ${NAMESPACE}
Resource Name Prefix:      ${NAME_PREFIX}
AWS Region:                ${AWS_REGION}
Refresh Interval:          ${REFRESH_INTERVAL}
Skip Parameter Store ESO:  ${CREATE_PARAMETER_STORE_ESO}
Skip ECR ESO:              ${CREATE_ECR_ESO}
EOF

    if [[ "$CREATE_AWS_SECRET" == "true" ]]; then
        cat <<EOF
AWS Access Key ID:        ${AWS_ACCESS_KEY_ID:0:4}****${AWS_ACCESS_KEY_ID: -4}
AWS Secret Access Key:    ${AWS_SECRET_ACCESS_KEY:0:4}****${AWS_SECRET_ACCESS_KEY: -4}
EOF
    fi
    echo "==============================="
}

# Function to confirm with user
confirm_operation() {
    read -rp "Do you want to proceed with these settings? (y/n) " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Operation cancelled by user."
        exit 0
    fi
}

# Function to create namespace if needed
create_namespace() {
    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        echo "Creating namespace ${NAMESPACE}..."
        kubectl create namespace "$NAMESPACE"
    fi
}

# Function to create AWS credentials secret
create_aws_secret() {
    if [[ "$CREATE_AWS_SECRET" == "true" ]]; then
        local secret_name="${NAME_PREFIX}-aws-credentials"

        # Base64 encode the credentials
        local access_key_encoded=$(echo -n "$AWS_ACCESS_KEY_ID" | base64 -w0)
        local secret_key_encoded=$(echo -n "$AWS_SECRET_ACCESS_KEY" | base64 -w0)

        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: ${NAMESPACE}
type: Opaque
data:
  aws-access-key: ${access_key_encoded}
  aws-secret-key: ${secret_key_encoded}
EOF

        echo "Created/updated secret: ${secret_name}"
    fi
}

process_template() {
    local template_file="$1"
     if ! interpolated_content=$(envsubst <"$template_file"); then
        echo "ERROR: Variable substitution failed for $template_file" >&2
        return 1
    fi
    echo "$interpolated_content"
}
# Function to process template files
process_templatex() {
    local template_file="$1"

    # Check file exists
    if [[ ! -f "$template_file" ]]; then
        echo "ERROR: Template not found: $template_file" >&2
        return 1
    fi

    # Interpolate and validate
    echo "Validating $template_file..."
    if ! interpolated_content=$(envsubst <"$template_file"); then
        echo "ERROR: Variable substitution failed for $template_file" >&2
        return 1
    fi

    # Dry-run validation
    if ! echo "$interpolated_content" | kubectl apply --dry-run=client -f - >/dev/null 2>&1; then
        echo "ERROR: Invalid Kubernetes manifest generated from: $template_file" >&2
        echo "Problematic content:" >&2
        echo "$interpolated_content" >&2
        return 1
    fi

    # Actual application
    echo "Applying $template_file..."
    if ! echo "$interpolated_content" | kubectl apply -f -; then
        echo "ERROR: Failed to apply $template_file" >&2
        return 1
    fi
   
}

# Function to create AWS credentials secret
create_aws_credentials_secret() {
    if [[ "$CREATE_AWS_SECRET" == "false" ]]; then
        echo "Skipping AWS credentials secret creation."
        return
    fi

    local templates=(
        "templates/aws-credentials-secret.yaml"
    )
    export NAME_PREFIX NAMESPACE AWS_REGION REFRESH_INTERVAL
    export AWS_ACCESS_KEY_B64=$(echo -n "$AWS_ACCESS_KEY_ID" | base64 -w0)
    export AWS_SECRET_KEY_B64=$(echo -n "$AWS_SECRET_ACCESS_KEY" | base64 -w0)

    for template in "${templates[@]}"; do
        process_template "$template" || exit 1
    done
    echo "Created/updated secret: ${NAME_PREFIX}-aws-credentials"

}

# Function to create AWS SSM secret
create_parameter_store_external_secret() {
    if [[ "$CREATE_PARAMETER_STORE_ESO" == "false" ]]; then
        echo "Skipping Parameter Store ESO creation."
        return
    fi
    local templates=(
        "templates/parameter-store-external-secret.yaml"
    )
    export NAME_PREFIX NAMESPACE AWS_REGION REFRESH_INTERVAL

    for template in "${templates[@]}"; do
        process_template "$template" || exit 1
    done
    echo "Created/updated External Secret for Parameter Store."
}

# Function to create ECR secret
create_ecr_external_secret() {
    if [[ "$CREATE_ECR_ESO" == "false" ]]; then
        echo "Skipping ECR ESO creation."
        return
    fi
    local templates=(
        "templates/ecr-external-secret.yaml"
    )
    export NAME_PREFIX NAMESPACE AWS_REGION REFRESH_INTERVAL
    for template in "${templates[@]}"; do
        process_template "$template" || exit 1
    done
    
}

# Function to install External Secrets Operator
install_external_secrets() {
    echo "Installing External Secrets Operator version ${ESO_VERSION}..."
    helm repo add external-secrets https://charts.external-secrets.io
    helm repo update

    helm upgrade --install external-secrets \
        external-secrets/external-secrets \
        -n "$NAMESPACE" \
        --version "$ESO_VERSION" \
        --set installCRDs=true \
        --wait
}

# Function to write variables to file
write_variables_to_file() {
    VARIABLES_OUTPUT_FILE="${NAME_PREFIX}_secret_variables.env"

    cat <<EOF >"${VARIABLES_OUTPUT_FILE}"
# Generated secret configuration
ESO_VERSION=${ESO_VERSION}
NAMESPACE=${NAMESPACE}
NAME_PREFIX=${NAME_PREFIX}
AWS_REGION=${AWS_REGION}
REFRESH_INTERVAL=${REFRESH_INTERVAL}
CREATE_PARAMETER_STORE_ESO=${CREATE_PARAMETER_STORE_ESO}
CREATE_ECR_ESO=${CREATE_ECR_ESO}
EOF

    if [[ "$CREATE_AWS_SECRET" == "true" ]]; then
        cat <<EOF >>"${VARIABLES_OUTPUT_FILE}"
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
SECRET_NAME=${NAME_PREFIX}-aws-credentials
EOF
    fi

    echo "Variables written to: ${VARIABLES_OUTPUT_FILE}"
}

# Main execution flow
main() {
    install_dependencies
    #check_dependencies
    parse_arguments "$@"
    validate_aws_credentials
    print_configuration
    confirm_operation
    create_namespace
    #create_aws_secret
    create_aws_credentials_secret
    create_parameter_store_external_secret
    create_ecr_external_secret
    #
    install_external_secrets
    write_variables_to_file

    echo "Setup completed successfully!"
    echo "Summary of created resources:"
    echo "============================"
    if [[ "$CREATE_AWS_SECRET" == "true" ]]; then
        echo "AWS Credentials Secret: ${NAME_PREFIX}-aws-credentials"
    fi
    echo "Installed ESO Version: ${ESO_VERSION}"
}
main2() {
    print_configuration
    create_parameter_store_external_secret
    create_ecr_external_secret
}
# Execute main function
main2 "$@"
