from django.urls import path

from . import views

app_name = "escrow"

urlpatterns = [
    path("escrow/<int:escrow_id>/", views.escrow_detail, name="detail"),
    path("api/escrow/<int:escrow_id>/release-request/", views.release_request, name="release_request"),
    path("api/escrow/<int:escrow_id>/release/", views.release_submit, name="release_submit"),
    path("api/escrow/<int:escrow_id>/evidence/", views.evidence_submit, name="evidence_submit"),
    path("api/escrow/<int:escrow_id>/autopilot/pre-authorize/", views.autopilot_pre_authorize, name="autopilot_pre_authorize"),
    path("api/escrow/<int:escrow_id>/autopilot/execute/", views.autopilot_execute, name="autopilot_execute"),
    path("api/escrow/<int:escrow_id>/autopilot/revoke/", views.autopilot_revoke, name="autopilot_revoke"),
]
