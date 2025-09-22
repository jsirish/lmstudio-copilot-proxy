#!/bin/bash

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration
IMAGE_NAME="${1:-lmstudio-copilot-proxy:latest}"
CONTAINER_NAME="lmstudio-proxy-test"
OLLAMA_PORT=11434
LITELLM_PORT=4000
WAIT_TIME=15

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
}

cleanup() {
    log "🧹 Cleaning up test container..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
}

# Set up cleanup on exit
trap cleanup EXIT INT TERM

main() {
    log "🧪 Testing LM Studio Copilot Proxy Docker Image"
    log "📋 Test Configuration:"
    log "   - Image: $IMAGE_NAME"
    log "   - Container: $CONTAINER_NAME"
    log "   - Ollama Port: $OLLAMA_PORT"
    log "   - LiteLLM Port: $LITELLM_PORT"
    
    # Clean up any existing test container
    cleanup
    
    # Start the container
    log "🚀 Starting test container..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        -p "$OLLAMA_PORT:$OLLAMA_PORT" \
        -p "$LITELLM_PORT:$LITELLM_PORT" \
        -e LMSTUDIO_URL=http://host.docker.internal:1234 \
        -e LOG_LEVEL=INFO \
        "$IMAGE_NAME"
    
    # Wait for container to start
    log "⏳ Waiting ${WAIT_TIME}s for container to initialize..."
    sleep "$WAIT_TIME"
    
    # Check if container is running
    if ! docker ps | grep -q "$CONTAINER_NAME"; then
        error "❌ Container failed to start or exited"
        echo ""
        log "📋 Container logs:"
        docker logs "$CONTAINER_NAME" 2>&1 || true
        exit 1
    fi
    
    log "✅ Container is running"
    
    # Test 1: Check if Ollama API endpoint responds
    log "🔍 Testing Ollama API endpoint..."
    if response=$(curl --fail-with-body -sS "http://localhost:$OLLAMA_PORT/api/tags" 2>&1); then
        log "✅ Ollama API endpoint is responding"
    else
        warn "⚠️ Ollama API endpoint not responding: $response"
        log "📋 Container logs:"
        docker logs --tail 20 "$CONTAINER_NAME"
        exit 1
    fi
    
    # Test 2: Check if LiteLLM API endpoint responds
    log "🔍 Testing LiteLLM API endpoint..."
    if curl -s -f "http://localhost:$LITELLM_PORT/health" > /dev/null; then
        log "✅ LiteLLM API endpoint is responding"
    else
        warn "⚠️ LiteLLM API endpoint not responding"
        response=$(curl -s -w "%{http_code}" "http://localhost:$LITELLM_PORT/health" -o /dev/null || echo "000")
        log "ℹ️ LiteLLM HTTP response: $response"
    fi
    
    # Test 3: Check container health
    log "🔍 Checking container health status..."
    health_status=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "no-health-check")
    if [[ "$health_status" == "healthy" ]]; then
        log "✅ Container health check: $health_status"
    elif [[ "$health_status" == "no-health-check" ]]; then
        warn "⚠️ No health check configured"
    else
        warn "⚠️ Container health check: $health_status"
    fi
    
    # Test 4: Check for error logs
    log "🔍 Checking for errors in container logs..."
    error_count=$(docker logs "$CONTAINER_NAME" 2>&1 | grep -i error | wc -l || echo "0")
    if [[ "$error_count" -eq 0 ]]; then
        log "✅ No errors found in container logs"
    else
        warn "⚠️ Found $error_count error messages in logs"
        echo ""
        log "📋 Recent error messages:"
        docker logs "$CONTAINER_NAME" 2>&1 | grep -i error | tail -5 || true
    fi
    
    # Test 5: Resource usage
    log "🔍 Checking resource usage..."
    stats=$(docker stats --no-stream --format "table {{.MemUsage}}\t{{.CPUPerc}}" "$CONTAINER_NAME" | tail -1)
    memory=$(echo "$stats" | awk '{print $1}')
    cpu=$(echo "$stats" | awk '{print $2}')
    log "📊 Resource usage: Memory: $memory, CPU: $cpu"
    
    # Display container logs for debugging
    echo ""
    log "📋 Recent container logs:"
    docker logs --tail 10 "$CONTAINER_NAME" 2>&1 || true
    
    echo ""
    log "✅ Docker container test completed!"
    echo ""
    log "🎯 Next steps:"
    log "   1. Ensure LM Studio is running on http://localhost:1234"
    log "   2. Load a model in LM Studio"
    log "   3. Configure VS Code with endpoint: http://localhost:$OLLAMA_PORT"
    log "   4. Test with: curl http://localhost:$OLLAMA_PORT/api/tags"
    
    echo ""
    log "🛑 To stop the test container: docker stop $CONTAINER_NAME"
}

main "$@"