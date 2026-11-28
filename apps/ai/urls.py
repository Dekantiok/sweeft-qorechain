from django.urls import path

from . import views

app_name = "ai"

urlpatterns = [
    path("ai/", views.assistant, name="index"),
    path("api/ai/chat/", views.chat, name="chat"),
    path("api/ai/mandate/", views.mandate_set, name="mandate_set"),
    path("api/ai/seller-mandate/", views.seller_mandate_set, name="seller_mandate_set"),
    path("api/ai/seller-mandate/<int:listing_id>/", views.seller_mandate_status, name="seller_mandate_status"),
    path("api/ai/seller-mandate/<int:listing_id>/quote/", views.seller_quote, name="seller_quote"),
    path("api/ai/seller-mandate/<int:listing_id>/quote/sign/", views.seller_quote_sign, name="seller_quote_sign"),
    path("api/ai/mandate/<int:mandate_id>/<str:action>/", views.mandate_pause_revoke, name="mandate_pause_revoke"),
    path("api/ai/conversations/<int:conversation_id>/", views.conversation_detail, name="conversation"),
]
