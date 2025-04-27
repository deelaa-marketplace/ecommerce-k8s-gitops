#!/bin/bash

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configurations
DEFAULT_NAMESPACE="default"
DEFAULT_AWS_PROFILE="default"
#DEFAULT_REGION="eu-west-1"
DEFAULT_MANIFESTS_DIR_NAME="manifests"
DEFAULT_OUTPUT_DIR_NAME="manifests-output"
DEFAULT_WORKING_DIR="."

# Initialize variables
ACTION=""
NAMESPACE=$DEFAULT_NAMESPACE
AWS_PROFILE=$DEFAULT_AWS_PROFILE
REGION=""
AWS_ACCESS_KEY="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_KEY="${AWS_SECRET_ACCESS_KEY:-}"
SSH_PRIVATE_KEY_FILE=""
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-}"
WORKING_DIR="$DEFAULT_WORKING_DIR"
MANIFESTS_DIR="${MANIFESTS_DIR:-$DEFAULT_MANIFESTS_DIR_NAME}"
OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR_NAME}"
FORCE=false
VERBOSE=false
DRY_RUN=false
OUTPUT=false



# --- Helper Functions ---

# Print usage information
usage() {
  echo -e "${BLUE}Usage: $0 <install|uninstall> [OPTIONS]${NC}"
  echo
  echo -e "${BLUE}Options:${NC}"
  echo "  -n, --namespace NS         Kubernetes namespace (default: $DEFAULT_NAMESPACE)"
  echo "  -p, --aws-profile PROFILE  AWS profile name (default: $DEFAULT_AWS_PROFILE)"
  echo "  -r, --region REGION        AWS region"
  echo "  -a, --access-key KEY       AWS Access Key ID"
  echo "  -s, --secret-key KEY       AWS Secret Access Key"
  echo "  -k, --ssh-key-file FILE    Path to SSH private key file"
  echo "  -o, --output               Save processed manifests to output directory"
  echo "  -w, --working-dir DIR      Working directory (default: $WORKING_DIR)"
  echo "  -d, --dry-run              Show what would be done without making changes"
  echo "  -f, --force                Skip confirmation prompts"
  echo "  -v, --verbose              Enable verbose output"
  echo "  -h, --help                 Show this help message"
  echo
  echo -e "${BLUE}Environment Variables:${NC}"
  echo "  AWS_ACCESS_KEY_ID         AWS Access Key ID (default: $AWS_ACCESS_KEY)"
  echo "  AWS_SECRET_ACCESS_KEY     AWS Secret Access Key (default: $AWS_SECRET_KEY)"
  echo "  SSH_PRIVATE_KEY           SSH private key (default: $SSH_PRIVATE_KEY)"
  exit 1
}

# Check for required dependencies
check_dependencies() {
  local missing=()

  for cmd in kubectl envsubst; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${RED}Error: Missing required dependencies: ${missing[*]}${NC}"

    # Try to install envsubst if missing
    if [[ " ${missing[*]} " =~ " envsubst " ]]; then
      echo -e "${YELLOW}Attempting to install envsubst...${NC}"
      if command -v apt-get &>/dev/null; then
        sudo apt-get install -y gettext-base
      elif command -v yum &>/dev/null; then
        sudo yum install -y gettext
      else
        echo -e "${RED}Could not automatically install envsubst. Please install it manually.${NC}"
        return 1
      fi

      # Verify installation
      if ! command -v envsubst &>/dev/null; then
        echo -e "${RED}Failed to install envsubst${NC}"
        return 1
      fi
      echo -e "${GREEN}envsubst installed successfully${NC}"
    else
      return 1
    fi
  fi
}

# Create namespace if it doesn't exist
create_namespace() {
  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo -e "${YELLOW}Creating namespace $NAMESPACE...${NC}"
    kubectl create namespace "$NAMESPACE" || {
      echo -e "${RED}Failed to create namespace $NAMESPACE${NC}"
      return 1
    }
    echo -e "${GREEN}Namespace $NAMESPACE created successfully${NC}"
  else
    echo -e "${YELLOW}Namespace $NAMESPACE already exists${NC}"
  fi
}

