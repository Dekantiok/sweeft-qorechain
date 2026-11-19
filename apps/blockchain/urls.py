from django.urls import path

from . import views

app_name = "blockchain"

urlpatterns = [
    path("api/indexer/sync/", views.sync_now, name="sync_now"),
]
