#!/bin/bash

set -euo pipefail

echo "🤖 Starting LM Studio Proxy (using actual oai2ollama package)..."

# Check if LM Studio is running
if ! curl -s http://localhost:1234/v1/models > /dev/null 2>&1; then
    echo "⚠️  LM Studio doesn't seem to be running on localhost:1234"
    echo "   Please start LM Studio first, then try again."
    exit 1
fi

echo "🔧 Activating virtual environment..."
source venv/bin/activate

echo "📦 Installing dependencies..."
pip install -q -r requirements.txt

echo "🔍 Checking if LM Studio is running..."
if curl -s http://localhost:1234/v1/models > /dev/null 2>&1; then
    echo "✅ LM Studio is running on port 1234"
else
    echo "❌ LM Studio is not responding. Please start LM Studio first."
    exit 1
fi

echo "🧹 Cleaning up existing processes..."
pkill -f "litellm.*port.*4000" 2>/dev/null || true
pkill -f "oai2ollama.*11434" 2>/dev/null || true

echo "🚀 Starting LiteLLM proxy on port 4000..."
litellm --config litellm-config.yaml --port 4000 &
LITELLM_PID=$!
echo "Started LiteLLM with PID $LITELLM_PID"
sleep 3

echo "🚀 Starting oai2ollama proxy on port 11434..."
oai2ollama --api-key dummy --base-url http://localhost:4000 --host localhost --port 11434 --capabilities tools --capabilities insert --capabilities embedding &
OAI2OLLAMA_PID=$!
echo "Started oai2ollama with PID $OAI2OLLAMA_PID"
sleep 2

# Forward signals and cleanup
cleanup() {
    echo -e "\n🛑 Stopping background processes..."
    kill $LITELLM_PID $OAI2OLLAMA_PID 2>/dev/null || true
    wait $LITELLM_PID $OAI2OLLAMA_PID 2>/dev/null || true
    exit 0
}
trap cleanup SIGINT SIGTERM

echo -e "\n✅ LM Studio Proxy is running!"
echo "📋 VS Code Configuration:"
echo "   Set github.copilot.chat.byok.ollamaEndpoint to: http://localhost:11434"
echo "   Then click 'Manage Models' → Select 'Ollama'"
echo ""
echo "🔗 Endpoints:"
echo "   - Ollama API (for VS Code): http://localhost:11434"
echo "   - LiteLLM API: http://localhost:4000"
echo "   - LM Studio: http://localhost:1234"
echo ""
echo "Press Ctrl+C to stop..."

# Wait for both background processes
wait $LITELLM_PID $OAI2OLLAMA_PID