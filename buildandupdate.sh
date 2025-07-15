#!/bin/bash

# Docker Build and Kubernetes Update Script with Checksum Optimization
# This script builds Docker images from three directories, pushes them to a local repo,
# and updates Kubernetes deployments with the new image tags.
# It skips building if no changes are detected in the source directories.

set -e  # Exit on any error

# Configuration
LOCAL_REGISTRY="localhost:5000"  # Change to your local registry URL
DIRECTORIES=("deploy" "request" "upload")  # Change to your actual directory names
DEPLOYMENTS=("deploy-service" "request-service" "upload-service")  # Change to your actual deployment names
NAMESPACE="vercel-clone"  # Change to your namespace if different
CHECKSUM_FILE=".build-checksums.json"  # File to store checksums

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_skip() {
    echo -e "${BLUE}[SKIP]${NC} $1"
}

# Function to generate random ID
generate_random_id() {
    echo $((RANDOM * RANDOM))
}

# Function to check if directory exists and has Dockerfile
check_directory() {
    local dir=$1
    if [ ! -d "$dir" ]; then
        print_error "Directory $dir does not exist"
        return 1
    fi

    if [ ! -f "$dir/Dockerfile" ]; then
        print_error "Dockerfile not found in $dir"
        return 1
    fi

    return 0
}