# Process Kubernetes manifest template
process_template() {
  local template_file="$1"
  local action="$2"
  local processed_manifest

  # Export variables for envsubst
  export NAMESPACE AWS_ACCESS_KEY AWS_SECRET_KEY SSH_PRIVATE_KEY AWS_REGION="${REGION}"

  if [[ -n "$AWS_ACCESS_KEY" ]]; then
    local AWS_ACCESS_KEY_B64
    AWS_ACCESS_KEY_B64=$(echo -n "$AWS_ACCESS_KEY" | base64 -w0)
    export AWS_ACCESS_KEY_B64
  fi
  if [[ -n "$AWS_SECRET_KEY" ]]; then
    local AWS_SECRET_KEY_B64
    AWS_SECRET_KEY_B64=$(echo -n "$AWS_SECRET_KEY" | base64 -w0)
    export AWS_SECRET_KEY_B64
  fi
  if [[ -n "$SSH_PRIVATE_KEY" ]]; then
    local SSH_PRIVATE_KEY_B64
    SSH_PRIVATE_KEY_B64=$(echo -n "$SSH_PRIVATE_KEY" | base64 -w0)
    export SSH_PRIVATE_KEY_B64
  fi
  echo -e "${YELLOW}Processing template: $template_file${NC}"

  # Substitute environment variables
  processed_manifest=$(envsubst <"$template_file") || {
    echo -e "${RED}Failed to process template $template_file${NC}"
    return 1
  }

  if $OUTPUT; then
    local output_dir
    output_dir="${OUTPUT_DIR}/${NAMESPACE}/${action}-${DRY_RUN:+-dry-run}/"
    mkdir -p "$output_dir"
    if [[ ! -d "$output_dir" ]]; then
      echo -e "${RED}Output directory $output_dir does not exist and could not be created${NC}"
      return 1
    fi

    local output_file
    output_file="${output_dir}/$(basename "${template_file%.*}").out.${template_file##*.}"
    echo "$processed_manifest" >"$output_file"
    echo -e "${GREEN}Saved processed manifest to: $output_file${NC}"
  fi

  if $VERBOSE; then
    echo -e "${BLUE}Processed manifest:${NC}"
    echo "$processed_manifest"
    echo
  fi

  if $DRY_RUN; then
    echo -e "${YELLOW}Dry run: Would ${action} resources from $template_file${NC}"
  fi

  case "$action" in
  install)
    # Dry-run validation (even when not in full dry-run mode)
    if ! echo "$processed_manifest" | kubectl apply --dry-run=client -f - &>/dev/null; then
      echo -e "${RED}Manifest validation failed for $template_file${NC}"
      return 1
    fi
    if $DRY_RUN; then
      echo -e "${YELLOW}Dry run validation succeeded for $template_file${NC}"
      return 0
    fi

    # Apply manifest
    echo "$processed_manifest" | kubectl apply -f - || {
      echo -e "${RED}Failed to apply $template_file${NC}"
      return 1
    }
    echo -e "${GREEN}Successfully applied $template_file${NC}"
    ;;
  uninstall)
    # Dry-run validation (even when not in full dry-run mode)
    if ! echo "$processed_manifest" | kubectl delete --dry-run=client -f - &>/dev/null; then
      echo -e "${RED}Manifest validation failed for $template_file${NC}"
      return 1
    fi
    if $DRY_RUN; then
      echo -e "${YELLOW}Dry run validation succeeded for $template_file${NC}"
      return 0
    fi

    # Delete resources
    echo "$processed_manifest" | kubectl delete -f - --ignore-not-found || {
      echo -e "${RED}Failed to delete resources from $template_file${NC}"
      return 1
    }
    echo -e "${GREEN}Successfully deleted resources from $template_file${NC}"
    ;;
  *)
    echo -e "${RED}Invalid action: $action${NC}"
    return 1
    ;;
  esac
}

# Process all manifests in the manifests directory
process_manifests() {
  local action="$1"

  local manifest_dir="${MANIFESTS_DIR}/${NAMESPACE}"
  if [[ ! -d "$manifest_dir" ]]; then
    echo -e "${YELLOW}No manifests directory found at $manifest_dir${NC}"
    return 0
  fi

  echo -e "${YELLOW}Processing manifests in $manifest_dir...${NC}"

  process_manifests_directory "$manifest_dir" "$action" || {
    echo -e "${RED}Error processing manifests in $manifest_dir${NC}"
    return 1
  }
}

