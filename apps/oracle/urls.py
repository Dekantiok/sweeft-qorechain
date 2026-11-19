from django.urls import path

from . import views

app_name = "oracle"

urlpatterns = [
    path("oracle/", views.evidence_list, name="index"),
]
