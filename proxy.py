#!/usr/bin/env python3
"""
Custom oai2ollama with additional endpoints for full Ollama compatibility
"""

from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
import json
import httpx
import asyncio
from typing import Dict, Any
import logging

app = FastAPI()

import os
from datetime import datetime, timezone

# Configure logging so exceptions show up in container logs with tracebacks
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration (read from env to avoid fragile runtime sed replacements)
API_KEY = os.environ.get("API_KEY", "dummy")
BASE_URL = os.environ.get("LITELLM_BASE_URL", "http://localhost:4000")
USE_HTTP2 = os.environ.get("USE_HTTP2", "false").lower() == "true"
CAPABILITIES = ["completion", "tools", "insert", "embedding"]

def _new_client():
    return httpx.AsyncClient(
        base_url=BASE_URL,
        headers={"Authorization": f"Bearer {API_KEY}"},
        timeout=60,
        follow_redirects=True,
        http2=USE_HTTP2,
    )

def _new_streaming_client():
    """Client with longer timeout for streaming requests"""
    return httpx.AsyncClient(
        base_url=BASE_URL,
        headers={"Authorization": f"Bearer {API_KEY}"},
        timeout=int(os.environ.get("STREAM_TIMEOUT", "300")),  # configurable via env
        follow_redirects=True,
        http2=USE_HTTP2,
    )


def _truncate_messages(messages, max_chars: int = 20000):
    """Simple left-truncation by character length to avoid blowing past model context.

    This is a heuristic (characters != tokens) but is cheap and prevents extremely
    large payloads from reaching LiteLLM / LM Studio which can cause mid-stream
    failures when the context is far larger than the loaded model's context window.
    """
    if not messages:
        return messages

    msgs = list(messages)
    total = sum(len((m.get("content") or "")) for m in msgs if isinstance(m, dict))
    # If messages are plain strings, fall back to total length of joined string
    if total == 0 and isinstance(messages, list):
        joined = "".join([m if isinstance(m, str) else json.dumps(m) for m in msgs])
        if len(joined) <= max_chars:
            return msgs
        # crude fallback: keep only the last portion
        truncated = joined[-max_chars:]
        return [{"role": "system", "content": truncated}]

    while msgs and total > max_chars:
        removed = msgs.pop(0)
        total -= len((removed.get("content") or "")) if isinstance(removed, dict) else 0

    return msgs

@app.get("/api/tags")
async def models():
    """Get available models - Ollama format"""
    async with _new_client() as client:
        res = await client.get("/models")
        res.raise_for_status()
        models_map = {i["id"]: {"name": i["id"], "model": i["id"]} for i in res.json()["data"]}
        return {"models": list(models_map.values())}

@app.post("/api/show")
async def show_model():
    """Show model info - Ollama format"""
    return {
        "model_info": {"general.architecture": "CausalLM"},
        "capabilities": CAPABILITIES,
    }

@app.get("/v1/models")
async def list_models():
    """List models - OpenAI format"""
    async with _new_client() as client:
        res = await client.get("/models")
        res.raise_for_status()
        return res.json()

@app.post("/v1/chat/completions")
async def chat_completions_openai(request: Request):
    """Chat completions - OpenAI format"""
    data = await request.json()

    if data.get("stream", False):
        async def stream():
            try:
                # Truncate messages heuristically before streaming to avoid exceeding model context
                data["messages"] = _truncate_messages(data.get("messages", []))

                async with _new_streaming_client() as client:
                    async with client.stream("POST", "/chat/completions", json=data) as response:
                        async for chunk in response.aiter_bytes():
                            yield chunk
            except Exception as e:
                # Return a proper error message if streaming fails
                error_response = {
                    "error": {
                        "message": f"Streaming failed: {str(e)}",
                        "type": "stream_error",
                        "code": "stream_error"
                    }
                }
                yield f"data: {json.dumps(error_response)}\n\n"
        return StreamingResponse(stream(), media_type="text/event-stream")
    else:
        async with _new_client() as client:
            res = await client.post("/chat/completions", json=data)
            res.raise_for_status()
            return res.json()

