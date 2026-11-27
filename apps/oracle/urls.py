from django.urls import path

from . import views

app_name = "oracle"

urlpatterns = [
    path("oracle/", views.evidence_list, name="index"),
    path("api/oracle/attest-request/", views.attest_request, name="attest_request"),
    path("api/oracle/attest-submit/", views.attest_submit, name="attest_submit"),
]
