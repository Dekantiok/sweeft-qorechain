"""AI provider interface — implement to add a new inference provider."""

from __future__ import annotations

from abc import ABC, abstractmethod


class AIProvider(ABC):
    @abstractmethod
    def extract_structured(self, prompt: str, schema: dict, system: str = "") -> dict:
        """Return model output parsed into `schema`. Must raise on parse failure."""

    @abstractmethod
    def tool_call(self, messages: list, tools: list) -> dict:
        """Run one tool-calling turn and return the model's response."""
