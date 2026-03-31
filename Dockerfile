FROM python:3.11-slim

WORKDIR /opt/agent

COPY agent.py .

# strace is needed for diagnostics
RUN apt-get update && apt-get install -y --no-install-recommends \
    strace procps && \
    rm -rf /var/lib/apt/lists/*

CMD ["python3", "-u", "agent.py"]
