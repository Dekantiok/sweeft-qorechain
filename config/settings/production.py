"""Production settings — hardened defaults for a real deployment."""

import os
from urllib.parse import unquote, urlparse

from dotenv import load_dotenv

from .base import *  # noqa: F401,F403

load_dotenv(BASE_DIR / ".env")  # noqa: F405

SECRET_KEY = os.environ["DJANGO_SECRET_KEY"]
DEBUG = False
ALLOWED_HOSTS = [h for h in os.getenv("DJANGO_ALLOWED_HOSTS", "").split(",") if h]
CSRF_TRUSTED_ORIGINS = [h for h in os.getenv("DJANGO_CSRF_TRUSTED_ORIGINS", "").split(",") if h]

# Serve static files (built Tailwind + htmx, no CDN) via WhiteNoise.
MIDDLEWARE.insert(MIDDLEWARE.index("django.middleware.security.SecurityMiddleware") + 1, "whitenoise.middleware.WhiteNoiseMiddleware")
MIDDLEWARE.append("config.middleware.NoCacheHTMLMiddleware")
STORAGES = {
    "default": {"BACKEND": "django.core.files.storage.FileSystemStorage"},
    # Hashed filenames: a CSS change gets a new URL, so browsers never serve
    # a stale stylesheet after a deploy.
    "staticfiles": {"BACKEND": "whitenoise.storage.CompressedManifestStaticFilesStorage"},
}

if os.getenv("DJANGO_DB_ENGINE") == "sqlite":
    # Demo deployments (e.g. Render free tier): single-file DB. Ephemeral by
    # default — `seed_from_chain` rebuilds the projection on every boot.
    # Off-chain-only data (AI conversations, mandates, negotiations) is lost
    # on restart; use Postgres (DATABASE_URL) for anything that must persist.
    import logging
    import warnings

    warnings.warn(
        "Sweeft is running on ephemeral SQLite: off-chain data (mandates, "
        "AI conversations, negotiations) will not survive a restart. "
        "Set DATABASE_URL for a persistent Postgres deployment.",
        stacklevel=2,
    )
    logging.getLogger(__name__).warning(
        "ephemeral SQLite in use — off-chain data will not persist across restarts"
    )
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.sqlite3",
            "NAME": os.getenv("DJANGO_DB_PATH", BASE_DIR / "db.sqlite3"),
        }
    }
elif os.getenv("DATABASE_URL"):
    # Render (and most platforms) provide DATABASE_URL for managed Postgres.
    _db = urlparse(os.environ["DATABASE_URL"])
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.postgresql",
            "NAME": _db.path.lstrip("/"),
            "USER": unquote(_db.username or ""),
            "PASSWORD": unquote(_db.password or ""),
            "HOST": _db.hostname or "",
            "PORT": str(_db.port or 5432),
        }
    }
else:
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.postgresql",
            "NAME": os.environ["POSTGRES_DB"],
            "USER": os.environ["POSTGRES_USER"],
            "PASSWORD": os.environ["POSTGRES_PASSWORD"],
            "HOST": os.getenv("POSTGRES_HOST", "127.0.0.1"),
            "PORT": os.getenv("POSTGRES_PORT", "5432"),
        }
    }

SECURE_SSL_REDIRECT = True
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = "Lax"
CSRF_COOKIE_SAMESITE = "Lax"
SECURE_HSTS_SECONDS = 31536000
SECURE_HSTS_INCLUDE_SUBDOMAINS = True
SECURE_HSTS_PRELOAD = True
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
SECURE_REFERRER_POLICY = "same-origin"
SECURE_CROSS_ORIGIN_OPENER_POLICY = "same-origin"
X_FRAME_OPTIONS = "DENY"

# Content-Security-Policy, applied by config.middleware.ContentSecurityPolicyMiddleware.
CONTENT_SECURITY_POLICY = (
    "default-src 'self'; "
    "img-src 'self' data: blob:; "
    "style-src 'self' 'unsafe-inline'; "
    "script-src 'self' 'nonce-{nonce}'; "
    "connect-src 'self' https://api-testnet.qore.host https://evm-testnet.qore.host; "
    "object-src 'none'; "
    "frame-ancestors 'none'; "
    "base-uri 'self'; "
    "form-action 'self'"
)

# Structured logs to stdout for the platform to collect.
LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "json": {"format": '{"level":"%(levelname)s","logger":"%(name)s","msg":"%(message)s"}'},
    },
    "handlers": {
        "console": {"class": "logging.StreamHandler", "formatter": "json"},
    },
    "root": {"handlers": ["console"], "level": os.getenv("DJANGO_LOG_LEVEL", "INFO")},
}

