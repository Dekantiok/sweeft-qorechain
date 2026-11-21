from django.urls import path

from . import views

app_name = "governance"

urlpatterns = [
    path("governance/", views.proposal_list, name="index"),
    path("disputes/", views.dispute_list, name="disputes"),
]
