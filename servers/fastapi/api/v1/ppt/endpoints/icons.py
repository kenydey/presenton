from typing import List
from fastapi import APIRouter
from services.icon_finder_service import get_icon_finder_service

ICONS_ROUTER = APIRouter(prefix="/icons", tags=["Icons"])


@ICONS_ROUTER.get("/search", response_model=List[str])
async def search_icons(query: str, limit: int = 20):
    return await get_icon_finder_service().search_icons(query, limit)
