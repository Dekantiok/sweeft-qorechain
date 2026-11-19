"""Development settings — local Docker/WSL, Django dev server."""

import os

from dotenv import load_dotenv

from .base import *  # noqa: F401,F403

load_dotenv(BASE_DIR / ".env")  # noqa: F405

SECRET_KEY = os.getenv("DJANGO_SECRET_KEY", "dev-insecure-key-change-me")
DEBUG = os.getenv("DJANGO_DEBUG", "true").lower() == "true"
ALLOWED_HOSTS = [h for h in os.getenv("DJANGO_ALLOWED_HOSTS", "localhost,127.0.0.1").split(",") if h]

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": os.getenv("POSTGRES_DB", "sweeft"),
        "USER": os.getenv("POSTGRES_USER", "sweeft"),
        "PASSWORD": os.getenv("POSTGRES_PASSWORD", "sweeft"),
        "HOST": os.getenv("POSTGRES_HOST", "127.0.0.1"),
        "PORT": os.getenv("POSTGRES_PORT", "5432"),
    }
}

CSRF_TRUSTED_ORIGINS = ["http://localhost:8000", "http://127.0.0.1:8000"]
