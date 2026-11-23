from django.urls import path

from . import views

app_name = "ai"

urlpatterns = [
    path("ai/", views.assistant, name="index"),
    path("api/ai/chat/", views.chat, name="chat"),
    path("api/ai/conversations/<int:conversation_id>/", views.conversation_detail, name="conversation"),
]
