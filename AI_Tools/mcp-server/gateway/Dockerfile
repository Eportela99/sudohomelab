FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ /app/
RUN useradd -r -u 10001 -d /data mcp && mkdir -p /data && chown mcp /data
USER mcp
EXPOSE 8790
CMD ["python", "/app/server.py"]
