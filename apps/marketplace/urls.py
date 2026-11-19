from django.urls import path

from . import views

app_name = "marketplace"

urlpatterns = [
    path("", views.home, name="home"),
    path("marketplace/", views.listing_list, name="list"),
    path("marketplace/<int:listing_id>/", views.listing_detail, name="detail"),
]
