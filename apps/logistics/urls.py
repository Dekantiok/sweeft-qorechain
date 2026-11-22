from django.urls import path

from . import views

app_name = "logistics"

urlpatterns = [
    path("logistics/", views.directory, name="directory"),
    path("logistics/register/", views.partner_register, name="partner_register"),
    path("logistics/portal/", views.partner_portal, name="partner_portal"),
    path("api/logistics/partners/<int:partner_id>/credential/", views.api_issue_partner_credential, name="issue_credential"),
    path("api/logistics/shipments/", views.api_create_shipment, name="create_shipment"),
    path("api/logistics/shipments/<int:shipment_id>/", views.api_shipment, name="shipment"),
    path("api/logistics/escrow/<int:escrow_id>/shipment/", views.api_shipment_for_escrow, name="escrow_shipment"),
    path("api/logistics/shipments/<int:shipment_id>/events/", views.api_shipment_event, name="shipment_event"),
    path("api/logistics/verification/payload/", views.api_verification_payload, name="verification_payload"),
    path("api/logistics/escrow/<int:escrow_id>/attest/", views.api_carrier_attest, name="carrier_attest"),
    # Partner API (X-Api-Key)
    path("api/partner/shipments/", views.api_partner_shipments, name="partner_shipments"),
    path("api/partner/shipments/<int:shipment_id>/events/", views.api_partner_event, name="partner_event"),
]
