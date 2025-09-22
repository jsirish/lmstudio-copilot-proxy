# Multi-stage build for LM Studio Copilot Proxy
# Stage 1: Build dependencies and install packages
FROM python:3.11-slim AS builder

# Set build arguments
ARG PYTHON_VERSION=3.11

# Install system dependencies needed for building
RUN apt-get update && apt-get install -y \
    gcc \
    g++ \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create virtual environment
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copy and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org && \
    pip install --no-cache-dir -r requirements.txt --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org

# Note: We use our custom proxy.py instead of oai2ollama package

# Stage 2: Runtime image with minimal footprint
FROM python:3.11-slim

# Install only runtime dependencies
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Copy virtual environment from builder
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Create non-root user for security
RUN groupadd -r appuser && useradd -r -g appuser appuser

# Set working directory
WORKDIR /app

# Copy application files
COPY config.yaml .
COPY proxy.py .
COPY entrypoint.sh .

# Make entrypoint executable
RUN chmod +x entrypoint.sh

# Create directories for logs and cache
RUN mkdir -p /app/logs /app/.cache && \
    chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# Environment variables with defaults
ENV LMSTUDIO_URL=http://host.docker.internal:1234
ENV LITELLM_PORT=4000
ENV OLLAMA_PORT=11434
ENV LOG_LEVEL=INFO
ENV HEALTH_CHECK_INTERVAL=30
ENV GRACEFUL_SHUTDOWN_TIMEOUT=10
ENV MODEL_REFRESH_INTERVAL=300

# Expose ports
EXPOSE 11434 4000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=30s \
    CMD curl -f http://localhost:11434/api/tags || exit 1

# Use entrypoint script
ENTRYPOINT ["./entrypoint.sh"]