process_manifests_directory() {
  local dir="$1"
  local  action="$2"
  local subdirectories=()

  # Process all files in the current directory (sorted alphabetically)
  while read -r file; do
    if [[ -d "$file" ]]; then
      subdirectories+=("$file")
      continue
    fi
#    if [[ "${file%.*}" == *".out"* ]]; then
#      echo "Skipping output file: $file"
#      continue
#    fi
     echo -e "${YELLOW}Processing ${file}...${NC}"
    # Process the manifest template
    process_template "$file" "$action" || {
      echo -e "${RED}Error processing $file${NC}"
      return 1
    }
  done < <(find "$dir" -maxdepth 1 \( -type f -name "*.yaml" -o -name "*.yml" -o -type d  ! -path "$dir" \) | sort)

  # Recursively process all subdirectories
  for subdir in "${subdirectories[@]}"; do
    echo "${YELLOW}Entering directory: $subdir${NC}"
    process_manifests_directory "$subdir" "$action" || {
      echo -e "${RED}Error processing manifests in ${subdir}${NC}"
      return 1
    }
  done
}

# Read SSH private key file
read_ssh_private_key() {
  if [[ -n "$SSH_PRIVATE_KEY_FILE" ]]; then
    if [[ ! -f "$SSH_PRIVATE_KEY_FILE" ]]; then
      echo -e "${RED}SSH private key file not found: $SSH_PRIVATE_KEY_FILE${NC}"
      return 1
    fi
    SSH_PRIVATE_KEY=$(<"$SSH_PRIVATE_KEY_FILE")
    if [[ -z "$SSH_PRIVATE_KEY" ]]; then
      echo -e "${RED}Failed to read SSH private key from $SSH_PRIVATE_KEY_FILE${NC}"
      return 1
    fi
    echo -e "${GREEN}Successfully read SSH private key from $SSH_PRIVATE_KEY_FILE${NC}"
  fi
}

# Read AWS credentials from ~/.aws/credentials
read_aws_credentials() {
    local aws_creds_file="$HOME/.aws/credentials"

    if [[ -f "$aws_creds_file" ]]; then
        echo -e "${YELLOW}Reading AWS credentials from $aws_creds_file${NC}"

        # Read the specified profile (defaults to [default])
        while IFS=' =' read -r key value; do
            if [[ "$key" == "[$AWS_PROFILE]" ]]; then
                in_profile=true
            elif [[ "$in_profile" == true && "$key" == "aws_access_key_id" ]]; then
                AWS_ACCESS_KEY="$value"
            elif [[ "$in_profile" == true && "$key" == "aws_secret_access_key" ]]; then
                AWS_SECRET_KEY="$value"
            elif [[ "$key" == "["* ]] && [[ "$in_profile" == true ]]; then
                break  # Reached another profile section
            fi
        done < "$aws_creds_file"

        if [[ -z "$AWS_ACCESS_KEY" || -z "$AWS_SECRET_KEY" ]]; then
            echo -e "${YELLOW}Warning: AWS credentials not found for profile [$AWS_PROFILE]${NC}"
            return 1
        fi

        echo -e "${GREEN}Successfully read AWS credentials for profile [$AWS_PROFILE]${NC}"
        return 0
    else
        echo -e "${YELLOW}AWS credentials file not found at $aws_creds_file${NC}"
        return 1
    fi
}

# Read AWS config (including region) from ~/.aws/config
read_aws_config() {
    local aws_config_file="$HOME/.aws/config"

    if [[ -f "$aws_config_file" ]]; then
        echo -e "${YELLOW}Reading AWS config from $aws_config_file${NC}"

        # AWS config file uses profile format like [profile name] except for default
        local config_profile
        if [[ "$AWS_PROFILE" == "default" ]]; then
            config_profile="[default]"
        else
            config_profile="[profile $AWS_PROFILE]"
        fi

        # Read the specified profile
        while IFS=' =' read -r key value; do
            if [[ "$key" == "$config_profile" ]]; then
                in_profile=true
            elif [[ "$in_profile" == true && "$key" == "region" ]]; then
                REGION="$value"
                break  # We got what we needed
            elif [[ "$key" == "["* ]] && [[ "$in_profile" == true ]]; then
                break  # Reached another profile section
            fi
        done < "$aws_config_file"

        if [[ -n "$REGION" ]]; then
            echo -e "${GREEN}Found region '$REGION' in AWS config for profile [$AWS_PROFILE]${NC}"
            return 0
        else
            echo -e "${YELLOW}No region found in AWS config for profile [$AWS_PROFILE]${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}AWS config file not found at $aws_config_file${NC}"
        return 1
    fi
}
# Print current configuration
print_config() {
  echo -e "${BLUE}Current Configuration:${NC}"
  echo -e "  Action:                ${GREEN}$ACTION${NC}"
  echo -e "  Namespace:             ${GREEN}$NAMESPACE${NC}"
  echo -e "  AWS Profile:           ${GREEN}$AWS_PROFILE${NC}"
  echo -e "  AWS Region:            ${GREEN}$REGION${NC}"
  echo -e "  AWS Access Key:        ${GREEN}${AWS_ACCESS_KEY:+*****}${NC}"
  echo -e "  AWS Secret Key:        ${GREEN}${AWS_SECRET_KEY:+*****}${NC}"
  echo -e "  SSH Private Key File:  ${GREEN}${SSH_PRIVATE_KEY_FILE:-none}${NC}"
  echo -e "  Output Enabled:        ${GREEN}$OUTPUT${NC}"
  echo -e "  Output Directory:      ${GREEN}$OUTPUT_DIR${NC}"
  echo -e "  Manifests Directory:   ${GREEN}$MANIFESTS_DIR${NC}"
  echo -e "  Working Directory:     ${GREEN}$WORKING_DIR${NC}"
  echo -e "  Dry Run:               ${GREEN}$DRY_RUN${NC}"
  echo -e "  Force Mode:            ${GREEN}$FORCE${NC}"
  echo -e "  Verbose Mode:          ${GREEN}$VERBOSE${NC}"
  echo
}

