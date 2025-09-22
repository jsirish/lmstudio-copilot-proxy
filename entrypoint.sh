#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
}

# Function to check if LM Studio is accessible
check_lmstudio() {
    local max_retries=10
    local retry=0

    log "🔍 Checking LM Studio connectivity at ${LMSTUDIO_URL}..."

    while [ $retry -lt $max_retries ]; do
        if curl -s --connect-timeout 5 "${LMSTUDIO_URL}/v1/models" > /dev/null 2>&1; then
            log "✅ LM Studio is accessible at ${LMSTUDIO_URL}"
            return 0
        fi

        retry=$((retry + 1))
        warn "LM Studio not accessible, attempt $retry/$max_retries"
        sleep 2
    done

    error "❌ Could not connect to LM Studio at ${LMSTUDIO_URL}"
    error "   Please ensure LM Studio is running and accessible from the container."
    error "   For local LM Studio, use: LMSTUDIO_URL=http://host.docker.internal:1234"
    return 1
}

# Function to generate dynamic config if needed
generate_config() {
    if [ ! -f "/app/config.yaml" ]; then
        log "📝 Generating default config.yaml..."
        cat > /app/config.yaml << EOF
# Auto-generated LiteLLM configuration
model_list: []

general_settings:
  master_key: ${API_KEY:-dummy}

litellm_settings:
  success_callback: []
  failure_callback: []
EOF
    fi
}

# Global variables for process IDs
LITELLM_PID=""
CUSTOM_PROXY_PID=""

# Cleanup function for graceful shutdown
cleanup() {
    log "🛑 Received shutdown signal, cleaning up..."

    if [ -n "$LITELLM_PID" ] && kill -0 $LITELLM_PID 2>/dev/null; then
        log "Stopping LiteLLM (PID: $LITELLM_PID)..."
        kill -TERM $LITELLM_PID 2>/dev/null || true
    fi

    if [ -n "$CUSTOM_PROXY_PID" ] && kill -0 $CUSTOM_PROXY_PID 2>/dev/null; then
        log "Stopping custom proxy (PID: $CUSTOM_PROXY_PID)..."
        kill -TERM $CUSTOM_PROXY_PID 2>/dev/null || true
    fi

    # Wait for graceful shutdown
    local timeout=${GRACEFUL_SHUTDOWN_TIMEOUT:-10}
    log "Waiting up to ${timeout}s for graceful shutdown..."

    for i in $(seq 1 $timeout); do
        local running=0

        if [ -n "$LITELLM_PID" ] && kill -0 $LITELLM_PID 2>/dev/null; then
            running=$((running + 1))
        fi

        if [ -n "$CUSTOM_PROXY_PID" ] && kill -0 $CUSTOM_PROXY_PID 2>/dev/null; then
            running=$((running + 1))
        fi

        if [ $running -eq 0 ]; then
            log "✅ All processes stopped gracefully"
            exit 0
        fi

        sleep 1
    done

    # Force kill if necessary
    warn "Forcing shutdown of remaining processes..."
    [ -n "$LITELLM_PID" ] && kill -KILL $LITELLM_PID 2>/dev/null || true
    [ -n "$CUSTOM_PROXY_PID" ] && kill -KILL $CUSTOM_PROXY_PID 2>/dev/null || true

    exit 0
}

# Set up signal handlers
trap cleanup SIGTERM SIGINT SIGQUIT

# Main function
main() {
    # Set timeout environment variables for LiteLLM and aiohttp
    export LITELLM_REQUEST_TIMEOUT=300
    export LITELLM_STREAM_TIMEOUT=300
    export AIOHTTP_TIMEOUT=300
    export OPENAI_API_TIMEOUT=300
    export HTTPX_TIMEOUT=300

    log "🐳 Starting LM Studio Copilot Proxy Container"
    log "🔧 Configuration:"
    log "   - LM Studio URL: ${LMSTUDIO_URL}"
    log "   - LiteLLM Port: ${LITELLM_PORT}"
    log "   - Ollama API Port: ${OLLAMA_PORT}"
    log "   - API Key: ${API_KEY:-dummy}"
    log "   - Log Level: ${LOG_LEVEL}"
    log "   - Request Timeout: 300s"

    # Pre-flight checks
    if ! check_lmstudio; then
        if [[ "${LMSTUDIO_URL}" == *"localhost"* ]] || [[ "${LMSTUDIO_URL}" == *"127.0.0.1"* ]]; then
            error "💡 Tip: Use 'host.docker.internal' instead of 'localhost' to access host services from container"
        fi
        exit 1
    fi

    # Generate config if needed
    generate_config

    # Start LiteLLM proxy
    log "🚀 Starting LiteLLM proxy on port ${LITELLM_PORT}..."
    litellm --config /app/config.yaml --port ${LITELLM_PORT} --host 0.0.0.0 &
    LITELLM_PID=$!
    log "Started LiteLLM with PID $LITELLM_PID"

    # Wait for LiteLLM to be ready
    sleep 3
    local litellm_ready=false
    for i in {1..10}; do
        if curl -s "http://localhost:${LITELLM_PORT}/health" > /dev/null 2>&1; then
            litellm_ready=true
            break
        fi
        sleep 1
    done

    if [ "$litellm_ready" = false ]; then
        error "❌ LiteLLM failed to start properly"
        exit 1
    fi

    # Start custom proxy (using our enhanced proxy.py instead of oai2ollama package)
    log "🚀 Starting custom Ollama-compatible proxy on port ${OLLAMA_PORT}..."

    # Start the custom proxy. proxy.py reads configuration from environment variables.
    export LITELLM_BASE_URL="http://localhost:${LITELLM_PORT}"
    export API_KEY="${API_KEY:-dummy}"

    python -c "import sys; sys.path.append('/app'); from proxy import app; import uvicorn; uvicorn.run(app, host='0.0.0.0', port=${OLLAMA_PORT})" &
    CUSTOM_PROXY_PID=$!
    log "Started custom proxy with PID $CUSTOM_PROXY_PID"

    # Wait for custom proxy to be ready
    sleep 2
    local proxy_ready=false
    for i in {1..10}; do
        if curl -s "http://localhost:${OLLAMA_PORT}/api/tags" > /dev/null 2>&1; then
            proxy_ready=true
            break
        fi
        sleep 1
    done

    if [ "$proxy_ready" = false ]; then
        error "❌ Custom proxy failed to start properly"
        exit 1
    fi

    log "✅ All services started successfully!"
    log ""
    log "📋 VS Code Configuration:"
    log "   Set github.copilot.chat.byok.ollamaEndpoint to: http://localhost:${OLLAMA_PORT}"
    log "   Then click 'Manage Models' → Select 'Ollama'"
    log ""
    log "🔗 Available Endpoints:"
    log "   - Ollama API (for VS Code): http://localhost:${OLLAMA_PORT}"
    log "   - LiteLLM API: http://localhost:${LITELLM_PORT}"
    log "   - Health Check: http://localhost:${OLLAMA_PORT}/api/tags"
    log ""
    log "🎯 Container is ready! Press Ctrl+C to stop..."

    # Wait for background processes
    wait $LITELLM_PID $CUSTOM_PROXY_PID
}

# Run main function
main "$@"