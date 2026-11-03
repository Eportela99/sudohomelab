FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
RUN pip install --no-cache-dir starlette==1.3.1 uvicorn==0.51.0 httpx==0.28.1
COPY router.py admin.py webui.py /app/
RUN useradd -r -u 10001 -d /data router && mkdir -p /data && chown router /data
USER router
EXPOSE 8791
CMD ["python", "/app/router.py"]
