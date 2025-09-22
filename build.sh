#!/bin/bash

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Default values
IMAGE_NAME="lmstudio-copilot-proxy"
TAG="latest"
BUILD_ARGS=""
PUSH_TO_REGISTRY=""
PLATFORMS="linux/amd64"

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -t, --tag TAG              Docker image tag (default: latest)"
    echo "  -n, --name NAME           Docker image name (default: lmstudio-copilot-proxy)"
    echo "  -p, --push                Push to registry after build"
    echo "  -m, --multi-platform      Build for multiple platforms (amd64, arm64)"
    echo "  --build-arg KEY=VALUE     Pass build arguments"
    echo "  -h, --help                Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                        # Build basic image"
    echo "  $0 -t v1.0.0             # Build with custom tag"
    echo "  $0 -m                    # Build for multiple platforms"
    echo "  $0 -t latest -p          # Build and push to registry"
}

# Function to log messages
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--tag)
            TAG="$2"
            shift 2
            ;;
        -n|--name)
            IMAGE_NAME="$2"
            shift 2
            ;;
        -p|--push)
            PUSH_TO_REGISTRY="true"
            shift
            ;;
        -m|--multi-platform)
            PLATFORMS="linux/amd64,linux/arm64"
            shift
            ;;
        --build-arg)
            BUILD_ARGS="$BUILD_ARGS --build-arg $2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Main build function
main() {
    log "🐳 Building LM Studio Copilot Proxy Docker Image"
    log "📋 Configuration:"
    log "   - Image: ${IMAGE_NAME}:${TAG}"
    log "   - Platforms: ${PLATFORMS}"
    log "   - Push to registry: ${PUSH_TO_REGISTRY:-false}"
    
    # Check if Docker is available
    if ! command -v docker &> /dev/null; then
        error "Docker is not installed or not in PATH"
        exit 1
    fi
    
    # Check if buildx is available for multi-platform builds
    if [[ "$PLATFORMS" == *","* ]]; then
        log "🏗️ Setting up Docker Buildx for multi-platform builds..."
        docker buildx create --use --name multiarch-builder 2>/dev/null || true
        docker buildx inspect --bootstrap
    fi
    
    # Build the image
    log "🔨 Building Docker image..."
    
    if [[ "$PLATFORMS" == *","* ]]; then
        # Multi-platform build
        if [[ "$PUSH_TO_REGISTRY" == "true" ]]; then
            docker buildx build \
                --platform "$PLATFORMS" \
                --tag "${IMAGE_NAME}:${TAG}" \
                --push \
                $BUILD_ARGS \
                .
        else
            docker buildx build \
                --platform "$PLATFORMS" \
                --tag "${IMAGE_NAME}:${TAG}" \
                --load \
                $BUILD_ARGS \
                .
        fi
    else
        # Single platform build
        docker build \
            --tag "${IMAGE_NAME}:${TAG}" \
            $BUILD_ARGS \
            .
        
        if [[ "$PUSH_TO_REGISTRY" == "true" ]]; then
            log "📤 Pushing to registry..."
            docker push "${IMAGE_NAME}:${TAG}"
        fi
    fi
    
    # Display image info
    log "✅ Build completed successfully!"
    log "📊 Image information:"
    
    if [[ "$PLATFORMS" != *","* ]]; then
        # Show size for single platform builds
        IMAGE_SIZE=$(docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" | grep "${IMAGE_NAME}" | grep "${TAG}" | awk '{print $3}' | head -1)
        log "   - Size: ${IMAGE_SIZE}"
    fi
    
    log "   - Full name: ${IMAGE_NAME}:${TAG}"
    log "   - Platforms: ${PLATFORMS}"
    
    echo ""
    log "🚀 Quick start commands:"
    echo ""
    echo -e "${BLUE}# Run the container${NC}"
    echo "docker run -p 11434:11434 -p 4000:4000 \\"
    echo "  -e LMSTUDIO_URL=http://host.docker.internal:1234 \\"
    echo "  ${IMAGE_NAME}:${TAG}"
    echo ""
    echo -e "${BLUE}# Or use docker-compose${NC}"
    echo "docker compose up"
    echo ""
}

# Run main function
main "$@"