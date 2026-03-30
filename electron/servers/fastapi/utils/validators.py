from pathlib import PurePath
from typing import List
from fastapi import HTTPException

from fastapi import UploadFile

from constants.documents import UPLOAD_ACCEPTED_FILE_EXTENSIONS


def _upload_allowed_by_extension(filename: str | None) -> bool:
    if not filename:
        return False
    suffix = PurePath(filename).suffix.lower()
    return suffix in UPLOAD_ACCEPTED_FILE_EXTENSIONS


def _content_type_needs_extension_fallback(content_type: str | None) -> bool:
    ct = (content_type or "").strip().lower()
    return ct in ("", "application/octet-stream")


def validate_files(
    field,
    nullable: bool,
    multiple: bool,
    max_size: int,
    accepted_types: List[str],
):

    if field:
        files: List[UploadFile] = field if multiple else [field]
        for each_file in files:
            if (max_size * 1024 * 1024) < each_file.size:
                raise HTTPException(
                    400,
                    detail=f"File '{each_file.filename}' exceeded max upload size of {max_size} MB",
                )
            elif each_file.content_type in accepted_types:
                continue
            elif _content_type_needs_extension_fallback(
                each_file.content_type
            ) and _upload_allowed_by_extension(each_file.filename):
                continue
            else:
                raise HTTPException(
                    400,
                    detail=f"File '{each_file.filename}' not accepted. Accepted types: {accepted_types}",
                )

    elif not (field or nullable):
        raise HTTPException(400, detail="File must be provided.")
