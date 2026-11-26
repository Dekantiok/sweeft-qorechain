from django.urls import path

from . import views

app_name = "ai"

urlpatterns = [
    path("ai/", views.assistant, name="index"),
    path("api/ai/chat/", views.chat, name="chat"),
    path("api/ai/mandate/", views.mandate_set, name="mandate_set"),
    path("api/ai/mandate/<int:mandate_id>/<str:action>/", views.mandate_pause_revoke, name="mandate_pause_revoke"),
    path("api/ai/conversations/<int:conversation_id>/", views.conversation_detail, name="conversation"),
]
