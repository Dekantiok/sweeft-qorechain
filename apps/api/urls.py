from django.urls import path

from . import views

app_name = "api_v1"

urlpatterns = [
    path("api/v1/", views.index, name="index"),
    path("api/v1/listings/", views.listings, name="listings"),
    path("api/v1/listings/<int:on_chain_id>/", views.listing_detail, name="listing_detail"),
    path("api/v1/escrows/", views.escrows, name="escrows"),
    path("api/v1/escrows/<int:on_chain_id>/", views.escrow_detail, name="escrow_detail"),
    path("api/v1/disputes/", views.disputes, name="disputes"),
    path("api/v1/disputes/<int:on_chain_id>/", views.dispute_detail, name="dispute_detail"),
    path("api/v1/proposals/", views.proposals, name="proposals"),
    path("api/v1/board/", views.board, name="board"),
    path("api/v1/verifiers/", views.verifiers, name="verifiers"),
]
