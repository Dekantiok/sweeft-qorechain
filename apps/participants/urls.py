from django.urls import path

from . import views, wallet

app_name = "participants"

urlpatterns = [
    path("dashboard/", views.dashboard, name="dashboard"),
    path("api/wallet/challenge/", wallet.challenge, name="wallet_challenge"),
    path("api/wallet/verify/", wallet.verify, name="wallet_verify"),
    path("api/wallet/logout/", wallet.logout, name="wallet_logout"),
]
