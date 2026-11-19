"""AI provider adapter — Meta Model API (OpenAI-compatible).

Swap providers by adding a sibling module and changing the import in
`apps.ai.services.orchestrator`. The rest of the application never talks to a
provider directly.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class ModelConfig:
    base_url: str
    api_key: str
    extract_model: str
    reason_model: str


def get_model_config() -> ModelConfig:
    return ModelConfig(
        base_url=os.getenv("META_API_BASE_URL", "https://api.meta.ai/v1"),
        api_key=os.getenv("MODEL_API_KEY", ""),
        extract_model=os.getenv("META_MODEL_EXTRACT", "muse-ember-1.0"),
        reason_model=os.getenv("META_MODEL_REASON", "muse-spark-1.3"),
    )


def get_client():
    """Return an OpenAI-SDK client pointed at Meta Model API."""
    from openai import OpenAI

    config = get_model_config()
    if not config.api_key:
        raise RuntimeError("MODEL_API_KEY is not set — add it to .env")
    return OpenAI(base_url=config.base_url, api_key=config.api_key)
