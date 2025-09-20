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

app = FastAPI()

# Configuration (same as original oai2ollama)
API_KEY = "dummy"
BASE_URL = "http://localhost:4000"
CAPABILITIES = ["completion", "tools", "insert", "embedding"]

def _new_client():
    return httpx.AsyncClient(
        base_url=BASE_URL,
        headers={"Authorization": f"Bearer {API_KEY}"},
        timeout=60,
        http2=True,
        follow_redirects=True
    )

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
            async with _new_client() as client, client.stream("POST", "/chat/completions", json=data) as response:
                async for chunk in response.aiter_bytes():
                    yield chunk
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
            async with _new_client() as client:
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
                                    "created_at": "2025-01-01T00:00:00Z",  # Static for now
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

        return StreamingResponse(stream(), media_type="text/event-stream")
    else:
        # Non-streaming
        async with _new_client() as client:
            res = await client.post("/chat/completions", json=openai_data)
            res.raise_for_status()
            openai_response = res.json()

            # Convert OpenAI format to Ollama format
            ollama_response = {
                "model": data.get("model"),
                "created_at": "2025-01-01T00:00:00Z",
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