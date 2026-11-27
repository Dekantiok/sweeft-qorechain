from django.urls import path

from . import views, views_proof

app_name = "blockchain"

urlpatterns = [
    path("api/indexer/sync/", views.sync_now, name="sync_now"),
    path("proof/tx/<str:tx_hash>/", views_proof.tx_proof, name="tx_proof"),
    path("verify/", views_proof.verify_tx_page, name="verify"),
    path("proof/escrow/<int:escrow_id>/", views_proof.escrow_proof, name="escrow_proof"),
    path("security/", views_proof.security_page, name="security"),
]
