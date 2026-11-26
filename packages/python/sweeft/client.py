"""Typed client for the Sweeft public REST API (`/api/v1`)."""

from __future__ import annotations

import requests


class SweeftClient:
    def __init__(self, base_url: str, timeout: float = 20.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def _get(self, path: str, **params) -> dict:
        response = requests.get(f"{self.base_url}{path}", params=params, timeout=self.timeout)
        response.raise_for_status()
        return response.json()

    def index(self) -> dict:
        return self._get("/api/v1/")

    def listings(self, status: str | None = None, **paging) -> list:
        return self._get("/api/v1/listings/", status=status, **paging)["results"]

    def listing(self, on_chain_id: int) -> dict:
        return self._get(f"/api/v1/listings/{on_chain_id}/")

    def escrows(self, buyer: str | None = None, seller: str | None = None, state: str | None = None, **paging) -> list:
        return self._get("/api/v1/escrows/", buyer=buyer, seller=seller, state=state, **paging)["results"]

    def escrow(self, on_chain_id: int) -> dict:
        return self._get(f"/api/v1/escrows/{on_chain_id}/")

    def disputes(self, state: str | None = None, **paging) -> list:
        return self._get("/api/v1/disputes/", state=state, **paging)["results"]

    def dispute(self, on_chain_id: int) -> dict:
        return self._get(f"/api/v1/disputes/{on_chain_id}/")

    def proposals(self, **paging) -> list:
        return self._get("/api/v1/proposals/", **paging)["results"]

    def board(self) -> dict:
        return self._get("/api/v1/board/")

    def verifiers(self) -> list:
        return self._get("/api/v1/verifiers/")["results"]
