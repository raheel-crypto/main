# Vercel Python serverless entry point. The runtime imports `app` from this
# module and serves it via the @vercel/python ASGI adapter. All routes
# (including /health and /evaluate) flow through the FastAPI app defined in
# app/main.py — see vercel.json's rewrite that sends every path here.
from app.main import app

__all__ = ["app"]
