"""Notifications — transaction and lifecycle notifications."""

from __future__ import annotations

from django.db import models

from apps.participants.models import Participant


class Notification(models.Model):
    class Channel(models.TextChoices):
        IN_APP = "in_app", "In-app"
        EMAIL = "email", "Email"

    participant = models.ForeignKey(Participant, on_delete=models.CASCADE, related_name="notifications")
    channel = models.CharField(max_length=10, choices=Channel.choices, default=Channel.IN_APP)

    title = models.CharField(max_length=200)
    body = models.TextField(blank=True)
    link = models.CharField(max_length=300, blank=True)

    read_at = models.DateTimeField(null=True, blank=True)
    sent_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.participant.display_name}: {self.title}"

    @property
    def is_read(self) -> bool:
        return self.read_at is not None
