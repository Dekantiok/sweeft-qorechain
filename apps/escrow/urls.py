from django.urls import path

from . import views

app_name = "escrow"

urlpatterns = [
    path("escrow/<int:escrow_id>/", views.escrow_detail, name="detail"),
    path("api/escrow/<int:escrow_id>/release-request/", views.release_request, name="release_request"),
    path("api/escrow/<int:escrow_id>/release/", views.release_submit, name="release_submit"),
]
