"""Template context — exposes the connected wallet to every page."""

from __future__ import annotations


def wallet(request):
    account = request.session.get("wallet_account") or {}
    evm = account.get("evm", "")
    qor = account.get("qor", "")
    ai_mandate = None
    ai_daily_spent_qor = 0
    if evm:
        try:
            from apps.ai.models import Mandate
            from apps.ai.services.tools import _daily_spend_uqor
            from apps.participants.models import Participant

            participant = Participant.objects.filter(evm_address__iexact=evm).first()
            if participant:
                ai_mandate = (
                    Mandate.objects.filter(
                        owner=participant, state__in=[Mandate.State.ACTIVE, Mandate.State.PAUSED]
                    )
                    .order_by("-created_at")
                    .first()
                )
            if ai_mandate and ai_mandate.state == Mandate.State.ACTIVE:
                ai_daily_spent_qor = _daily_spend_uqor(ai_mandate) / 1_000_000
        except Exception:
            ai_mandate = None
    return {
        "wallet_account": evm,
        "wallet_qor": qor,
        "wallet_short": f"{evm[:6]}…{evm[-4:]}" if evm else "",
        "wallet_method": account.get("method", ""),
        "is_staked_resolver": False,
        "is_logistics_provider": False,
        "ai_mandate": ai_mandate,
        "ai_daily_spent_qor": ai_daily_spent_qor,
    }


def nav_flags(request):
    """Gate nav items by participation: staking/governance items only for
    staked resolvers, logistics only for providers. Kept cheap (one query
    per flagged wallet, cached per request by the DB)."""
    account = request.session.get("wallet_account") or {}
    evm = account.get("evm", "")
    if not evm:
        return {"is_staked_resolver": False, "is_logistics_provider": False}

    from apps.participants.models import Participant

    participant = Participant.objects.filter(evm_address__iexact=evm).first()
    if participant is None:
        return {"is_staked_resolver": False, "is_logistics_provider": False}

    staked = False
    provider = False
    try:
        from apps.governance.models import ResolverProfile

        profile = ResolverProfile.objects.filter(participant=participant).first()
        staked = bool(profile and int(profile.staked_uqor) > 0)
    except Exception:
        staked = False
    try:
        from django.db.models import Q

        from apps.logistics.models import LogisticsPartner

        provider = LogisticsPartner.objects.filter(
            Q(owner_wallet__iexact=evm) | Q(settlement_wallet__iexact=evm)
        ).exists()
    except Exception:
        provider = False
    return {"is_staked_resolver": staked, "is_logistics_provider": provider}