@app.post("/api/chat")
async def chat_completions_ollama(request: Request):
    """Chat completions - Ollama format (missing from original oai2ollama!)"""
    data = await request.json()

    # Convert Ollama format to OpenAI format
    openai_data = {
        "model": data.get("model"),
        "messages": data.get("messages", []),
        "stream": data.get("stream", False),
        "max_tokens": data.get("options", {}).get("max_tokens", 2048),
        "temperature": data.get("options", {}).get("temperature", 0.7)
    }

    # Add tools if present
    if "tools" in data:
        openai_data["tools"] = data["tools"]
        if "tool_choice" in data:
            openai_data["tool_choice"] = data["tool_choice"]

    if data.get("stream", False):
        async def stream():
            try:
                async with _new_streaming_client() as client:
                    # Truncate messages heuristically before streaming to avoid exceeding model context
                    openai_data["messages"] = _truncate_messages(openai_data.get("messages", []))

                    async with client.stream("POST", "/chat/completions", json=openai_data) as response:
                        async for chunk in response.aiter_lines():
                            if chunk.startswith("data: "):
                                chunk_data = chunk[6:]
                                if chunk_data.strip() == "[DONE]":
                                    # Convert OpenAI [DONE] to Ollama format
                                    yield f'data: {json.dumps({"model": data.get("model"), "done": True})}\n\n'
                                    break

                                try:
                                    openai_chunk = json.loads(chunk_data)
                                    # Convert OpenAI streaming format to Ollama format
                                    ollama_chunk = {
                                        "model": data.get("model"),
                                        "created_at": datetime.now(timezone.utc).isoformat(),
                                        "done": False
                                    }

                                    if "choices" in openai_chunk and len(openai_chunk["choices"]) > 0:
                                        choice = openai_chunk["choices"][0]
                                        if "delta" in choice:
                                            delta = choice["delta"]
                                            if "content" in delta:
                                                ollama_chunk["message"] = {
                                                    "role": "assistant",
                                                    "content": delta["content"]
                                                }
                                            if "tool_calls" in delta:
                                                ollama_chunk["message"] = {
                                                    "role": "assistant",
                                                    "content": "",
                                                    "tool_calls": delta["tool_calls"]
                                                }

                                    yield f'data: {json.dumps(ollama_chunk)}\n\n'
                                except json.JSONDecodeError:
                                    continue
            except Exception as e:
                # Log the full exception with traceback for diagnostics
                logger.exception("Streaming failed for model %s", data.get("model"))

                # Ensure the streamed error includes the exception message (truncated)
                exc_text = str(e) or "<no message>"
                if len(exc_text) > 1000:
                    exc_text = exc_text[:1000] + "...[truncated]"

                error_response = {
                    "model": data.get("model"),
                    "created_at": datetime.now(timezone.utc).isoformat(),
                    "done": True,
                    "error": f"Streaming failed: {exc_text}"
                }
                yield f'data: {json.dumps(error_response)}\n\n'

        return StreamingResponse(stream(), media_type="text/event-stream")
    else:

        # Non-streaming
        async with _new_client() as client:
            # Truncate messages heuristically to avoid exceeding model context
            openai_data["messages"] = _truncate_messages(openai_data.get("messages", []))

            res = await client.post("/chat/completions", json=openai_data)
            res.raise_for_status()
            openai_response = res.json()

            # Convert OpenAI format to Ollama format
            ollama_response = {
                "model": data.get("model"),
                "created_at": datetime.now(timezone.utc).isoformat(),
                "done": True,
                "message": {
                    "role": "assistant",
                    "content": ""
                }
            }

            if "choices" in openai_response and len(openai_response["choices"]) > 0:
                choice = openai_response["choices"][0]
                if "message" in choice:
                    message = choice["message"]
                    ollama_response["message"] = {
                        "role": message.get("role", "assistant"),
                        "content": message.get("content", "")
                    }
                    if "tool_calls" in message:
                        ollama_response["message"]["tool_calls"] = message["tool_calls"]

            return ollama_response

@app.get("/api/version")
async def ollama_version():
    """Ollama version info"""
    return {"version": "0.11.4"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="localhost", port=11434)