# Confirm before proceeding
confirm_action() {
  print_config
  # Confirm action (unless force or dry-run)
  if $FORCE || $DRY_RUN; then
    return 0
  fi

  read -rp "Do you want to proceed with ${ACTION}? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo -e "${YELLOW}Operation cancelled${NC}"
    exit 0
  fi
}

# Parse command line arguments
parse_args() {
  if [[ $# -lt 1 ]]; then
    usage
  fi

  ACTION="$1"
  shift

  if [[ "$ACTION" != "install" && "$ACTION" != "uninstall" ]]; then
    echo -e "${RED}Error: Invalid action '$ACTION'. Must be 'install' or 'uninstall'${NC}"
    usage
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
    install|uninstall)
      COMMAND="$1"
      shift
      ;;
    -n=*|--namespace=*)
      NAMESPACE="${1#*=}"
      shift
      ;;
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    -p=*|--aws-profile=*)
      AWS_PROFILE="${1#*=}"
      shift
      ;;
    -p|--aws-profile)
      AWS_PROFILE="$2"
      shift 2
      ;;
    -r=*|--region=*)
      REGION="${1#*=}"
      shift
      ;;
    -r|--region)
      REGION="$2"
      shift 2
      ;;
    -a=*|--access-key=*)
      AWS_ACCESS_KEY="${1#*=}"
      shift
      ;;
    -a|--access-key)
      AWS_ACCESS_KEY="$2"
      shift 2
      ;;
    -s=*|--secret-key=*)
      AWS_SECRET_KEY="${1#*=}"
      shift
      ;;
    -s|--secret-key)
      AWS_SECRET_KEY="$2"
      shift 2
      ;;
    -k=*|--ssh-key-file=*)
      SSH_PRIVATE_KEY_FILE="${1#*=}"
      shift
      ;;
    -k|--ssh-key-file)
      SSH_PRIVATE_KEY_FILE="$2"
      shift 2
      ;;
    -o|--output)
      OUTPUT=true
      shift
      ;;
    -w=*|--working-dir=*)
      WORKING_DIR="${1#*=}"
      OUTPUT_DIR="${WORKING_DIR}/$DEFAULT_OUTPUT_DIR_NAME"
      MANIFESTS_DIR="${WORKING_DIR}/$DEFAULT_MANIFESTS_DIR_NAME"
      shift
      ;;
    -w|--working-dir)
      WORKING_DIR="$2"
      OUTPUT_DIR="${WORKING_DIR}/$DEFAULT_OUTPUT_DIR_NAME"
      MANIFESTS_DIR="${WORKING_DIR}/$DEFAULT_MANIFESTS_DIR_NAME"
      shift 2
      ;;
    -d|--dry-run)
      DRY_RUN=true
      VERBOSE=true
      shift
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *=*)
      echo -e "${RED}Error: Unknown option $1${NC}"
      usage
      ;;
    *)
      echo -e "${RED}Error: Unknown option $1${NC}"
      usage
      ;;
    esac
  done

  # Read SSH private key file is specified
  if [[ -n "$SSH_PRIVATE_KEY_FILE" ]]; then
    read_ssh_private_key || usage
  fi

  # Read AWS config first (to get region)
  if [[ -z "$REGION" ]]; then
    read_aws_config || echo -e "${YELLOW}Proceeding without AWS Region${NC}"
  fi

  # Read AWS credentials if not provided via command line
  if [[ -z "$AWS_ACCESS_KEY" || -z "$AWS_SECRET_KEY" ]]; then
    read_aws_credentials || echo -e "${YELLOW}Proceeding without AWS credentials${NC}"
  fi
  # Validate AWS credentials for install (unless dry-run)
  if [[ "$ACTION" == "install" && (-z "$AWS_ACCESS_KEY" || -z "$AWS_SECRET_KEY") && ! $DRY_RUN ]]; then
    echo -e "${YELLOW}Warning: AWS credentials not provided. Some features may not work.${NC}"
  fi
}

