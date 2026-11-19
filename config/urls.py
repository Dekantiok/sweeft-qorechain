"""Sweeft URL configuration."""

from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.urls import include, path

urlpatterns = [
    path("admin/", admin.site.urls),
    path("", include("apps.marketplace.urls")),
    path("", include("apps.escrow.urls")),
    path("", include("apps.participants.urls")),
    path("", include("apps.governance.urls")),
    path("", include("apps.oracle.urls")),
    path("", include("apps.ai.urls")),
    path("", include("apps.blockchain.urls")),
]

if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
