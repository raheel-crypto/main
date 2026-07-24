FROM python:3.12-slim

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    RED_TEAM_STATE_DIR=/data

COPY requirements.txt ./
RUN pip install -r requirements.txt

COPY app ./app
COPY config ./config
COPY intel ./intel
COPY prompts ./prompts

# Persistent state mount target. Fly volumes / Railway disks attach here.
RUN mkdir -p /data
VOLUME ["/data"]

EXPOSE 3003
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "3003"]
