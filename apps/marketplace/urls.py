from django.urls import path

from . import views

app_name = "marketplace"

urlpatterns = [
    path("", views.home, name="home"),
    path("marketplace/", views.listing_list, name="list"),
    path("marketplace/new/", views.listing_new, name="new"),
    path("marketplace/<int:listing_id>/", views.listing_detail, name="detail"),
    path("api/marketplace/metadata/", views.api_metadata, name="api_metadata"),
]
