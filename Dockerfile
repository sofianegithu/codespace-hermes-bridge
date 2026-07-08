FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates \
 && curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cf.deb \
 && dpkg -i /tmp/cf.deb || (apt-get install -f -y && rm -f /tmp/cf.deb) \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ ./app/
COPY scripts/ ./scripts/
RUN chmod +x scripts/start.sh

EXPOSE 8080
CMD ["./scripts/start.sh"]