parse_argsx() {
  if [[ $# -lt 1 ]]; then
    usage
  fi

  local cmd="$1"
  if [[ "$cmd" != "install" && "$cmd" != "uninstall" ]]; then
    echo -e "${RED}Error: Invalid action '$cmd'. Must be 'install' or 'uninstall'${NC}"
    usage
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -n | --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    -p | --aws-profile)
      AWS_PROFILE="$2"
      shift 2
      ;;
    -r | --region)
      REGION="$2"
      shift 2
      ;;
    -a | --access-key)
      AWS_ACCESS_KEY="$2"
      shift 2
      ;;
    -s | --secret-key)
      AWS_SECRET_KEY="$2"
      shift 2
      ;;
    -k | --ssh-key-file)
      SSH_PRIVATE_KEY_FILE="$2"
      shift 2
      ;;
    -o | --output)
      OUTPUT=true
      shift
      ;;
    -w | --working-dir)
      WORKING_DIR="$2"
      OUTPUT_DIR="${WORKING_DIR}/$DEFAULT_OUTPUT_DIR_NAME"
      MANIFESTS_DIR="${WORKING_DIR}/$DEFAULT_MANIFESTS_DIR_NAME"
      shift 2
      ;;
    -d | --dry-run)
      DRY_RUN=true
      VERBOSE=true
      shift
      ;;
    -f | --force)
      FORCE=true
      shift
      ;;
    -v | --verbose)
      VERBOSE=true
      shift
      ;;
    -h | --help)
      usage
      ;;
    *)
      echo -e "${RED}Error: Unknown option $1${NC}"
      usage
      ;;
    esac
  done


  # Read SSH private key if specified
  if [[ -n "$SSH_PRIVATE_KEY_FILE" ]]; then
    read_ssh_private_key || usage
  fi

  # Validate AWS credentials for install (unless dry-run)
  if [[ "$ACTION" == "install" && (-z "$AWS_ACCESS_KEY" || -z "$AWS_SECRET_KEY") && ! $DRY_RUN ]]; then
    echo -e "${YELLOW}Warning: AWS credentials not provided. Some features may not work.${NC}"
  fi
}

# --- Main Function ---

main() {
  parse_args "$@"

  # Check dependencies (unless dry-run)
  if ! $DRY_RUN && ! check_dependencies; then
    echo -e "${RED}Error: Required dependencies are missing${NC}"
    exit 1
  fi

  # Confirm action
  confirm_action

  # Execute action
  if $DRY_RUN; then
    echo -e "${YELLOW}=== DRY RUN MODE ===${NC}"
    echo -e "${YELLOW}No changes will be made to the cluster${NC}"
    echo
  fi

  case "$ACTION" in
  install)
    if ! $DRY_RUN; then
      create_namespace || exit 1
    fi
    process_manifests install || exit 1
    if $DRY_RUN; then
      echo -e "${GREEN}Dry run completed - no changes made${NC}"
    else
      echo -e "${GREEN}Installation completed successfully!${NC}"
    fi
    ;;
  uninstall)
    process_manifests uninstall || exit 1
    if $DRY_RUN; then
      echo -e "${GREEN}Dry run completed - no changes made${NC}"
    else
      echo -e "${GREEN}Uninstallation completed successfully!${NC}"
    fi
    ;;
  esac
}

# Only execute if run directly
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

#./manifest.sh install \
#  -n ecommerce-dev \
#  -r eu-west-1 \
#  -a my-access-key \
#  -s my-secret-key \
#  -k ~/.ssh/id_ed25519 \
#  -o \
#  -w /path/to/working-dir \
#  -d \
#  -f \
#  -v

#./manifest.sh install \
#  --namespace=mecommerce-dev \
#  --region=eu-west-1 \
#  --access-key=my-access-key \
#  --secret-key=my-secret-key \
#  --ssh-key-file=~/.ssh/id_ed25519 \
#  --output \
#  --working-dir=/path/to/working-dir \
#  --dry-run \
#  --force \
#  --verbose

#sudo bash manifest.sh install -n ecommerce-dev -k ~/.ssh/id_ed25519  -v -d