# Function to get .gitignore patterns and create find exclude arguments
get_gitignore_excludes() {
    local dir=$1
    local gitignore_file="$dir/.gitignore"
    local excludes=""

    if [ -f "$gitignore_file" ]; then
        # Read .gitignore and convert to find exclude arguments
        while IFS= read -r line; do
            # Skip empty lines and comments
            if [[ -n "$line" && ! "$line" =~ ^#.* ]]; then
                # Remove leading/trailing whitespace
                line=$(echo "$line" | xargs)

                # Handle different gitignore patterns
                if [[ "$line" == *"/" ]]; then
                    # Directory pattern
                    excludes="$excludes -path '*/${line%/}' -prune -o"
                elif [[ "$line" == "."* ]]; then
                    # Hidden files/extensions
                    excludes="$excludes -name '$line' -prune -o"
                else
                    # Regular file/directory patterns
                    excludes="$excludes -name '$line' -prune -o"
                fi
            fi
        done < "$gitignore_file"
    fi

    # Always exclude .git directory
    excludes="$excludes -path '*/.git' -prune -o"

    echo "$excludes"
}

# Function to calculate directory checksum
calculate_directory_checksum() {
    local dir=$1
    local excludes
    local find_cmd
    local checksum

    excludes=$(get_gitignore_excludes "$dir")

    # Build the find command with excludes
    find_cmd="find \"$dir\" $excludes -type f -print0"

    # Calculate checksum of all relevant files
    if [ -n "$excludes" ]; then
        checksum=$(eval "$find_cmd" | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
    else
        checksum=$(find "$dir" -type f -not -path '*/.git/*' -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
    fi

    echo "$checksum"
}

# Function to load existing checksums
load_checksums() {
    if [ -f "$CHECKSUM_FILE" ]; then
        cat "$CHECKSUM_FILE"
    else
        echo "{}"
    fi
}

# Function to save checksums
save_checksums() {
    local checksums="$1"
    echo "$checksums" > "$CHECKSUM_FILE"
}

# Function to get checksum from JSON
get_stored_checksum() {
    local dir=$1
    local checksums=$2

    # Use jq if available, otherwise use basic parsing
    if command -v jq >/dev/null 2>&1; then
        echo "$checksums" | jq -r ".\"$dir\" // empty"
    else
        # Basic JSON parsing for the specific key
        echo "$checksums" | grep -o "\"$dir\":\"[^\"]*\"" | cut -d'"' -f4
    fi
}

# Function to update checksum in JSON
update_checksum() {
    local dir=$1
    local new_checksum=$2
    local checksums=$3

    # Use jq if available, otherwise use basic replacement
    if command -v jq >/dev/null 2>&1; then
        echo "$checksums" | jq ". + {\"$dir\": \"$new_checksum\"}"
    else
        # Basic JSON update
        if [[ "$checksums" == "{}" ]]; then
            echo "{\"$dir\": \"$new_checksum\"}"
        else
            # Remove existing entry if it exists and add new one
            local updated
            updated=$(echo "$checksums" | sed "s/\"$dir\":\"[^\"]*\",\?//g" | sed 's/,}/}/g' | sed 's/{,/{/g')
            if [[ "$updated" == "{}" ]]; then
                echo "{\"$dir\": \"$new_checksum\"}"
            else
                echo "${updated/\}/,\"$dir\": \"$new_checksum\"}"
            fi
        fi
    fi
}

# Function to check if directory has changes
has_directory_changed() {
    local dir=$1
    local checksums=$2
    local current_checksum
    local stored_checksum

    print_status "Calculating checksum for $dir"
    current_checksum=$(calculate_directory_checksum "$dir")
    stored_checksum=$(get_stored_checksum "$dir" "$checksums")

    if [ -z "$stored_checksum" ]; then
        print_status "No previous checksum found for $dir, will build"
        return 0
    fi

    if [ "$current_checksum" != "$stored_checksum" ]; then
        print_status "Changes detected in $dir (checksum: $current_checksum)"
        return 0
    else
        print_skip "No changes detected in $dir, skipping build"
        return 1
    fi
}

# Function to build and push Docker image
build_and_push() {
    local dir=$1
    local image_name=$2
    local tag=$3
    CURRENT_IMAGE="${LOCAL_REGISTRY}/${image_name}:${tag}"

    print_status "Building Docker image for $dir..."

    # Build the Docker image
    if docker build -t "$CURRENT_IMAGE" "$dir/"; then
        print_status "Successfully built $CURRENT_IMAGE"
    else
        print_error "Failed to build $CURRENT_IMAGE"
        return 1
    fi

    # Push the image to local registry
    print_status "Pushing $CURRENT_IMAGE to local registry..."
    if docker push "$CURRENT_IMAGE"; then
        print_status "Successfully pushed $CURRENT_IMAGE"
    else
        print_error "Failed to push $CURRENT_IMAGE"
        return 1
    fi

    return 0
}

# Function to update Kubernetes deployment
update_k8s_deployment() {
    local deployment=$1
    local image_name=$2
    local namespace=$3

    print_status "Updating Kubernetes deployment $deployment..."

    # Update the deployment with new image
    if kubectl set image deployment/"$deployment" "$deployment"="$image_name" -n "$namespace"; then
        print_status "Successfully updated deployment $deployment"

        # Wait for rollout to complete
        print_status "Waiting for rollout to complete..."
        if kubectl rollout status deployment/"$deployment" -n "$namespace" --timeout=300s; then
            print_status "Rollout completed successfully for $deployment"
        else
            print_warning "Rollout status check timed out for $deployment"
        fi
    else
        print_error "Failed to update deployment $deployment"
        return 1
    fi
}

# Main script execution
main() {
    print_status "Starting Docker build and Kubernetes update process..."

    # Check if required tools are installed
    command -v docker >/dev/null 2>&1 || { print_error "Docker is required but not installed. Aborting."; exit 1; }
    command -v kubectl >/dev/null 2>&1 || { print_error "kubectl is required but not installed. Aborting."; exit 1; }

    # Load existing checksums
    local checksums
    checksums=$(load_checksums)
    print_status "Loaded existing checksums from $CHECKSUM_FILE"

    # Check if all directories exist
    for dir in "${DIRECTORIES[@]}"; do
        check_directory "$dir" || exit 1
    done

    # Arrays to store built images and directories that need building
    BUILT_IMAGES=()
    DIRS_TO_BUILD=()
    DIRS_TO_DEPLOY=()

    # Check each directory for changes
    for dir in "${DIRECTORIES[@]}"; do
        if has_directory_changed "$dir" "$checksums"; then
            DIRS_TO_BUILD+=("$dir")
        fi
    done

    # If no directories need building, exit early
    if [ ${#DIRS_TO_BUILD[@]} -eq 0 ]; then
        print_status "No changes detected in any directory. No builds necessary."
        exit 0
    fi

    # Generate random ID for this build
    BUILD_ID=$(generate_random_id)
    print_status "Generated build ID: $BUILD_ID"

    # Build and push images for changed directories
    for dir in "${DIRS_TO_BUILD[@]}"; do
        image_name="$dir"  # Use directory name as image name, modify if needed

        print_status "Processing directory: $dir"

        # Build and push image
        if build_and_push "$dir" "$image_name" "$BUILD_ID"; then
            BUILT_IMAGES+=("$CURRENT_IMAGE")
            DIRS_TO_DEPLOY+=("$dir")
            print_status "Added $CURRENT_IMAGE to deployment queue"

            # Update checksum for successfully built directory
            local new_checksum
            new_checksum=$(calculate_directory_checksum "$dir")
            checksums=$(update_checksum "$dir" "$new_checksum" "$checksums")
        else
            print_error "Failed to build and push image for $dir"
            exit 1
        fi
    done

    # Save updated checksums
    save_checksums "$checksums"
    print_status "Updated checksums saved to $CHECKSUM_FILE"

    print_status "All images built and pushed successfully!"
    print_status "Built images:"
    for image in "${BUILT_IMAGES[@]}"; do
        echo "  - $image"
    done

    # Update Kubernetes deployments for built images
    print_status "Updating Kubernetes deployments..."

    for i in "${!DIRS_TO_DEPLOY[@]}"; do
        dir="${DIRS_TO_DEPLOY[$i]}"
        image_name="${BUILT_IMAGES[$i]}"

        # Find the corresponding deployment for this directory
        for j in "${!DIRECTORIES[@]}"; do
            if [ "${DIRECTORIES[$j]}" = "$dir" ]; then
                deployment="${DEPLOYMENTS[$j]}"
                break
            fi
        done

        print_status "Updating deployment: $deployment with image: $image_name"
        if ! update_k8s_deployment "$deployment" "$image_name" "$NAMESPACE"; then
            print_error "Failed to update deployment $deployment"
            exit 1
        fi
    done

    print_status "All deployments updated successfully!"
    print_status "Build ID: $BUILD_ID"
    print_status "Script completed successfully!"
}

# Script usage information
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  -n, --namespace NAMESPACE   Set Kubernetes namespace (default: vercel-clone)"
    echo "  -r, --registry REGISTRY     Set local registry URL (default: localhost:5000)"
    echo "  -f, --force    Force rebuild all images regardless of changes"
    echo "  --clean        Remove checksum file and force rebuild"
    echo ""
    echo "Configuration:"
    echo "  Edit the DIRECTORIES and DEPLOYMENTS arrays in the script to match your setup"
    echo ""
    echo "Prerequisites:"
    echo "  - Docker must be installed and running"
    echo "  - kubectl must be installed and configured"
    echo "  - Local Docker registry must be running"
    echo "  - Each directory must contain a Dockerfile"
    echo ""
    echo "Checksum optimization:"
    echo "  - The script respects .gitignore files in each directory"
    echo "  - Checksums are stored in $CHECKSUM_FILE"
    echo "  - Only directories with changes will be rebuilt"
}

# Parse command line arguments
FORCE_BUILD=false
CLEAN_CHECKSUMS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -r|--registry)
            LOCAL_REGISTRY="$2"
            shift 2
            ;;
        -f|--force)
            FORCE_BUILD=true
            shift
            ;;
        --clean)
            CLEAN_CHECKSUMS=true
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Handle force build and clean options
if [ "$CLEAN_CHECKSUMS" = true ]; then
    print_status "Cleaning checksum file..."
    rm -f "$CHECKSUM_FILE"
fi

if [ "$FORCE_BUILD" = true ]; then
    print_status "Force build enabled, ignoring checksums..."
    rm -f "$CHECKSUM_FILE"
fi

# Run main function
main
